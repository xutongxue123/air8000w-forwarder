local exnetif = require "exnetif"

local util_network = {}

local initialized = false
local ready = false
local active_adapter
local active_type
local wifi_adapter = 2
local cellular_adapter = 1
local cellular_data_enabled = false

local function diag(event, ...)
    if type(USER_DIAG) ~= "function" then return end
    if type(config.LOGGING) ~= "table" and config.DIAGNOSTIC_LOGS ~= true then return end
    USER_DIAG("network", event, ...)
end

local function info(...)
    if type(USER_LOG_INFO) == "function" then
        USER_LOG_INFO("network", ...)
    else
        log.info("network", ...)
    end
end

local function networkConfig()
    return type(config.NETWORK) == "table" and config.NETWORK or {}
end

local function isPermitted(adapter)
    return adapter == wifi_adapter
        or (cellular_data_enabled and adapter == cellular_adapter)
end

local function publishState(next_ready, net_type, adapter)
    next_ready = next_ready == true and isPermitted(adapter)
    local next_adapter = next_ready and adapter or nil
    local next_type = next_ready and tostring(net_type or "unknown") or nil
    if ready == next_ready and active_adapter == next_adapter and active_type == next_type then
        return
    end

    ready = next_ready
    active_adapter = next_adapter
    active_type = next_type
    info("状态变化", "ready", ready, "type", active_type or "none",
        "adapter", active_adapter or -1)
    sys.publish("NETWORK_STATUS_CHANGED", ready, active_type, active_adapter)
    if ready then
        sys.publish("NETWORK_READY", active_adapter, active_type)
        sys.publish("NOTIFY_WAKE")
    else
        sys.publish("NETWORK_LOST")
    end
end

local function statusChanged(net_type, adapter)
    if type(net_type) == "string" and type(adapter) == "number" and isPermitted(adapter) then
        publishState(true, net_type, adapter)
        if adapter == wifi_adapter then
            local ok, ip = pcall(socket.localIP, wifi_adapter)
            if ok and type(ip) == "string" and ip ~= "" and ip ~= "0.0.0.0" then
                info("Wi-Fi local IP", ip)
            end
        end
    else
        publishState(false)
    end
end

local function validRssi(value)
    local number = tonumber(value)
    if number and number >= -127 and number <= 0 then
        return number
    end
end

local function wlanMethod(name)
    if wlan == nil then return nil end
    local ok, method = pcall(function() return wlan[name] end)
    return ok and type(method) == "function" and method or nil
end

local function wifiRssi()
    if wlan == nil then
        return "unknown", "wlan_unavailable"
    end

    local info_reason = "getInfo_unavailable"
    local get_info = wlanMethod("getInfo")
    if get_info then
        local ok, info = pcall(get_info)
        if ok and type(info) == "table" then
            local rssi = validRssi(info.rssi)
            if rssi then return rssi, "getInfo" end
            info_reason = "getInfo_rssi_" .. type(info.rssi)
        elseif not ok then
            info_reason = "getInfo_error"
        else
            info_reason = "getInfo_" .. type(info)
        end
    end

    for _, method_name in ipairs({ "getRssi", "getRSSI", "getrssi" }) do
        local method = wlanMethod(method_name)
        if method then
            local ok, value = pcall(method)
            local rssi = ok and validRssi(value) or nil
            if rssi then return rssi, method_name end
            return "unknown", ok and (method_name .. "_" .. type(value))
                or (method_name .. "_error")
        end
    end
    return "unknown", info_reason
end

local function validIpv4(value)
    if type(value) ~= "string" then return nil end
    local a, b, c, d = value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    for _, octet in ipairs({ a, b, c, d }) do
        local number = tonumber(octet)
        if not number or number > 255 then return nil end
    end
    return value
end

local function localIp(adapter)
    local ok, ip = pcall(socket.localIP, adapter)
    return ok and validIpv4(ip) or nil
end

local function configureDns()
    local adapters = { wifi_adapter }
    if cellular_data_enabled and cellular_adapter ~= wifi_adapter then
        table.insert(adapters, cellular_adapter)
    end
    for _, adapter in ipairs(adapters) do
        for index, server in ipairs(config.DNS_SERVERS or {}) do
            pcall(socket.setDNS, adapter, index, server)
        end
    end
end

local function buildPriority()
    local priority = {}
    local network = networkConfig()
    local wifi = type(network.wifi) == "table" and network.wifi or {}
    if wifi.enabled ~= false then
        if type(wifi.ssid) == "string" and wifi.ssid ~= ""
            and type(wifi.password) == "string" and wifi.password ~= "" then
            table.insert(priority, {
                WIFI = {
                    ssid = wifi.ssid,
                    password = wifi.password,
                },
            })
        else
            log.warn("network", "Wi-Fi 配置不可用")
        end
    end
    if cellular_data_enabled then
        table.insert(priority, { LWIP_GP = true })
    end
    return priority
end

function util_network.init()
    if initialized then return true end
    initialized = true

    local network = networkConfig()
    wifi_adapter = tonumber(network.wifi_adapter) or 2
    cellular_adapter = tonumber(network.cellular_adapter) or 1
    cellular_data_enabled = network.cellular_data_enabled == true
    configureDns()
    diag("init", "mode", cellular_data_enabled and "wifi_cellular_fallback" or "wifi_only",
        "wifi_adapter", wifi_adapter)

    local notify_ok, notify_result = pcall(exnetif.notify_status, statusChanged)
    if not notify_ok or notify_result == false then
        log.error("network", "网络状态监听初始化失败")
    end

    sys.taskInit(function()
        local priority = buildPriority()
        if #priority == 0 then
            log.error("network", "没有可用的数据出口配置")
            publishState(false)
            return
        end
        local ok, result = pcall(exnetif.set_priority_order, priority)
        if not ok or result == false then
            log.error("network", "网络优先级初始化失败")
            publishState(false)
        end
    end)
    return true
end

function util_network.isReady()
    return ready
end

function util_network.currentAdapter()
    return ready and active_adapter or nil
end

function util_network.getStatus()
    local network = networkConfig()
    local wifi = type(network.wifi) == "table" and network.wifi or {}
    local wifi_enabled = wifi.enabled ~= false
    local wifi_ip = wifi_enabled and localIp(wifi_adapter) or nil
    local cellular_ip = cellular_data_enabled and localIp(cellular_adapter) or nil
    local wifi_connected = wifi_enabled
        and (wifi_ip ~= nil or (ready and active_adapter == wifi_adapter))
    local wifi_rssi, wifi_rssi_source = "unknown", "not_connected"
    if wifi_connected then
        wifi_rssi, wifi_rssi_source = wifiRssi()
    end
    return {
        ready = ready,
        adapter = active_adapter,
        network_type = active_type,
        cellular_data_enabled = cellular_data_enabled,
        cellular_local_ip = cellular_ip or "none",
        wifi_enabled = wifi_enabled,
        wifi_connected = wifi_connected,
        wifi_adapter = wifi_adapter,
        wifi_local_ip = wifi_ip or "none",
        wifi_rssi = wifi_rssi,
        wifi_rssi_source = wifi_rssi_source,
    }
end

function util_network.reportFailure()
    if type(exnetif.check_network_status) == "function" then
        pcall(exnetif.check_network_status)
    end
end

function util_network.syncTime()
    if not ready then return false end
    return pcall(socket.sntp, nil, active_adapter)
end

return util_network
