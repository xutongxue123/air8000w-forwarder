local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local test_dir = source:match("^(.*[/])") or "tests/"
package.path = test_dir .. "../script/?.lua;" .. test_dir .. "?.lua;" .. (package.path or "")
local support = dofile(test_dir .. "test_support.lua")
package.loaded.util_router = nil
local util_router = require "util_router"

local function assertChannels(actual, expected, message)
    support.assertEqual(#actual, #expected, message .. " length")
    for index, channel in ipairs(expected) do support.assertEqual(actual[index], channel, message .. " channel " .. index) end
end

local app_config = {
    CHANNELS = {
        all = { type = "webhook", enabled = true, sms_mode = "all", system_enabled = true, call_enabled = true },
        bark_codes = {
            type = "bark", enabled = true, sms_mode = "verification", system_enabled = true, call_enabled = true,
            match = { content_patterns = { "code" }, sender_patterns = {}, mode = "any" },
        },
        sender = {
            type = "custom_post", enabled = true, sms_mode = "verification", system_enabled = false,
            call_enabled = false, match = { content_patterns = {}, sender_patterns = { "^955" }, mode = "any" },
        },
        disabled = { type = "webhook", enabled = false, sms_mode = "all", system_enabled = true },
        invalid = { type = "webhook", enabled = true, sms_mode = "off", system_enabled = true },
    },
}

local channels, errors = util_router.route({ sender = "95588", content = "your code is 123456" }, app_config, true)
assertChannels(channels, { "all", "bark_codes", "sender" }, "deterministic route")
support.assertEqual(#errors, 1, "invalid policy reported")
channels = util_router.route({ sender = "10086", content = "ordinary" }, app_config, true)
assertChannels(channels, { "all" }, "ordinary route")
channels = util_router.route({ sender = "95588", content = "code 654321" }, app_config, false)
assertChannels(channels, { "all", "sender" }, "Bark runtime switch")
assertChannels(util_router.systemChannels(app_config, true, true), { "all", "bark_codes" }, "system channels")
assertChannels(util_router.callChannels(app_config, true), { "all", "bark_codes" }, "call channels")
assertChannels(util_router.sortedChannelNames(app_config), { "all", "bark_codes", "disabled", "invalid", "sender" }, "sorted names")

local valid, detail = util_router.validatePolicy("empty", { sms_mode = "verification", match = {} })
support.assertFalse(valid, "empty verification policy rejected")
support.assertTrue(type(detail) == "string", "verification error detail")
support.assertFalse(util_router.validatePolicy("bad", { sms_mode = "off" }), "invalid SMS mode rejected")
support.assertFalse(util_router.validatePolicy("bad", { sms_mode = "all", system_enabled = "yes" }), "invalid system flag rejected")
support.assertFalse(util_router.validatePolicy("bad", { sms_mode = "verification", match = { content_patterns = { "[" } } }),
    "invalid Lua pattern rejected")
support.assertFalse(util_router.matches(nil, {}, app_config), "invalid message rejected")

local global_config = {
    KEYWORD_FILTER = { mode = "all", content_patterns = { "code", "123" }, sender_patterns = {} },
    CHANNELS = { global = { type = "webhook", enabled = true, sms_mode = "verification", match = { content_patterns = { "ignored" } } } },
}
support.assertTrue(util_router.matches({ content = "code 123", sender = "x" }, global_config.CHANNELS.global, global_config),
    "global keyword filter takes precedence")
support.assertFalse(util_router.matches({ content = "code", sender = "x" }, global_config.CHANNELS.global, global_config),
    "all keyword filter requires all patterns")

print("util_router tests passed")
