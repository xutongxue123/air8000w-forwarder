local source = debug.getinfo(1, "S").source:sub(2)
local test_dir = source:gsub("\\", "/"):match("^(.*[/])") or "tests/"
package.path = test_dir .. "../script/?.lua;" .. test_dir .. "?.lua;" .. (package.path or "")
package.loaded.config = nil

local config = require "config"
local function assertTrue(value, message) if not value then error(message or "expected true") end end
local function assertEqual(actual, expected, message)
    if actual ~= expected then error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual))) end
end

assertEqual(config.VERSION, nil, "config does not own runtime version")
assertEqual(config.BOOT_NOTIFY, true, "boot notifications enabled by default")
assertEqual(config.NETWORK.cellular_data_enabled, false, "cellular data disabled by default")
assertEqual(config.NETWORK.wifi.enabled, true, "Wi-Fi enabled by default")
assertEqual(config.NETWORK.wifi_adapter, 2, "Wi-Fi adapter")
assertEqual(config.NETWORK.cellular_adapter, 1, "cellular adapter")
assertEqual(config.CHANNELS.bark.type, "bark", "Bark channel type")
assertEqual(config.CHANNELS.dingtalk.type, "dingtalk", "DingTalk channel type")
assertEqual(config.CHANNELS.feishu.type, "feishu", "Feishu channel type")
assertEqual(config.CHANNELS.webhook.type, "webhook", "Webhook channel type")
assertEqual(config.CHANNELS.bark.enabled, false, "Bark disabled in first-boot config")
assertEqual(config.CHANNELS.dingtalk.enabled, false, "DingTalk disabled in first-boot config")
assertTrue(type(config.KEYWORD_FILTER.content_patterns) == "table", "global keyword filter exists")
assertTrue(#config.KEYWORD_FILTER.content_patterns > 0, "global keyword filter is not empty")
assertEqual(config.SMS_WIFI_COMMAND.keyword, "XTX", "SMS Wi-Fi command keyword")
assertEqual(config.CALL.events.INCOMINGCALL, true, "incoming call enabled")
assertEqual(config.CALL.events.CONNECTED, false, "connected call disabled by default")

print("config tests passed")
