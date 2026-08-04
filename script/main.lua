PROJECT = "air8000w_forwarder"
VERSION = "1.0.0"

sys = require "sys"
config = require "config"

local logging_config = type(config.LOGGING) == "table" and config.LOGGING or {}
local configured_log_level = type(logging_config.level) == "string"
    and logging_config.level or "INFO"
-- Set the level before requiring modules that probe the filesystem during startup.
log.setLevel(configured_log_level)

local fskv_ready = fskv.init()
local util_web = require "util_web"
util_web.applySavedConfig()

function USER_LOG_INFO(component, ...)
    if logging_config.operational ~= false then
        log.info(component, ...)
    end
end

function USER_DIAG(component, event, ...)
    local diagnostic = logging_config.diagnostic
    if type(diagnostic) == "table" then
        if diagnostic.enabled ~= true or diagnostic[component] == false then return end
    elseif config.DIAGNOSTIC_LOGS ~= true then
        return
    end
    log.info("diag", component, event, ...)
end

USER_LOG_INFO("main", PROJECT, VERSION)
USER_LOG_INFO("main", "开机原因", pm.lastReson())

wdt.init(9000)
sys.timerLoopStart(wdt.feed, 3000)

local network_config = type(config.NETWORK) == "table" and config.NETWORK or {}
local cellular_recovery_period = network_config.cellular_data_enabled == true
    and network_config.cellular_flight_mode ~= true and 60000 or nil
mobile.setAuto(10000, 0, 8, nil, cellular_recovery_period)
mobile.ipv6(config.IPV6_ENABLED == true)

USER_LOG_INFO("main", "fskv.init", fskv_ready)

local util_mobile = require "util_mobile"
local util_network = require "util_network"
local util_notify = require "util_notify"
local util_call = require "util_call"
local util_history = require "util_history"
local util_sms_command = require "util_sms_command"

local last_sms_tick = 0
local TICK_MODULO = 4294967296
local VALID_TIME_EPOCH = 1714500000
local TIME_READY_RECHECK_MS = 1000
local startup_network_notified = false
local startup_network_time_waiting = false
local startup_sms_ready = false
local startup_sms_notified = false
local startup_sms_time_waiting = false

local NETWORK_NOTIFICATION_TYPES = {
    WiFi = true,
    ["4G"] = true,
    Ethernet = true,
}

local function startupPowerReason()
    local ok, reason = pcall(pm.lastReson)
    if not ok or reason == nil then return "unknown" end
    return tostring(reason)
end

local function notifyStartupNetwork()
    if config.BOOT_NOTIFY ~= true or startup_network_notified then return end
    local status = util_network.getStatus()
    if status.ready ~= true then return end

    local now = os.time()
    if type(now) ~= "number" or now < VALID_TIME_EPOCH then
        if not startup_network_time_waiting then
            startup_network_time_waiting = true
            USER_DIAG("startup", "network_ready_wait_time")
            util_network.syncTime()
            sys.timerStart(function()
                startup_network_time_waiting = false
                notifyStartupNetwork()
            end, TIME_READY_RECHECK_MS)
        end
        return
    end

    local network_type = status.network_type
    if not NETWORK_NOTIFICATION_TYPES[network_type] then
        network_type = "Unknown"
    end
    startup_network_notified = true
    USER_DIAG("startup", "network_ready_notify", "type", network_type)
    local ok = pcall(util_notify.addSystem,
        "#NETWORK_READY_" .. network_type, true, false)
    if not ok then log.error("startup", "联网就绪通知创建失败") end
end

local function notifyStartupSms()
    if config.BOOT_NOTIFY ~= true or not startup_sms_ready or startup_sms_notified then return end
    local status = util_network.getStatus()
    if status.ready ~= true then return end

    local now = os.time()
    if type(now) ~= "number" or now < VALID_TIME_EPOCH then
        if not startup_sms_time_waiting then
            startup_sms_time_waiting = true
            USER_DIAG("startup", "sms_ready_wait_time")
            if not startup_network_time_waiting then util_network.syncTime() end
            sys.timerStart(function()
                startup_sms_time_waiting = false
                notifyStartupSms()
            end, TIME_READY_RECHECK_MS)
        end
        return
    end

    startup_sms_notified = true
    local reason = startupPowerReason()
    USER_DIAG("startup", "sms_ready_notify", "reason", reason)
    local ok = pcall(util_notify.addSystem,
        "#SMS_READY_BOOT_" .. reason, true, true)
    if not ok then log.error("startup", "短信就绪通知创建失败") end
end

local function markStartupSmsReady()
    startup_sms_ready = true
    notifyStartupSms()
end

local function formatDuration(total_seconds)
    total_seconds = math.max(0, math.floor(tonumber(total_seconds) or 0))
    local days = math.floor(total_seconds / 86400)
    local hours = math.floor(total_seconds / 3600) % 24
    local minutes = math.floor(total_seconds / 60) % 60
    local seconds = total_seconds % 60
    return string.format("%dd %02d:%02d:%02d", days, hours, minutes, seconds)
end

local function formatUptime(total_seconds)
    total_seconds = math.max(0, math.floor(tonumber(total_seconds) or 0))
    local days = math.floor(total_seconds / 86400)
    local hours = math.floor(total_seconds / 3600) % 24
    local minutes = math.floor(total_seconds / 60) % 60
    local seconds = total_seconds % 60
    return string.format("%d天%d小时%d分%d秒", days, hours, minutes, seconds)
end

local function formatTickAge(last_tick, now_tick)
    if type(last_tick) ~= "number" or last_tick <= 0 then return "never" end
    local delta = now_tick - last_tick
    if delta < 0 then delta = delta + TICK_MODULO end
    return formatDuration(delta / 1000)
end

local function formatMemory(used, total)
    if type(used) ~= "number" or type(total) ~= "number" then return "unknown" end
    return string.format("%d/%dKB", math.floor(used / 1024), math.floor(total / 1024))
end

local function smsTime(metadata)
    if type(metadata) == "table"
        and type(metadata.year) == "number" and type(metadata.mon) == "number"
        and type(metadata.day) == "number" and type(metadata.hour) == "number"
        and type(metadata.min) == "number" and type(metadata.sec) == "number" then
        return string.format("%d/%02d/%02d %02d:%02d:%02d",
            metadata.year + 2000, metadata.mon, metadata.day,
            metadata.hour, metadata.min, metadata.sec)
    end
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function snapshot()
    local now_tick = mcu.ticks()
    local notify = util_notify.getStatus()
    local history = util_history.getStats()
    local total_lua, used_lua = rtos.meminfo("lua")
    local total_sys, used_sys = rtos.meminfo("sys")
    local fskv_ok, fskv_used, fskv_total, fskv_count = pcall(fskv.status)
    local fs_call_ok, fs_ok, fs_total_blocks, fs_used_blocks, fs_block_size, fs_type =
        pcall(io.fsstat, "/")
    local fs_ready = fs_call_ok and fs_ok == true
        and type(fs_total_blocks) == "number" and type(fs_used_blocks) == "number"
        and type(fs_block_size) == "number"
    local fs_total_bytes = fs_ready and fs_total_blocks * fs_block_size or nil
    local fs_used_bytes = fs_ready and fs_used_blocks * fs_block_size or nil
    local network = util_network.getStatus()
    local service_cell = type(util_mobile.serviceCell) == "function"
        and util_mobile.serviceCell() or {}
    return {
        now_tick = now_tick,
        uptime = formatUptime(now_tick / 1000),
        sim_ready = mobile.simPin(mobile.simid()),
        network_code = mobile.status(),
        network_text = util_mobile.status(),
        operator = util_mobile.operator(),
        local_number = util_mobile.localNumber(),
        data_ready = network.ready,
        data_type = network.network_type or "none",
        data_adapter = network.adapter or -1,
        cellular_data_enabled = network.cellular_data_enabled == true,
        cellular_flight_mode = network.cellular_flight_mode == true,
        cellular_local_ip = network.cellular_local_ip or "none",
        wifi_enabled = network.wifi_enabled,
        wifi_connected = network.wifi_connected,
        wifi_adapter = network.wifi_adapter or -1,
        wifi_local_ip = network.wifi_local_ip or "none",
        wifi_rssi = network.wifi_rssi or "unknown",
        wifi_rssi_source = network.wifi_rssi_source or "unknown",
        rsrp = mobile.rsrp(), rsrq = mobile.rsrq(), snr = mobile.snr(),
        cell = {
            eci = service_cell.eci or service_cell.cid,
            pci = service_cell.pci,
            earfcn = service_cell.earfcn,
            band = service_cell.band,
        },
        notify = notify,
        last_sms = formatTickAge(last_sms_tick, now_tick),
        last_success = formatTickAge(notify.last_success_tick, now_tick),
        last_full = formatTickAge(notify.last_full_success_tick, now_tick),
        lua_mem = formatMemory(used_lua, total_lua),
        sys_mem = formatMemory(used_sys, total_sys),
        fskv_mem = fskv_ok and formatMemory(fskv_used, fskv_total) or "unknown",
        fskv_count = fskv_ok and fskv_count or "unknown",
        fs_mem = fs_ready and formatMemory(fs_used_bytes, fs_total_bytes) or "unknown",
        fs_free = fs_ready and formatMemory(fs_total_bytes - fs_used_bytes, fs_total_bytes) or "unknown",
        fs_type = fs_ready and tostring(fs_type or "unknown") or "unknown",
        history_storage = history.storage,
        history_records = history.records,
        history_sms_count = history.sms_count,
        history_call_count = history.call_count,
        history_bytes = history.bytes,
        history_budget = history.budget,
        history_corrupt_records = history.corrupt_records,
        history_last_compact = history.last_compact,
    }
end

util_web.setStatusProvider(snapshot)
util_web.init()

local function logHealthStatus()
    local ok, value = pcall(snapshot)
    if not ok then
        log.error("health", "状态采集失败")
        return
    end
    local notify = value.notify
    local function networkLine(name, enabled, ip, signal)
        return table.concat({
            name,
            enabled and "ON" or "OFF",
            tostring(ip or "none"),
            tostring(signal or "unknown"),
        }, " ")
    end
    local fields = {
        "up", value.uptime,
        "sim", value.sim_ready,
        networkLine("WIFI", value.wifi_enabled, value.wifi_local_ip, value.wifi_rssi),
        networkLine("4G", value.cellular_data_enabled, value.cellular_local_ip, value.rsrp),
        "q", notify.queue_length,
        "retry", notify.retrying_count,
        "corrupt", notify.corrupt_records,
        "err", notify.consecutive_errors,
        "cfgerr", notify.configuration_error,
        "old", formatDuration(notify.oldest_task_ms / 1000),
        "lsms", value.last_sms,
        "lpush", value.last_success,
        "lfull", value.last_full,
        "lmem", value.lua_mem,
        "smem", value.sys_mem,
        "fsm", value.fs_mem,
        "fst", value.fs_type,
        "hb", value.history_bytes,
        "hcor", value.history_corrupt_records,
    }
    for index, field in ipairs(fields) do fields[index] = tostring(field) end
    log.info("health " .. table.concat(fields, " "))
end

sms.setNewSmsCb(function(sender_number, sms_content, metadata)
    if type(util_network.isFlightMode) == "function" and util_network.isFlightMode() then return end
    sender_number = tostring(sender_number or "")
    sms_content = tostring(sms_content or "")
    last_sms_tick = mcu.ticks()
    USER_LOG_INFO("sms", "收到短信", "length", #sms_content)
    local received_at = smsTime(metadata)
    local command_consumed = util_sms_command.handle(sms_content)
    if command_consumed then return end
    util_history.addSms(sender_number, sms_content, received_at)
    util_notify.addSms({
        sender = sender_number,
        content = sms_content,
        received_at = received_at,
    })
end)

util_network.init()
util_notify.init()
util_call.init()
sys.subscribe("NETWORK_STATUS_CHANGED", function(ready)
    if ready then
        notifyStartupNetwork()
        notifyStartupSms()
    end
end)
sys.subscribe("SMS_READY", markStartupSmsReady)

notifyStartupNetwork()

local health_config = type(logging_config.health) == "table" and logging_config.health or {}
local health_interval = tonumber(health_config.interval)
    or tonumber(config.HEALTH_INTERVAL) or 15 * 60 * 1000
local health_first_delay = tonumber(health_config.first_delay) or 10 * 60 * 1000
if health_config.enabled ~= false and health_interval > 0 then
    sys.timerStart(function()
        logHealthStatus()
        sys.timerLoopStart(logHealthStatus, health_interval)
    end, math.max(0, health_first_delay))
end

sys.taskInit(function()
    local ready = util_network.isReady()
    if not ready then
        ready = sys.waitUntil("NETWORK_READY", config.NETWORK_READY_TIMEOUT or 5 * 60 * 1000)
    end
    if ready and os.time() < VALID_TIME_EPOCH then util_network.syncTime() end
end)

sys.taskInit(function()
    if type(config.PIN_CODE) ~= "string" or config.PIN_CODE == "" then return end
    sys.wait(5000)
    if util_network.isFlightMode() then return end
    util_mobile.pinVerify(config.PIN_CODE)
end)

sys.run()
