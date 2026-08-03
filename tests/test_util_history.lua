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
assertTrue(history.addSms("13800138000", "短信一", "2026-08-03 10:00:00", "incoming"), "SMS append")
assertTrue(history.addCall("13800138001", "INCOMINGCALL", "2026-08-03 10:00:01"), "call append")
assertTrue(history.addSms("13800138000", "短信二", "2026-08-03 10:00:02", "outgoing"), "outgoing SMS append")

local sms = history.getSms()
assertEqual(#sms, 2, "SMS count")
assertEqual(sms[1].sequence, 3, "SMS sequence descending")
assertEqual(sms[1].direction, "outgoing", "SMS direction")
assertEqual(history.getCalls()[1].sequence, 2, "call sequence")
assertEqual(history.getSms(1, 3)[1].sequence, 1, "SMS before pagination")

local chinese_and_emoji = string.rep("中", 170) .. "😀"
assertTrue(history.addSms(string.rep("1", 40), chinese_and_emoji, "2026-08-03 10:00:03", "incoming"),
    "UTF-8 SMS append")
local bounded = history.getSms(1)[1]
assertEqual(#bounded.sender, 32, "number byte limit")
assertEqual(bounded.content, string.rep("中", 170), "UTF-8 truncation boundary")
assertEqual(#bounded.content, 510, "UTF-8 content byte limit")

local persisted = env.files["/history/events-v2.ndjson"]
assertTrue(type(persisted) == "string" and #persisted > 0, "NDJSON file exists")
for line in persisted:gmatch("[^\n]+") do
    assertTrue(type(json.decode(line)) == "table", "every persisted line is JSON")
end
assertEqual(env.opened(), env.closed(), "all history file handles closed")

local all = history.getAll()
assertTrue(type(all.sms) == "table" and type(all.calls) == "table" and type(all.limits) == "table",
    "getAll compatibility fields")
assertEqual(all.limits.records, 500, "shared record limit")
assertEqual(all.limits.bytes, 256 * 1024, "shared byte limit")
assertEqual(all.limits.sms_content_bytes, 512, "SMS content limit")

local count_env, count_history = support.load()
for index = 1, 501 do
    if index % 2 == 0 then
        count_history.addSms("10086", "sms-" .. index, "2026-08-03 10:00:00", "incoming")
    else
        count_history.addCall("10010", "INCOMINGCALL", "2026-08-03 10:00:00")
    end
end
local count_stats = count_history.getStats()
assertEqual(count_stats.records, 500, "mixed records share 500-record limit")
assertTrue(count_stats.sms_count + count_stats.call_count == 500, "mixed record counts")
assertEqual(#count_history.getSms(100, 2), 0, "oldest mixed record evicted")
assertEqual(count_history.getCalls(1)[1].sequence, 501, "latest mixed record retained")
assertTrue(#count_env.files["/history/events-v2.ndjson"] <= 256 * 1024, "mixed history byte budget")

local budget_env, budget_history = support.load()
local large_body = string.rep("中", 170) .. "😀"
for index = 1, 450 do
    budget_history.addSms("10086", large_body, "2026-08-03 10:00:00", "incoming")
end
local budget_stats = budget_history.getStats()
assertTrue(budget_stats.bytes <= 256 * 1024, "content-sized history byte budget")
assertTrue(budget_stats.records <= 450, "content-sized history record count")
assertEqual(budget_history.getSms(1)[1].sequence, 450, "latest content-sized record retained")
assertTrue(#budget_env.files["/history/events-v2.ndjson"] <= 256 * 1024, "persisted content-sized budget")

print("util_history tests passed")
