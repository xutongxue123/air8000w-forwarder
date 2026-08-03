local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local test_dir = source:match("^(.*[/])") or "tests/"
package.path = test_dir .. "../script/?.lua;" .. test_dir .. "?.lua;" .. (package.path or "")
local support = dofile(test_dir .. "test_support.lua")
local history_support = dofile(test_dir .. "test_history_support.lua")
support.clearModules({ "util_web", "util_history", "util_notify", "util_notify_channel", "util_network", "util_mobile" })

local env = history_support.load()
local reboot_count, timer
local sent_number, sent_content
local handler
local channel_test_state = { state = "idle" }
local bark_state

config = {
    WEB = { enabled = true, username = "admin", password = "secret", port = 80 },
    NETWORK = { wifi_adapter = 2, wifi = { enabled = true } },
    FALLBACK_LOCAL_NUMBER = "+8613800138000",
    CHANNELS = {
        archive = { type = "custom_post", enabled = true, sms_mode = "all", system_enabled = true,
            sms_template = "SMS {content}" },
        bark = { type = "bark", enabled = false, sms_mode = "all", system_enabled = true,
            sms_template = "Bark {content}" },
        alpha = { type = "webhook", enabled = true, sms_mode = "all", system_enabled = true,
            sms_template = "Default {content}" },
    },
}
mcu = { ticks = function() return 3723000 end }
rtos = {
    reboot = function() reboot_count = reboot_count + 1 end,
    meminfo = function(kind) return kind == "lua" and 4096 or 8192, kind == "lua" and 1024 or 2048 end,
}
sys = {
    timerStart = function(fn, delay) timer = { fn = fn, delay = delay } end,
    taskInit = function() end,
}
httpsrv = {
    start = function(port, callback, adapter)
        support.assertEqual(port, 80, "HTTP port")
        support.assertEqual(adapter, 2, "HTTP adapter")
        handler = callback
        return true
    end,
}
mobile = { simid = function() return 0 end, simPin = function() return true end,
    rsrp = function() return -70 end, rsrq = function() return -10 end, snr = function() return 20 end }
package.loaded.util_network = {
    getStatus = function() return { ready = true, network_type = "WiFi", adapter = 2, wifi_local_ip = "192.0.2.2", wifi_rssi = -50 } end,
}
package.loaded.util_mobile = {
    operator = function() return "operator" end,
    localNumber = function() return "+8613800138000" end,
    deviceInfo = function() return "device-info" end,
}
package.loaded.util_notify = {
    getStatus = function() return { queue_length = 0, retrying_count = 0, bark_enabled = bark_state == true } end,
    addChannelTest = function(channel)
        if channel ~= "archive" then return false, "channel_not_configured" end
        channel_test_state = { state = "queued", message_id = "test-1", detail = "" }
        return true, "test-1"
    end,
    getChannelTest = function() return channel_test_state end,
    setBarkEnabled = function(value) bark_state = value == true return bark_state end,
}
package.loaded.util_notify_channel = {
    ready = function() return true end,
    send = function() return { success = true } end,
    validate = function() return true end,
}
sms = {
    send = function(number, content) sent_number, sent_content = number, content return true end,
}
log = { info = function() end, warn = function() end, error = function() end }

local util_web = require "util_web"
local status_snapshot = {
    provider = true,
    data_type = "WiFi",
    data_adapter = 2,
    cellular_data_enabled = true,
    cellular_local_ip = "198.51.100.1",
    wifi_local_ip = "192.0.2.2",
    wifi_rssi = -50,
    local_number = "+8613800138000",
}
util_web.setStatusProvider(function() return status_snapshot end)
local provider_status = WEB_STATUS_PROVIDER()
support.assertTrue(provider_status.provider, "status provider exported")
support.assertTrue(util_web.init(), "Web server initialized")
support.assertFalse(util_web.init(), "Web server initializes once")
support.assertEqual(type(handler), "function", "HTTP handler captured")

local auth = { Authorization = "Basic YWRtaW46c2VjcmV0" }
local function request(method, uri, body, headers)
    local code, response_headers, response_body = handler(nil, method, uri, headers or auth, body or "")
    return code, response_headers, response_body
end
local function jsonRequest(method, uri, body)
    local code, headers, response_body = request(method, uri, body)
    support.assertEqual(headers["Content-Type"], "application/json; charset=utf-8", "JSON response type")
    return code, json.decode(response_body)
end

local code = request("GET", "/api/ping", "", { Authorization = "Basic d3Jvbmc6cGFzcw==" })
support.assertEqual(code, 401, "unauthorized request")
code = request("GET", "/")
support.assertEqual(code, 200, "dashboard response")
local asset_code, asset_headers, assets = request("GET", "/assets/dashboard")
support.assertEqual(asset_code, 200, "dashboard asset response")
support.assertEqual(asset_headers["Content-Type"], "text/plain; charset=utf-8", "asset content type")
support.assertTrue(#assets > 0, "dashboard asset is non-empty")
support.assertContains(assets, "当前页仅显示最新的100条通话记录。", "call history page description")
support.assertNotContains(assets, "设备本地保留最近 100 条通话事件。", "old call history description removed")
local chunk_code = request("GET", "/assets/dashboard/1")
support.assertEqual(chunk_code, 200, "dashboard chunk response")
support.assertEqual(request("GET", "/assets/dashboard/99999"), 404, "missing dashboard chunk")

local ping_code, ping = jsonRequest("GET", "/api/ping")
support.assertEqual(ping_code, 200, "ping status")
support.assertEqual(ping.service, "air8000w-web-admin", "ping service")
local status_code, status = jsonRequest("GET", "/api/status")
support.assertEqual(status_code, 200, "status endpoint")
support.assertEqual(status.data_type, "WiFi", "status network type")
support.assertEqual(status.local_number, "+8613800138000", "status local number")
support.assertEqual(status.cellular_local_ip, "198.51.100.1", "status cellular IP")

env.history.addSms("10086", "incoming", "2026-08-03 10:00:00", "incoming")
env.history.addCall("10010", "INCOMINGCALL", "2026-08-03 10:00:01")
local _, history = jsonRequest("GET", "/api/history")
support.assertEqual(#history.sms, 1, "history SMS endpoint")
local _, calls = jsonRequest("GET", "/api/calls?limit=1")
support.assertEqual(#calls.calls, 1, "history calls endpoint")
local _, sms_history = jsonRequest("GET", "/api/sms/history?limit=1")
support.assertEqual(#sms_history.sms, 1, "history SMS pagination endpoint")

local sent_code, sent = jsonRequest("POST", "/api/sms/send", '{"number":"10086","content":"reply"}')
support.assertEqual(sent_code, 200, "SMS send status")
support.assertTrue(sent.ok, "SMS send success")
support.assertTrue(sent.history_saved, "outgoing SMS saved")
support.assertEqual(sent_number, "10086", "SMS recipient")
support.assertEqual(sent_content, "reply", "SMS content")
local _, missing = jsonRequest("POST", "/api/sms/send", '{"number":"","content":""}')
support.assertEqual(missing.detail, "number_and_content_required", "missing SMS fields")

local channel_test_config = json.encode({ CHANNELS = {
    archive = { type = "custom_post", enabled = true, sms_mode = "all", system_enabled = true,
        url = "https://archive.test", body = { content = "SMS {content}" },
        sms_template = "SMS {content}" },
} })
local test_code, test_result = jsonRequest("POST", "/api/channels/test",
    json.encode({ channel = "archive", config = json.decode(channel_test_config) }))
support.assertTrue(test_result.ok, "channel test request")
support.assertEqual(test_code, 200, "channel test status")
local _, test_state = jsonRequest("GET", "/api/channels/test/archive")
support.assertEqual(test_state.state, "queued", "channel test state endpoint")
local _, missing_state = jsonRequest("GET", "/api/channels/test/missing")
support.assertEqual(missing_state.state, "queued", "channel state passthrough")

local _, templates = jsonRequest("GET", "/api/config/default-templates")
support.assertTrue(type(templates.custom_post) == "table", "default templates endpoint")
local config_code, _, config_body = request("GET", "/api/config")
support.assertEqual(config_code, 200, "config endpoint")
support.assertNotContains(config_body, "secret", "Web password not returned")

local put_code = request("PUT", "/api/config",
    '{"CHANNELS":{"bark":{"enabled":true,"sms_mode":"all"}},"NETWORK":{"wifi":{"enabled":true}}}')
support.assertEqual(put_code, 200, "config save status")
support.assertTrue(env.store["web-config-overrides-v1"] ~= nil, "config persisted")
support.assertEqual(config.CHANNELS.bark.enabled, true, "saved config merged")
support.assertEqual(bark_state, true, "Bark state synchronized")

local reboot_code = request("POST", "/api/reboot")
support.assertEqual(reboot_code, 200, "reboot endpoint")
support.assertEqual(timer.delay, 300, "reboot delay")
support.assertEqual(request("GET", "/not-found"), 404, "unknown endpoint")

env.store["web-config-overrides-v1"] = { CHANNELS = {
    alpha = { sms_mode = "off", enabled = true, title_template = "legacy-title" },
} }
util_web.applySavedConfig()
support.assertEqual(config.CHANNELS.alpha.sms_mode, "all", "legacy SMS mode migrated")
support.assertEqual(config.CHANNELS.alpha.enabled, false, "legacy disabled mode migrated")
support.assertEqual(config.CHANNELS.alpha.title_template, nil, "legacy title removed")

local wifi_saved = util_web.applyWifiSmsCommand("set", "new-ap", "new-password")
support.assertTrue(wifi_saved, "Wi-Fi SMS configuration saved")
support.assertTrue(env.store["web-config-overrides-v1"].NETWORK.wifi.enabled, "Wi-Fi enabled by SMS config")
support.assertEqual(timer.delay, 300, "Wi-Fi config reboot scheduled")
support.assertFalse(util_web.applyWifiSmsCommand("invalid"), "invalid Wi-Fi action rejected")

print("util_web tests passed")
