local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local test_dir = source:match("^(.*[/])") or "tests/"
package.path = test_dir .. "../script/?.lua;" .. test_dir .. "?.lua;" .. (package.path or "")
local support = dofile(test_dir .. "test_support.lua")

local function runScenario(network_config)
    local status_callback
    local priority
    local events, dns_calls = {}, {}
    local checks, sntp_adapter = 0, nil
    local logs = {}
    local wifi_rssi = -57
    local local_ip = "192.0.2.1"
    local local_ips = { [1] = "198.51.100.1", [2] = local_ip }
    local subscriptions = {}

    config = { DIAGNOSTIC_LOGS = true, DNS_SERVERS = { "223.5.5.5", "119.29.29.29" }, NETWORK = network_config }
    log = {
        info = function(...) table.insert(logs, { ... }) end,
        warn = function(...) table.insert(logs, { ... }) end,
        error = function(...) table.insert(logs, { ... }) end,
    }
    USER_DIAG = function(...) table.insert(logs, { ... }) end
    socket = {
        setDNS = function(adapter, index, server) table.insert(dns_calls, { adapter, index, server }) end,
        localIP = function(adapter) return local_ips[adapter] end,
        sntp = function(_, adapter) sntp_adapter = adapter return true end,
    }
    wlan = {
        getInfo = function() return { rssi = wifi_rssi, bssid = "private-bssid", gw = "private-gateway" } end,
    }
    sys = {
        publish = function(...) table.insert(events, { ... }) end,
        taskInit = function(handler) handler() end,
    }
    package.loaded.exnetif = {
        notify_status = function(callback) status_callback = callback return true end,
        set_priority_order = function(value) priority = value return true end,
        check_network_status = function() checks = checks + 1 end,
    }
    package.loaded.util_network = nil
    local util_network = require "util_network"
    support.assertTrue(util_network.init(), "network init")
    support.assertTrue(type(status_callback) == "function", "exnetif callback captured")
    support.assertTrue(type(priority) == "table", "priority task configured")
    support.assertTrue(#dns_calls >= 2, "DNS configured")

    status_callback("WiFi", 2)
    support.assertTrue(util_network.isReady(), "permitted Wi-Fi is ready")
    support.assertEqual(util_network.currentAdapter(), 2, "Wi-Fi adapter active")
    support.assertTrue(util_network.syncTime(), "SNTP sync")
    support.assertEqual(sntp_adapter, 2, "SNTP uses active adapter")
    support.assertEqual(events[#events - 1][1], "NETWORK_READY", "network ready event")
    support.assertEqual(events[#events][1], "NOTIFY_WAKE", "notification wake event")

    status_callback("4G", 1)
    if network_config.cellular_data_enabled == true then
        support.assertEqual(util_network.currentAdapter(), 1, "permitted cellular is accepted")
    else
        support.assertEqual(util_network.currentAdapter(), nil, "disabled cellular is rejected")
    end
    status_callback("Unknown", 99)
    support.assertFalse(util_network.isReady(), "unknown adapter loses network")
    util_network.reportFailure()
    support.assertEqual(checks, 1, "network status recheck")

    local status = util_network.getStatus()
    support.assertEqual(status.wifi_local_ip, local_ip, "Wi-Fi IP in status")
    support.assertEqual(status.wifi_rssi, wifi_rssi, "Wi-Fi RSSI in status")
    support.assertEqual(status.wifi_rssi_source, "getInfo", "RSSI source in status")
    support.assertEqual(status.wifi_adapter, tonumber(network_config.wifi_adapter), "configured Wi-Fi adapter")
    support.assertEqual(status.cellular_data_enabled, network_config.cellular_data_enabled == true,
        "cellular data enabled in status")
    support.assertEqual(status.cellular_local_ip,
        network_config.cellular_data_enabled == true and local_ips[1] or "none",
        "cellular IP in status")
    return util_network, subscriptions, logs, status
end

local util_network, _, _, wifi_status = runScenario({
    cellular_data_enabled = true, cellular_adapter = 1, wifi_adapter = 2,
    wifi = { enabled = true, ssid = "ap", password = "password" },
})

local _, _, fallback_logs, fallback_status = runScenario({
    cellular_data_enabled = false, cellular_adapter = 1, wifi_adapter = 2,
    wifi = { enabled = true, ssid = "ap", password = "password" },
})
support.assertTrue(util_network ~= nil and fallback_logs ~= nil, "network scenarios loaded")
support.assertEqual(wifi_status.cellular_local_ip, "198.51.100.1", "enabled cellular IP is reported")
support.assertEqual(fallback_status.cellular_local_ip, "none", "disabled cellular IP is hidden")

config = { NETWORK = { cellular_data_enabled = false, wifi_adapter = 2, cellular_adapter = 1, wifi = { enabled = false } } }
socket = { setDNS = function() end, localIP = function() return "0.0.0.0" end }
package.loaded.exnetif = { notify_status = function() return true end, set_priority_order = function() return true end }
package.loaded.util_network = nil
local no_network = require "util_network"
support.assertTrue(no_network.init(), "network init without configured adapter")

print("util_network tests passed")
