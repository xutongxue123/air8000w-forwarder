local util_notify = require "util_notify"
local util_history = require "util_history"

local util_call = {}

local started = false
local last_notified_state
local current_number = ""
local cc_module
local cc_capability_logged = false
local system_ready = false

local DEFAULT_EVENTS = {
    INCOMINGCALL = true,
    CONNECTED = false,
    DISCONNECTED = false,
    SPEECH_START = false,
    MAKE_CALL_OK = false,
    MAKE_CALL_FAILED = false,
    ANSWER_CALL_DONE = false,
    HANGUP_CALL_DONE = false,
}

local STATE_LABELS = {
    INCOMINGCALL = "来电呼入",
    CONNECTED = "电话已接通",
    DISCONNECTED = "通话已断开",
    SPEECH_START = "语音通话开始",
    MAKE_CALL_OK = "拨号请求成功",
    MAKE_CALL_FAILED = "拨号请求失败",
    ANSWER_CALL_DONE = "接听完成",
    HANGUP_CALL_DONE = "挂断完成",
}

local function callConfig()
    return type(config.CALL) == "table" and config.CALL or {}
end

local function cellularFlightMode()
    local network = type(config.NETWORK) == "table" and config.NETWORK or {}
    return network.cellular_flight_mode == true
end

local function info(...)
    if type(USER_LOG_INFO) == "function" then
        USER_LOG_INFO("call", ...)
    else
        log.info("call", ...)
    end
end

local function diag(event, ...)
    if type(USER_DIAG) ~= "function" then return end
    if type(config.LOGGING) ~= "table" and config.DIAGNOSTIC_LOGS ~= true then return end
    USER_DIAG("call", event, ...)
end

-- Air8000W 的 cc 是固件内置只读库，不能用普通 Lua table 类型判断。
-- 直接探测 lastNum 能力，避免把已经注册的核心库误判为不可用。
local function loadCc()
    if cc_module ~= nil then return cc_module end

    local global_cc = _G.cc
    if global_cc == nil and type(package) == "table" and type(package.loaded) == "table" then
        global_cc = package.loaded.cc
    end
    if global_cc ~= nil then
        local ok, last_num = pcall(function() return global_cc.lastNum end)
        if not ok or type(last_num) ~= "function" then return nil end
        cc_module = global_cc
        if not cc_capability_logged then
            cc_capability_logged = true
            info("号码接口可用", "source", "cc.lastNum", "module_type", type(global_cc))
        end
        return cc_module
    end
    return nil
end

local function lastNumber()
    local call_api = loadCc()
    if call_api == nil then return "" end
    local api_ok, last_num = pcall(function() return call_api.lastNum end)
    if not api_ok or type(last_num) ~= "function" then return "" end
    local ok, number = pcall(last_num)
    if not ok or type(number) ~= "string" then return "" end
    return number
end

local function numberFromValue(value)
    if type(value) == "table" then
        value = value.number or value.phone or value.caller or value.caller_number
    end
    if type(value) == "number" then value = tostring(value) end
    if type(value) ~= "string" then return "" end
    value = value:match("^%s*(.-)%s*$") or ""
    local compact = value:gsub("[%s%-%(%)]", "")
    if compact:match("^%+?%d%d%d%d%d+$") then return compact end
    return ""
end

local function eventEnabled(state)
    local events = callConfig().events
    if type(events) == "table" then return events[state] == true end
    return DEFAULT_EVENTS[state] == true
end

local function eventTime()
    local now = os.time()
    if type(now) == "number" and now >= 1714500000 then
        return os.date("%Y-%m-%d %H:%M:%S")
    end
    return "开机后 " .. tostring(math.floor(mcu.ticks() / 1000)) .. " 秒（时间未同步）"
end

local function markSystemReady(source)
    if system_ready then return end
    system_ready = true
    info("电话系统已就绪", "source", source)
end

local function handleState(state, value, extra)
    if cellularFlightMode() then return end
    state = tostring(state or "UNKNOWN")
    if state == "READY" then
        info("模块就绪")
        diag("state", "state", state)
        markSystemReady("CC_IND_READY")
        return
    end
    if state == "PLAY" then
        diag("state", "state", state)
        return
    end

    -- 官方 Air8000 示例在 INCOMINGCALL 中通过 cc.lastNum() 取得主叫号码。
    -- CC_IND 参数只作为不同固件实现的兼容回退。
    local number = lastNumber()
    if number == "" then number = numberFromValue(value) end
    if number == "" then number = numberFromValue(extra) end
    if number ~= "" then current_number = number end
    number = current_number
    info("事件", "state", state, "number", number ~= "" and number or "未知号码")
    diag("state", "state", state, "number", number ~= "" and number or "unknown")

    -- 部分固件会单独发布号码事件；只缓存号码，不创建远程通知。
    if state == "CALL_NUMBER" or state == "CONNECTED_NUMBER" then return end

    local duplicate = last_notified_state == state
    last_notified_state = state
    local label = STATE_LABELS[state] or state
    local received_at = eventTime()
    if state == "INCOMINGCALL" and not duplicate then
        util_history.addCall(number, state, received_at)
    end
    if not eventEnabled(state) or duplicate then
        if state == "DISCONNECTED" then current_number = "" end
        return
    end
    local ok = util_notify.addCall({
        sender = number,
        content = "#CALL_" .. state .. "\n状态: " .. label,
        received_at = received_at,
        call_state = state,
    })
    if not ok then
        log.warn("call", "通话事件没有可用通知渠道", state)
    end
    if state == "DISCONNECTED" then current_number = "" end
end

function util_call.init()
    if started or callConfig().enabled ~= true then return false end
    started = true
    sys.subscribe("CC_IND", handleState)
    sys.subscribe("CC_READY", function()
        markSystemReady("CC_READY")
    end)
    -- 通话状态由 mobile 层的 CC_IND 驱动，来电号码由 cc.lastNum() 读取。
    info("事件监听已注册", "event", "CC_IND", "mode", "passive")
    return true
end

return util_call
