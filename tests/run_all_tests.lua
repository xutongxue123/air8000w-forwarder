local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local test_dir = source:match("^(.*[/])") or "tests/"
package.path = test_dir .. "../script/?.lua;" .. test_dir .. "?.lua;" .. (package.path or "")
local native_os = os

local test_files = {
    "test_config.lua",
    "test_exnetif.lua",
    "test_httpdns.lua",
    "test_main.lua",
    "test_util_call.lua",
    "test_util_history.lua",
    "test_history_recovery.lua",
    "test_util_http.lua",
    "test_util_mobile.lua",
    "test_util_network.lua",
    "test_util_notify.lua",
    "test_util_notify_restore.lua",
    "test_util_notify_channel.lua",
    "test_util_router.lua",
    "test_util_sms_command.lua",
    "test_util_web.lua",
    "test_util_web_history.lua",
}

for _, name in ipairs(test_files) do
    dofile(test_dir .. name)
    if name == "test_history_recovery.lua" then _G.os = native_os end
end

print("all Air8000W tests passed")
