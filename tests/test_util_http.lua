local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local test_dir = source:match("^(.*[/])") or "tests/"
package.path = test_dir .. "../script/?.lua;" .. test_dir .. "?.lua;" .. (package.path or "")
local support = dofile(test_dir .. "test_support.lua")
package.loaded.util_http = nil

local tick = 1000
local events, requests = {}, {}
local selected_adapter = 2
local failures = 0
config = { DIAGNOSTIC_LOGS = true, HTTP_TIMEOUT = 20000 }
mcu = { ticks = function() return tick end }
USER_DIAG = function(component, event, ...) table.insert(events, { component, event, ... }) end
package.loaded.util_network = {
    currentAdapter = function() return selected_adapter end,
    reportFailure = function() failures = failures + 1 end,
}
log = { info = function() end, warn = function() end, error = function() end }
http = {
    request = function(method, url, headers, body, opts)
        table.insert(requests, { method, url, headers, body, opts })
        return { wait = function()
            tick = tick + 125
            return 200, { Server = "test" }, "secret-response"
        end }
    end,
}
collectgarbage = function() end

local util_http = require "util_http"
local code, response_headers, response_body = util_http.fetch(nil, "POST", "https://example.test", {}, "secret-request")
support.assertEqual(code, 200, "HTTP result")
support.assertEqual(response_headers.Server, "test", "HTTP response headers")
support.assertEqual(response_body, "secret-response", "HTTP response body")
support.assertEqual(requests[1][5].adapter, 2, "Wi-Fi adapter selected")
support.assertEqual(requests[1][5].timeout, 20000, "configured timeout")
support.assertEqual(events[1][2], "start", "start diagnostic")
support.assertEqual(events[2][2], "finish", "finish diagnostic")

local rendered = ""
for _, event in ipairs(events) do for _, value in ipairs(event) do rendered = rendered .. " " .. tostring(value) end end
support.assertNotContains(rendered, "secret-request", "request body is not logged")
support.assertNotContains(rendered, "secret-response", "response body is not logged")

config.DIAGNOSTIC_LOGS = false
util_http.fetch(1000, "GET", "https://example.test", nil, nil)
support.assertEqual(#events, 2, "diagnostics disabled")
selected_adapter = nil
support.assertEqual(util_http.fetch(nil, "GET", "https://example.test"), -1, "offline HTTP skipped")
support.assertEqual(#requests, 2, "offline request not issued")

selected_adapter = 1
http.request = function() return { wait = function() return -1, nil, "network failure" end } end
support.assertEqual(util_http.fetch(nil, "GET", "https://example.test"), -1, "HTTP failure code")
support.assertEqual(failures, 1, "network failure reported")

print("util_http tests passed")
