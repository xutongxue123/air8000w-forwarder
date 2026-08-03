local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local test_dir = source:match("^(.*[/])") or "tests/"
package.path = test_dir .. "../script/?.lua;" .. test_dir .. "?.lua;" .. (package.path or "")
local support = dofile(test_dir .. "test_history_support.lua")

local function assertTrue(value, message)
    if not value then error(message or "expected true") end
end

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message or "values differ", tostring(expected), tostring(actual)))
    end
end

local env, history = support.load()
local sent_number, sent_content
_G.config = {
    CHANNELS = {},
    NETWORK = { wifi_adapter = 2 },
    WEB = { enabled = true, username = "admin", password = "secret", port = 80 },
}
_G.sms = {
    send = function(number, content)
        sent_number, sent_content = number, content
        return true
    end,
}
_G.httpsrv = {
    start = function(_, handler)
        _G.history_handler = handler
        return true
    end,
}
_G.sys = { timerStart = function() end }
_G.rtos = { reboot = function() end }

package.loaded.util_web = nil
local util_web = require "util_web"
assertTrue(util_web.init(), "Web server initialization")
assertTrue(type(history_handler) == "function", "HTTP handler captured")

local headers = { Authorization = "Basic YWRtaW46c2VjcmV0" }
local function request(method, uri, body)
    local code, response_headers, response_body = history_handler(nil, method, uri, headers, body or "")
    assertEqual(response_headers["Content-Type"], "application/json; charset=utf-8", "JSON response content type")
    assertEqual(code, 200, "HTTP response status")
    return json.decode(response_body)
end

history.addSms("10086", "短信一", "2026-08-03 10:00:00", "incoming")
history.addCall("10010", "INCOMINGCALL", "2026-08-03 10:00:01")
history.addSms("10086", "短信二", "2026-08-03 10:00:02", "incoming")
history.addCall("10010", "CONNECTED", "2026-08-03 10:00:03")

local paged_sms = request("GET", "/api/sms/history?limit=100&before=3")
assertEqual(#paged_sms.sms, 1, "SMS before pagination response")
assertEqual(paged_sms.sms[1].sequence, 1, "SMS before cursor")

local paged_calls = request("GET", "/api/calls?limit=1&before=4")
assertEqual(#paged_calls.calls, 1, "call limit pagination response")
assertEqual(paged_calls.calls[1].sequence, 2, "call before cursor")

local history_response = request("GET", "/api/history")
assertTrue(type(history_response.sms) == "table", "history SMS field")
assertTrue(type(history_response.calls) == "table", "history calls field")
assertTrue(type(history_response.limits) == "table", "history limits field")
assertEqual(history_response.limits.records, 500, "history record limit field")
assertEqual(history_response.limits.bytes, 256 * 1024, "history byte limit field")

local sent_response = request("POST", "/api/sms/send", json.encode({ number = "10086", content = "回复内容" }))
assertEqual(sent_response.ok, true, "SMS send response")
assertEqual(sent_response.history_saved, true, "outgoing history response")
assertEqual(sent_number, "10086", "SMS send number")
assertEqual(sent_content, "回复内容", "SMS send content")
assertEqual(history.getSms(1)[1].direction, "outgoing", "outgoing SMS persisted")

local bounded_response = request("GET", "/api/sms/history?limit=999")
assertTrue(#bounded_response.sms <= 100, "API limit capped at 100")
assertTrue(env.files["/history/events-v2.ndjson"] ~= nil, "Web API writes LittleFS history")

print("util_web history tests passed")
