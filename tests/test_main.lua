local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local test_dir = source:match("^(.*[/])") or "tests/"
package.path = test_dir .. "../script/?.lua;" .. test_dir .. "?.lua;" .. (package.path or "")
local support = dofile(test_dir .. "test_support.lua")
support.clearModules({ "main", "config", "util_web", "util_mobile", "util_network", "util_notify", "util_call", "util_history", "util_sms_command" })

local subscriptions, timers, tasks, logs = {}, {}, {}, {}
local sms_callback
local history_sms, notifications = {}, {}
local command_consumed = false
local provider
local module_load_level

local app_config = {
    BOOT_NOTIFY = true, PIN_CODE = "", NETWORK_READY_TIMEOUT = 5000,
    IPV6_ENABLED = false,
    NETWORK = { cellular_data_enabled = true, wifi_adapter = 2, cellular_adapter = 1 },
    LOGGING = { level = "INFO", operational = true, diagnostic = {
        enabled = true, startup = true, network = true, http = true, notify = true, call = true,
    }, health = { enabled = true, first_delay = 1, interval = 2 } },
    CHANNELS = { archive = { enabled = true, type = "custom_post", sms_mode = "all" } },
}
package.loaded.config = app_config
package.loaded.sys = {
    publish = function() end,
    subscribe = function(event, handler) subscriptions[event] = handler end,
    timerStart = function(fn, delay) table.insert(timers, { fn = fn, delay = delay }) end,
    timerLoopStart = function(fn, interval) table.insert(timers, { loop = true, fn = fn, interval = interval }) end,
    taskInit = function(fn) table.insert(tasks, fn) end,
    waitUntil = function() return true end,
    wait = function() end,
    run = function() end,
}
fskv = {
    init = function() return true end,
    status = function() return true, 1024, 4096, 3 end,
}
log = {
    setLevel = function(level) logs.level = level end,
    info = function(...) table.insert(logs, { "info", ... }) end,
    warn = function(...) table.insert(logs, { "warn", ... }) end,
    error = function(...) table.insert(logs, { "error", ... }) end,
}
pm = { lastReson = function() return "POWER_ON" end }
wdt = { init = function(value) logs.wdt_init = value end, feed = function() end }
mobile = {
    setAuto = function(...) logs.mobile_auto = { ... } end,
    ipv6 = function(value) logs.mobile_ipv6 = value end,
    simid = function() return 0 end,
    simPin = function() return true end,
    status = function() return 1 end,
    rsrp = function() return -70 end,
    rsrq = function() return -10 end,
    snr = function() return 20 end,
}
rtos = { meminfo = function(kind) return kind == "lua" and 8192 or 16384, kind == "lua" and 2048 or 4096 end }
io.fsstat = function() return true, 10, 2, 4096, "littlefs" end
mcu = { ticks = function() return 3723000 end }
sms = { setNewSmsCb = function(callback) sms_callback = callback end }

package.loaded.util_web = {
    applySavedConfig = function() module_load_level = logs.level end,
    setStatusProvider = function(value) provider = value end,
    init = function() return true end,
}
package.loaded.util_mobile = {
    status = function() return "registered" end,
    operator = function() return "operator" end,
    localNumber = function() return "+8613800138000" end,
}
package.loaded.util_network = {
    init = function() return true end,
    isReady = function() return true end,
    syncTime = function() return true end,
    getStatus = function() return {
        ready = true, network_type = "WiFi", adapter = 2, wifi_enabled = true,
        wifi_connected = true, wifi_adapter = 2, wifi_local_ip = "192.0.2.5",
        wifi_rssi = -50, wifi_rssi_source = "getInfo",
        cellular_data_enabled = true, cellular_local_ip = "198.51.100.7",
    } end,
}
package.loaded.util_notify = {
    init = function() end,
    getStatus = function() return {
        queue_length = 0, retrying_count = 0, persisted_count = 0,
        corrupt_records = 0, consecutive_errors = 0, persistence_errors = 0,
        route_errors = 0, oldest_task_ms = 0, last_success_tick = 0,
        last_full_success_tick = 0, bark_enabled = false, configuration_error = false,
    } end,
    addSystem = function(content, include_bark, include_info)
        table.insert(notifications, { content, include_bark, include_info })
        return true
    end,
    addSms = function(envelope) table.insert(notifications, { sms = envelope }) return true end,
}
package.loaded.util_call = { init = function() return true end }
package.loaded.util_history = {
    addSms = function(...) table.insert(history_sms, { ... }) return true end,
    getStats = function() return { storage = "littlefs", records = 0, sms_count = 0, call_count = 0,
        bytes = 0, budget = 256 * 1024, corrupt_records = 0, last_compact = "never" } end,
}
package.loaded.util_sms_command = {
    handle = function() return command_consumed end,
}

require "main"
support.assertEqual(logs.level, "INFO", "main log level")
support.assertEqual(module_load_level, "INFO", "log level initialized before module load")
support.assertEqual(logs.wdt_init, 9000, "watchdog initialized")
support.assertEqual(logs.mobile_ipv6, false, "IPv6 setting")
support.assertEqual(type(provider), "function", "status provider registered")
support.assertEqual(type(sms_callback), "function", "SMS callback registered")
support.assertTrue(type(subscriptions.NETWORK_STATUS_CHANGED) == "function", "network event subscribed")
support.assertTrue(type(subscriptions.SMS_READY) == "function", "SMS ready subscribed")
support.assertEqual(#notifications, 1, "startup network notification")
support.assertContains(notifications[1][1], "#NETWORK_READY_WiFi", "network notification type")

local snapshot = provider()
support.assertEqual(snapshot.data_type, "WiFi", "health snapshot data type")
support.assertEqual(snapshot.wifi_local_ip, "192.0.2.5", "health snapshot Wi-Fi IP")
support.assertEqual(snapshot.cellular_local_ip, "198.51.100.7", "health snapshot cellular IP")
support.assertEqual(snapshot.fs_type, "littlefs", "health snapshot filesystem")
support.assertEqual(snapshot.history_budget, 256 * 1024, "health snapshot history budget")

sms_callback("10086", "incoming", { year = 26, mon = 8, day = 3, hour = 10, min = 0, sec = 0 })
support.assertEqual(#history_sms, 1, "incoming SMS history")
support.assertEqual(history_sms[1][1], "10086", "incoming SMS sender")
support.assertEqual(#notifications, 2, "incoming SMS notification")
support.assertEqual(notifications[2].sms.content, "incoming", "incoming SMS content")

command_consumed = true
sms_callback("10010", "XJ,W,ON", nil)
support.assertEqual(#history_sms, 1, "consumed SMS not saved")
support.assertEqual(#notifications, 2, "consumed SMS not notified")
command_consumed = false

subscriptions.SMS_READY()
support.assertEqual(#notifications, 3, "SMS ready startup notification")
support.assertContains(notifications[3][1], "#SMS_READY_BOOT_POWER_ON", "SMS ready power reason")
subscriptions.NETWORK_STATUS_CHANGED(true)
support.assertEqual(#notifications, 3, "startup notifications are one-shot")

for _, timer in ipairs(timers) do if timer.loop ~= true then timer.fn() end end
local health_logged = false
local health_line
for _, entry in ipairs(logs) do
    if entry[1] == "info" and type(entry[2]) == "string" and entry[2]:sub(1, 7) == "health " then
        health_logged = true
        health_line = entry[2]
    end
end
support.assertTrue(health_logged, "health timer executed")
support.assertContains(health_line, "WIFI ON 192.0.2.5 -50", "Wi-Fi health summary")
support.assertContains(health_line, "4G ON 198.51.100.7 -70", "cellular health summary")
support.assertNotContains(health_line, " fsf ", "free filesystem field removed")
support.assertNotContains(health_line, "hbud", "history budget field removed")
support.assertNotContains(health_line, "bark", "channel-specific Bark field removed")

print("main tests passed")
