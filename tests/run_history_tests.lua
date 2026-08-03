local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local test_dir = source:match("^(.*[/])") or "tests/"

dofile(test_dir .. "test_util_history.lua")
dofile(test_dir .. "test_history_recovery.lua")
dofile(test_dir .. "test_util_web_history.lua")

print("all Air8000W history tests passed")
