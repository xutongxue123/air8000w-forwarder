local util_router = require "util_router"
local channel_registry = require "util_notify_channel"
local util_mobile = require "util_mobile"
local util_network = require "util_network"

local util_notify = {}

local TASK_PREFIX = "notify-v2-"
local TASK_SCHEMA = "notify_task_v2"
local TICK_MODULO = 4294967296
local RETRY_DELAYS = { 5000, 15000, 60000, 300000 }
local CHANNEL_READY_DELAY = 1000

local tasks = {}
local message_count = 0
local bark_enabled = false
local initialized = false
local sending = false
local consecutive_errors = 0
local persistence_errors = 0
local corrupt_records = 0
local route_errors = 0
local configuration_error = false
local last_success_tick = 0
local last_full_success_tick = 0
local channel_tests = {}

local function diag(event, ...)
    if type(USER_DIAG) ~= "function" then return end
    if type(config.LOGGING) ~= "table" and config.DIAGNOSTIC_LOGS ~= true then return end
    USER_DIAG("notify", event, ...)
end

local function info(...)
    if type(USER_LOG_INFO) == "function" then
        USER_LOG_INFO("notify", ...)
    else
        log.info("notify", ...)
    end
end

local function dumpInfo(...)
    log.info("notify", ...)
end

local function nowTick()
    return mcu.ticks()
end

local function elapsed(now, previous)
    if type(previous) ~= "number" or previous <= 0 then return nil end
    local delta = now - previous
    if delta < 0 then delta = delta + TICK_MODULO end
    return delta
end

local function due(now, target)
    return ((now - target) % TICK_MODULO) < (TICK_MODULO / 2)
end

local function after(now, delay)
    return (now + delay) % TICK_MODULO
end

local function publishStatus()
    sys.publish("NOTIFY_STATUS_CHANGED")
end

local function nextMessageId()
    message_count = message_count + 1
    return string.format("m-%d-%d-%d-%d", os.time(), nowTick(), message_count, math.random(999999))
end

local function persistenceKey(task_id)
    return TASK_PREFIX .. task_id
end

local function persistedValue(task)
    local ok, value = pcall(json.encode, {
        schema = TASK_SCHEMA,
        task_id = task.task_id,
        message_id = task.message_id,
        channel = task.channel,
        envelope = task.envelope,
        retry_count = 0,
        created_at = task.created_at,
    })
    if not ok or type(value) ~= "string" then return nil end
    return value
end

local function persist(task)
    local value = persistedValue(task)
    if not value then
        persistence_errors = persistence_errors + 1
        log.error("notify", "任务编码失败", task.task_id)
        return false
    end
    local call_ok, result = pcall(fskv.set, task.persisted_key, value)
    if not call_ok or result ~= true then
        persistence_errors = persistence_errors + 1
        log.error("notify", "任务持久化失败", task.task_id)
        return false
    end
    task.persisted = true
    diag("persisted", "task", task.task_id, "channel", task.channel)
    return true
end

local function validatePersisted(value)
    return type(value) == "table"
        and value.schema == TASK_SCHEMA
        and type(value.task_id) == "string"
        and value.task_id ~= ""
        and type(value.message_id) == "string"
        and type(value.channel) == "string"
        and type(value.envelope) == "table"
        and type(value.envelope.id) == "string"
        and type(value.envelope.content) == "string"
end

local function restore()
    local iter = fskv.iter()
    while iter do
        local key = fskv.next(iter)
        if not key then break end
        if type(key) == "string" and key:sub(1, #TASK_PREFIX) == TASK_PREFIX then
            local raw = fskv.get(key)
            local ok, item = pcall(json.decode, raw or "")
            if ok and validatePersisted(item) then
                table.insert(tasks, {
                    task_id = item.task_id,
                    message_id = item.message_id,
                    channel = item.channel,
                    envelope = item.envelope,
                    created_at = item.created_at,
                    created_tick = nowTick(),
                    retry = 0,
                    next_attempt = nowTick(),
                    persisted_key = key,
                    persisted = true,
                })
                info("恢复待发送任务", item.task_id, item.channel)
            else
                corrupt_records = corrupt_records + 1
                log.error("notify", "保留损坏的持久化记录", key)
            end
        elseif type(key) == "string" and key:sub(1, 4) == "msg-" then
            -- Compatibility with the pre-refactor queue. Keep the original key so
            -- successful delivery removes exactly the historical record.
            local raw = fskv.get(key)
            local ok, legacy = pcall(json.decode, raw or "")
            local channel = "bark"
            local content = raw
            local message_id = key
            if ok and type(legacy) == "table" and legacy.notify_queue_v1 == true then
                channel = type(legacy.channel) == "string" and legacy.channel or "bark"
                content = legacy.msg
                message_id = type(legacy.id) == "string" and legacy.id or key
            end
            if type(content) == "string" and content ~= "" then
                table.insert(tasks, {
                    task_id = message_id .. "-" .. channel,
                    message_id = message_id,
                    channel = channel,
                    envelope = {
                        id = message_id,
                        kind = "legacy",
                        sender = "",
                        content = content,
                        received_at = "",
                    },
                    created_at = os.time(),
                    created_tick = nowTick(),
                    retry = 0,
                    next_attempt = nowTick(),
                    persisted_key = key,
                    persisted = true,
                })
                info("恢复旧版待发送任务", key, channel)
            else
                corrupt_records = corrupt_records + 1
                log.error("notify", "保留损坏的旧版记录", key)
            end
        end
    end
end

local function enqueue(envelope, channel)
    local task_id = envelope.id .. "-" .. channel
    local task = {
        task_id = task_id,
        message_id = envelope.id,
        channel = channel,
        envelope = envelope,
        created_at = os.time(),
        created_tick = nowTick(),
        retry = 0,
        next_attempt = nowTick(),
        persisted_key = persistenceKey(task_id),
        persisted = false,
    }
    local persisted = persist(task)
    table.insert(tasks, task)
    diag("enqueued", "task", task.task_id, "kind", tostring(envelope.kind or ""),
        "channel", channel, "persisted", persisted, "queue", #tasks)
    sys.publish("NOTIFY_WAKE")
    publishStatus()
end

local function addEnvelope(envelope, channels)
    if type(envelope) ~= "table" or type(envelope.content) ~= "string" or envelope.content == "" then
        log.error("notify", "忽略无效通知")
        return false
    end
    envelope.id = type(envelope.id) == "string" and envelope.id ~= "" and envelope.id or nextMessageId()
    local seen = {}
    for _, channel in ipairs(channels or {}) do
        if type(channel) == "string" and channel ~= "" and not seen[channel] then
            seen[channel] = true
            enqueue(envelope, channel)
        end
    end
    return next(seen) ~= nil
end

function util_notify.addSms(envelope)
    envelope = envelope or {}
    envelope.kind = "sms"
    envelope.id = type(envelope.id) == "string" and envelope.id ~= "" and envelope.id or nextMessageId()
    local channels, errors = util_router.route(envelope, config, bark_enabled)
    diag("routed", "message", envelope.id, "channels", table.concat(channels, ","),
        "rule_errors", #errors)
    if #errors > 0 then
        route_errors = route_errors + #errors
        log.error("notify", "路由规则错误", #errors, table.concat(errors, " | "))
    end
    if #channels == 0 and type(log.warn) == "function" then
        log.warn("notify", "短信无目标渠道", envelope.id)
    end
    return addEnvelope(envelope, channels)
end

function util_notify.addCall(envelope)
    envelope = envelope or {}
    envelope.kind = "call"
    envelope.id = type(envelope.id) == "string" and envelope.id ~= "" and envelope.id or nextMessageId()
    envelope.sender = tostring(envelope.sender or "")
    envelope.content = tostring(envelope.content or "")
    envelope.received_at = tostring(envelope.received_at or "")
    local channels = util_router.callChannels(config, bark_enabled)
    diag("call_routed", "message", envelope.id, "state", tostring(envelope.call_state or ""),
        "channels", table.concat(channels, ","))
    return addEnvelope(envelope, channels)
end

function util_notify.addSystem(content, include_bark, include_device_info, network_adapter)
    local envelope = {
        id = nextMessageId(),
        kind = "system",
        sender = "",
        content = tostring(content or ""),
        received_at = os.date("%Y-%m-%d %H:%M:%S"),
        include_device_info = include_device_info == true,
    }
    if type(network_adapter) == "number" then envelope.network_adapter = network_adapter end
    return addEnvelope(envelope, util_router.systemChannels(config, bark_enabled, include_bark))
end

function util_notify.addChannelTest(channel)
    if type(channel) ~= "string" or type(config.CHANNELS) ~= "table"
        or type(config.CHANNELS[channel]) ~= "table" then
        return false, "channel_not_configured"
    end
    local message_id = nextMessageId()
    channel_tests[channel] = { state = "queued", message_id = message_id, detail = "" }
    local queued = addEnvelope({
        id = message_id,
        kind = "system",
        sender = "",
        content = "#WEB_CHANNEL_TEST",
        received_at = os.date("%Y-%m-%d %H:%M:%S"),
        include_device_info = true,
        web_test_channel = channel,
    }, { channel })
    if not queued then
        channel_tests[channel] = { state = "failed", message_id = message_id, detail = "queue_failed" }
        return false, "queue_failed"
    end
    return true, message_id
end

function util_notify.getChannelTest(channel)
    local value = channel_tests[channel]
    if type(value) ~= "table" then return { state = "idle" } end
    return {
        state = value.state,
        message_id = value.message_id,
        detail = value.detail,
    }
end

local function retryDelay(retry)
    return RETRY_DELAYS[math.min(retry, #RETRY_DELAYS)]
end

local function removeTask(index)
    table.remove(tasks, index)
    publishStatus()
end

local function deletePersisted(task)
    if not task.persisted then return true end
    local get_ok, current = pcall(fskv.get, task.persisted_key)
    if get_ok and current == nil then return true end
    local delete_ok, result = pcall(fskv.del, task.persisted_key)
    return delete_ok and result == true
end

local function deliveryEnvelope(task)
    local source = task.envelope
    local channel_config = config.CHANNELS and config.CHANNELS[task.channel]
    local is_bark = type(channel_config) == "table" and channel_config.type == "bark"
    local include_info = source.include_device_info == true
        or (is_bark and source.kind == "sms")
    if not include_info then return source end

    local envelope = {}
    for key, value in pairs(source) do envelope[key] = value end
    local ok, info = pcall(util_mobile.deviceInfo)
    if ok and type(info) == "string" and info ~= "" then
        envelope.device_info = info
    else
        envelope.device_info = table.concat({
            "本机号码: 未知",
            "开机时长: 获取失败",
            "运营商: unknown",
            "信号: 获取失败",
        }, "\n")
    end
    return envelope
end

local function process(index, task)
    if task.delivered then
        if deletePersisted(task) then
            diag("removed", "task", task.task_id, "delivered", true, "queue_before", #tasks)
            removeTask(index)
        else
            persistence_errors = persistence_errors + 1
            task.next_attempt = after(nowTick(), RETRY_DELAYS[#RETRY_DELAYS])
            log.error("notify", "已发送任务删除失败", task.task_id)
            publishStatus()
        end
        return
    end

    local channel_ready, wait_reason = channel_registry.ready(task.channel, config)
    if not channel_ready then
        task.next_attempt = after(nowTick(), CHANNEL_READY_DELAY)
        diag("send_wait", "task", task.task_id, "channel", task.channel,
            "reason", tostring(wait_reason or "not_ready"), "delay_ms", CHANNEL_READY_DELAY)
        sys.timerStart(function() sys.publish("NOTIFY_WAKE") end, CHANNEL_READY_DELAY)
        return
    end

    sending = true
    publishStatus()
    diag("send_start", "task", task.task_id, "channel", task.channel,
        "retry", task.retry, "queue", #tasks)
    local result = channel_registry.send(task.channel, deliveryEnvelope(task), config)
    sending = false
    diag("send_result", "task", task.task_id, "channel", task.channel,
        "success", result.success == true, "class", tostring(result.failure_class or "none"))

    if result.success then
        if task.envelope.web_test_channel == task.channel then
            channel_tests[task.channel] = { state = "success", message_id = task.message_id, detail = "" }
        end
        consecutive_errors = 0
        last_success_tick = nowTick()
        local channel_config = config.CHANNELS and config.CHANNELS[task.channel]
        if type(channel_config) == "table" and channel_config.sms_mode == "all" then
            last_full_success_tick = last_success_tick
        end
        task.delivered = true
        if deletePersisted(task) then
            info("发送成功", task.task_id, task.channel)
            diag("removed", "task", task.task_id, "delivered", true, "queue_before", #tasks)
            removeTask(index)
        else
            persistence_errors = persistence_errors + 1
            task.next_attempt = after(nowTick(), RETRY_DELAYS[#RETRY_DELAYS])
            log.error("notify", "发送成功但删除持久化记录失败", task.task_id)
            publishStatus()
        end
        return
    end

    if task.envelope.web_test_channel == task.channel then
        channel_tests[task.channel] = {
            state = result.failure_class == "configuration" and "failed" or "retrying",
            message_id = task.message_id,
            detail = tostring(result.detail or result.failure_class or "send_failed"),
        }
        if result.failure_class == "configuration" then
            if deletePersisted(task) then removeTask(index) end
            return
        end
    end
    consecutive_errors = consecutive_errors + 1
    task.retry = task.retry + 1
    local delay = retryDelay(task.retry)
    task.next_attempt = after(nowTick(), delay)
    log.error("notify", "发送失败，任务已保留", task.task_id, task.channel,
        result.failure_class or "unknown", result.detail or "unknown")
    diag("retry_scheduled", "task", task.task_id, "channel", task.channel,
        "retry", task.retry, "delay_ms", delay)
    publishStatus()
end

local function findDue(now)
    for index, task in ipairs(tasks) do
        if due(now, task.next_attempt) then return index, task end
    end
end

local function worker()
    local network_was_ready = false
    while true do
        local network_ready = util_network.isReady()
        if not network_ready then
            network_was_ready = false
            diag("network_wait", "adapter", util_network.currentAdapter() or -1, "queue", #tasks)
            sys.waitUntil("NETWORK_READY", 10000)
        else
            if not network_was_ready then
                diag("network_ready", "adapter", util_network.currentAdapter() or -1,
                    "queue", #tasks)
                network_was_ready = true
            end
            local index, task = findDue(nowTick())
            if task then
                process(index, task)
                sys.wait(100)
            else
                sys.waitUntil("NOTIFY_WAKE", 10000)
            end
        end
    end
end

function util_notify.isBarkEnabled()
    return bark_enabled
end

function util_notify.setBarkEnabled(enabled)
    bark_enabled = enabled == true
    publishStatus()
    return bark_enabled
end

function util_notify.toggleBark()
    return util_notify.setBarkEnabled(not bark_enabled)
end

function util_notify.getStatus()
    local now = nowTick()
    local retrying = 0
    local persisted = 0
    local oldest
    for _, task in ipairs(tasks) do
        if task.retry > 0 or task.delivered then retrying = retrying + 1 end
        if task.persisted then persisted = persisted + 1 end
        local age = elapsed(now, task.created_tick) or 0
        if not oldest or age > oldest then oldest = age end
    end
    local enabled_channels = 0
    for _, channel_config in pairs(config.CHANNELS or {}) do
        if type(channel_config) == "table" and channel_config.enabled ~= false then
            enabled_channels = enabled_channels + 1
        end
    end
    return {
        queue_length = #tasks,
        retrying_count = retrying,
        persisted_count = persisted,
        persistence_errors = persistence_errors,
        corrupt_records = corrupt_records,
        route_errors = route_errors,
        consecutive_errors = consecutive_errors,
        oldest_task_ms = oldest or 0,
        last_success_tick = last_success_tick,
        last_full_success_tick = last_full_success_tick,
        bark_enabled = bark_enabled,
        enabled_channels = enabled_channels,
        sending = sending,
        configuration_error = configuration_error,
    }
end

function util_notify.init()
    if initialized then return end
    initialized = true

    -- 通知渠道页面中的 CHANNELS.bark.enabled 是当前唯一配置来源。
    -- 旧版本曾单独持久化 Bark 开关；不能让旧的 false 覆盖网页刚保存的 true。
    bark_enabled = false
    for _, channel_name in ipairs(util_router.sortedChannelNames(config)) do
        local channel_config = config.CHANNELS[channel_name]
        if type(channel_config) == "table"
            and channel_config.enabled ~= false
            and channel_config.type == "bark" then
            bark_enabled = true
            break
        end
    end
    local enabled_count = 0
    for _, channel_name in ipairs(util_router.sortedChannelNames(config)) do
        local channel_config = config.CHANNELS[channel_name]
        if type(channel_config) == "table" then
            local channel_enabled = channel_config.enabled ~= false
            local policy_valid, policy_detail = util_router.validatePolicy(channel_name, channel_config, config)
            local transport_valid, transport_detail = channel_registry.validate(channel_name, config)
            if channel_enabled then
                enabled_count = enabled_count + 1
            end
            if channel_enabled and (not policy_valid or not transport_valid) then
                configuration_error = true
                log.error("notify", "渠道配置错误", channel_name,
                    policy_detail or transport_detail or "unknown")
            end
        end
    end
    diag("init", "enabled_channels", enabled_count,
        "configuration_error", configuration_error, "bark_enabled", bark_enabled)

    local restore_ok = pcall(restore)
    if not restore_ok then
        persistence_errors = persistence_errors + 1
        log.error("notify", "持久化任务恢复失败")
    end
    sys.taskInit(worker)
    publishStatus()
end

function util_notify.logChannelConfig()
    local count = 0
    local success = true
    for _, channel_name in ipairs(util_router.sortedChannelNames(config)) do
        local channel_config = config.CHANNELS and config.CHANNELS[channel_name]
        if type(channel_config) == "table" then
            local encoded_ok, encoded = pcall(json.encode, channel_config)
            if encoded_ok and type(encoded) == "string" then
                dumpInfo("channel_config_dump", channel_name, encoded)
            else
                success = false
                log.error("notify", "channel config encoding failed", channel_name)
            end
            count = count + 1
        end
    end
    dumpInfo("channel_config_dump_done", "channels", count)
    return success, count
end

return util_notify
