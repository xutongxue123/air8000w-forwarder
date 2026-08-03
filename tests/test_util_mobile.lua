local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local test_dir = source:match("^(.*[/])") or "tests/"
package.path = test_dir .. "../script/?.lua;" .. test_dir .. "?.lua;" .. (package.path or "")
local support = dofile(test_dir .. "test_support.lua")
package.loaded.util_mobile = nil

local tick = 3723000
local number = "+8613800138000"
local rsrp = -79
local logs = {}
config = { FALLBACK_LOCAL_NUMBER = "" }
mcu = { ticks = function() return tick end }
log = {
    info = function(...) table.insert(logs, { ... }) end,
    warn = function(...) table.insert(logs, { ... }) end,
}
mobile = {
    simid = function() return 0 end,
    number = function() return number end,
    imsi = function() return "460011234567890" end,
    rsrp = function() return rsrp end,
    status = function() return 1 end,
    simPin = function(_, operation) return operation == nil or operation == 1 end,
    PIN_VERIFY = 1,
}

local util_mobile = require "util_mobile"
support.assertTrue(type(util_mobile.status()) == "string", "registered status text")
support.assertTrue(util_mobile.operator() ~= "unknown", "operator lookup")
support.assertEqual(util_mobile.localNumber(), number, "SIM number")
number = ""
config.FALLBACK_LOCAL_NUMBER = "+8613900139000"
support.assertEqual(util_mobile.localNumber(), config.FALLBACK_LOCAL_NUMBER, "fallback number")
config.FALLBACK_LOCAL_NUMBER = ""
local unknown_number = util_mobile.localNumber()
support.assertTrue(type(unknown_number) == "string" and unknown_number ~= "", "unknown number")

number = "+8613800138000"
local info = util_mobile.deviceInfo()
support.assertContains(info, number, "device number")
support.assertContains(info, "01:02:03", "uptime")
support.assertContains(info, "-79dBm", "signal")
rsrp = 0
support.assertNotContains(util_mobile.deviceInfo(), "-79dBm", "missing signal fallback")

support.assertTrue(util_mobile.pinVerify("1234"), "PIN verification")
support.assertFalse(util_mobile.pinVerify("123"), "short PIN rejected")
local rendered_logs = ""
for _, entry in ipairs(logs) do for _, value in ipairs(entry) do rendered_logs = rendered_logs .. " " .. tostring(value) end end
support.assertNotContains(rendered_logs, number, "phone number not logged")
mobile.imsi = function() return "123" end
support.assertEqual(util_mobile.operator(), "unknown", "short IMSI")

print("util_mobile tests passed")
