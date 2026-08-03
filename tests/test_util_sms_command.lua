local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local test_dir = source:match("^(.*[/])") or "tests/"
package.path = test_dir .. "../script/?.lua;" .. test_dir .. "?.lua;" .. (package.path or "")
local support = dofile(test_dir .. "test_support.lua")
package.loaded.util_sms_command = nil

local calls = {}
config = { SMS_WIFI_COMMAND = { enabled = true, keyword = "XJ" } }
log = { info = function() end }
package.loaded.util_web = {
    applyWifiSmsCommand = function(...)
        table.insert(calls, { ... })
        return calls[#calls][1] ~= "off-fails"
    end,
}
local util_sms_command = require "util_sms_command"

support.assertFalse(util_sms_command.handle("hello"), "ordinary SMS ignored")
local legacy_consumed, legacy_ok = util_sms_command.handle("XJ,W,ON,extra")
support.assertTrue(legacy_consumed and legacy_ok, "legacy four-field SET command")
local consumed, ok = util_sms_command.handle("xj,w,on")
support.assertTrue(consumed, "ON command consumed")
support.assertTrue(ok, "ON command applied")
support.assertEqual(calls[#calls][1], "on", "ON action")

consumed, ok = util_sms_command.handle("XJ,W,ssid,password")
support.assertTrue(consumed, "legacy SET command consumed")
support.assertTrue(ok, "SET command applied")
support.assertEqual(calls[#calls][1], "set", "SET action")
support.assertEqual(calls[#calls][2], "ssid", "SSID passed")
support.assertEqual(calls[#calls][3], "password", "password passed")

consumed, ok = util_sms_command.handle("XJ,W,OFF")
support.assertTrue(consumed, "OFF command consumed")
support.assertTrue(ok, "OFF command applied")
support.assertEqual(calls[#calls][1], "off", "OFF action")

config.SMS_WIFI_COMMAND.enabled = false
support.assertFalse(util_sms_command.handle("XJ,W,ON"), "disabled command ignored")
config.SMS_WIFI_COMMAND.enabled = true
support.assertFalse(util_sms_command.handle("XJ,X,ON"), "wrong mode ignored")
local malformed_consumed, malformed_ok = util_sms_command.handle("XJ,W,SET,,password")
support.assertTrue(malformed_consumed, "recognized malformed command is consumed")
support.assertFalse(malformed_ok == true, "empty SSID is not applied")

print("util_sms_command tests passed")
