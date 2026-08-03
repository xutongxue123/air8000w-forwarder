-- Air8000W 短信转发项目专用网络选择器。
-- 仅保留 Wi-Fi STA、蜂窝 4G、优先级切换和连通性复检。

local httpdns = require "httpdns"

local exnetif = {}

local PROBE_HOST = "baidu.com"
local PROBE_TIMEOUT_MS = 3000
local PROBE_RETRY_MS = 10 * 1000

local priority = {}
local states = {}
local current_adapter
local status_callback = function() end

local function typeName(adapter)
    if adapter == socket.LWIP_STA then return "WiFi" end
    if adapter == socket.LWIP_GP then return "4G" end
    return "Unknown"
end

local function hasIp(adapter)
    local ok, ip = pcall(socket.localIP, adapter)
    return ok and type(ip) == "string" and ip ~= "" and ip ~= "0.0.0.0"
end

local function publish(adapter)
    if current_adapter == adapter then return end
    current_adapter = adapter
    if adapter == nil then
        log.warn("exnetif", "没有通过连通性检查的网络")
        status_callback(nil, -1)
        sys.publish("EXLIB_NETDRV_NETWORK_STATUS", nil, -1)
        return
    end
    local net_type = typeName(adapter)
    socket.dft(adapter)
    log.info("exnetif", "网络可用", "type", net_type, "adapter", adapter)
    status_callback(net_type, adapter)
    sys.publish("EXLIB_NETDRV_NETWORK_STATUS", net_type, adapter)
end

local function applyPriority()
    for _, adapter in ipairs(priority) do
        local state = states[adapter]
        if state and state.usable then
            publish(adapter)
            return
        end
    end
    if current_adapter ~= nil then publish(nil) end
end

local function probe(adapter)
    local state = states[adapter]
    if not state or not state.configured or not state.link_ready then return end
    state.generation = state.generation + 1
    local generation = state.generation
    state.usable = false
    state.last_probe_result = nil
    applyPriority()

    sys.taskInit(function()
        while state.configured and state.link_ready
            and state.generation == generation do
            local ok, ip = pcall(httpdns.ali, PROBE_HOST, {
                adapter = adapter,
                timeout = PROBE_TIMEOUT_MS,
            })
            local success = ok and type(ip) == "string" and ip ~= ""
            if state.last_probe_result ~= success then
                state.last_probe_result = success
                log.info("exnetif", "连通性检查", "type", typeName(adapter),
                    "adapter", adapter, "success", success)
            end
            state.usable = success
            applyPriority()
            if success then return end
            sys.wait(PROBE_RETRY_MS)
        end
    end)
end

local function ipReady(_, adapter)
    local state = states[adapter]
    if not state or not state.configured then return end
    local already_usable = state.link_ready and state.usable
    state.link_ready = true
    log.info("exnetif", "网卡取得IP", "type", typeName(adapter), "adapter", adapter)
    if not already_usable then probe(adapter) end
end

local function ipLose(adapter)
    local state = states[adapter]
    if not state or not state.configured then return end
    state.generation = state.generation + 1
    state.link_ready = false
    state.usable = false
    state.last_probe_result = nil
    log.warn("exnetif", "网卡失去IP", "type", typeName(adapter), "adapter", adapter)
    applyPriority()
end

local function addAdapter(adapter)
    if states[adapter] and states[adapter].configured then return end
    states[adapter] = {
        configured = true,
        link_ready = hasIp(adapter),
        usable = false,
        generation = 0,
    }
    table.insert(priority, adapter)
end

local function configureWifi(wifi)
    if type(wifi.ssid) ~= "string" or wifi.ssid == "" then
        log.error("exnetif", "Wi-Fi SSID 为空")
        return false
    end
    addAdapter(socket.LWIP_STA)
    wlan.init()
    local ok, result = pcall(wlan.connect, wifi.ssid,
        tostring(wifi.password or ""), 1)
    if not ok or result == false then
        log.error("exnetif", "Wi-Fi STA 初始化失败")
        return false
    end
    log.info("exnetif", "Wi-Fi STA 已启动", "adapter", socket.LWIP_STA)
    return true
end

local function configureCellular()
    addAdapter(socket.LWIP_GP)
    pcall(mobile.flymode, nil, false)
    log.info("exnetif", "4G 数据网卡已启用", "adapter", socket.LWIP_GP)
    return true
end

function exnetif.notify_status(callback)
    if type(callback) ~= "function" then
        log.error("exnetif", "网络状态回调必须是 function")
        return false
    end
    status_callback = callback
    return true
end

function exnetif.set_priority_order(configs)
    if type(configs) ~= "table" or #configs == 0 then
        log.error("exnetif", "网络配置为空")
        return false
    end

    for _, state in pairs(states) do
        state.configured = false
        state.generation = state.generation + 1
    end
    priority = {}
    current_adapter = nil

    for _, item in ipairs(configs) do
        local ok
        if type(item.WIFI) == "table" then
            ok = configureWifi(item.WIFI)
        elseif item.LWIP_GP == true then
            ok = configureCellular()
        else
            log.error("exnetif", "存在项目不支持的网络配置")
            return false
        end
        if not ok then return false end
    end

    socket.dft(priority[1])
    for _, adapter in ipairs(priority) do
        local state = states[adapter]
        state.link_ready = state.link_ready or hasIp(adapter)
        if state.link_ready then probe(adapter) end
    end
    return true
end

function exnetif.check_network_status()
    for _, adapter in ipairs(priority) do
        local state = states[adapter]
        if state and state.configured then
            state.link_ready = hasIp(adapter)
            if state.link_ready then
                probe(adapter)
            else
                state.generation = state.generation + 1
                state.usable = false
            end
        end
    end
    applyPriority()
    return true
end

function exnetif.version()
    return "air8000w-forwarder-20260730"
end

sys.subscribe("IP_READY", ipReady)
sys.subscribe("IP_LOSE", ipLose)

return exnetif
