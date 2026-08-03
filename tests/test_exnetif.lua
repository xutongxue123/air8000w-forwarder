local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local test_dir = source:match("^(.*[/])") or "tests/"
package.path = test_dir .. "../script/?.lua;" .. test_dir .. "?.lua;" .. (package.path or "")
package.loaded.exnetif = nil
local probe_adapters = {}
package.loaded.httpdns = {
    ali = function(_, opts)
        table.insert(probe_adapters, opts.adapter)
        return "203.0.113.20"
    end,
}

local support = dofile(test_dir .. "test_support.lua")
local subscriptions, tasks, events, defaults = {}, {}, {}, {}
local callback
local ips = { [1] = "0.0.0.0", [2] = "0.0.0.0" }
local wifi_connect
local flymode_calls = 0

socket = {
    LWIP_GP = 1,
    LWIP_STA = 2,
    localIP = function(adapter) return ips[adapter] end,
    dft = function(adapter) table.insert(defaults, adapter) end,
}
sys = {
    subscribe = function(event, handler) subscriptions[event] = handler end,
    taskInit = function(handler) table.insert(tasks, handler) end,
    wait = function() end,
    publish = function(...) table.insert(events, { ... }) end,
}
wlan = {
    init = function() end,
    connect = function(ssid, password, auth_mode)
        wifi_connect = { ssid, password, auth_mode }
        return true
    end,
}
mobile = { flymode = function(_, enabled) flymode_calls = flymode_calls + 1; return enabled end }
log = { info = function() end, warn = function() end, error = function() end }

local exnetif = require "exnetif"
support.assertFalse(exnetif.notify_status("not-a-function"), "invalid status callback")
support.assertTrue(exnetif.notify_status(function(net_type, adapter)
    callback = { net_type, adapter }
end), "status callback registration")
support.assertFalse(exnetif.set_priority_order(nil), "missing network priority rejected")
support.assertFalse(exnetif.set_priority_order({ { UNKNOWN = true } }), "unknown network rejected")

support.assertTrue(exnetif.set_priority_order({
    { WIFI = { ssid = "test-ap", password = "secret" } },
    { LWIP_GP = true },
}), "network priority configured")
support.assertEqual(wifi_connect[1], "test-ap", "Wi-Fi SSID passed through")
support.assertEqual(wifi_connect[2], "secret", "Wi-Fi password passed through")
support.assertEqual(flymode_calls, 1, "cellular data enabled")
support.assertEqual(defaults[1], 2, "first priority selected as default")
support.assertEqual(type(subscriptions.IP_READY), "function", "IP_READY subscription")
support.assertEqual(type(subscriptions.IP_LOSE), "function", "IP_LOSE subscription")

ips[2] = "192.0.2.10"
subscriptions.IP_READY("192.0.2.10", 2)
support.assertTrue(#tasks >= 1, "Wi-Fi probe task scheduled")
tasks[#tasks]()
support.assertEqual(callback[1], "WiFi", "Wi-Fi status type")
support.assertEqual(callback[2], 2, "Wi-Fi adapter selected")
support.assertEqual(probe_adapters[1], 2, "Wi-Fi probe adapter")
support.assertEqual(defaults[#defaults], 2, "Wi-Fi becomes default")
support.assertEqual(events[#events][1], "EXLIB_NETDRV_NETWORK_STATUS", "network event published")

ips[1] = "198.51.100.10"
subscriptions.IP_READY("198.51.100.10", 1)
tasks[#tasks]()
support.assertEqual(probe_adapters[#probe_adapters], 1, "cellular probe adapter")
support.assertEqual(callback[1], "WiFi", "lower-priority cellular does not replace Wi-Fi")

subscriptions.IP_LOSE(2)
support.assertEqual(callback[1], "4G", "cellular fallback selected")
support.assertEqual(callback[2], 1, "cellular fallback adapter")

ips[1] = "0.0.0.0"
exnetif.check_network_status()
support.assertEqual(callback[1], nil, "no usable adapter callback type")
support.assertEqual(callback[2], -1, "no usable adapter callback code")
support.assertEqual(exnetif.version(), "air8000w-forwarder-20260730", "exnetif version")

local bad_exnetif = dofile(test_dir .. "../script/exnetif.lua")
support.assertFalse(bad_exnetif.set_priority_order({ { WIFI = {} } }), "empty Wi-Fi SSID rejected")

print("exnetif tests passed")
