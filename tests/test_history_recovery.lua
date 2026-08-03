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

local legacy_sms = {
    kind = "sms", sequence = 12, sender = "13800138000", content = "legacy sms",
    received_at = "2026-08-03 10:00:00", direction = "incoming",
}
local legacy_env, legacy_history = support.load({
    legacy = { ["history-v1-sms-1"] = legacy_sms },
})
assertEqual(legacy_history.getStats().records, 0, "legacy FSKV records are not loaded")
assertTrue(legacy_env.files["/history/events-v2.ndjson"] == nil, "legacy slots do not create history file")
assertTrue(legacy_env.store["history-v1-sms-1"] ~= nil, "legacy slot remains untouched")

local formal_record = {
    kind = "sms", sequence = 20, sender = "10086", content = "formal",
    received_at = "2026-08-03 10:00:20", direction = "incoming",
}
local ignored_legacy = {
    kind = "sms", sequence = 99, sender = "10010", content = "must not import",
    received_at = "2026-08-03 10:00:99", direction = "incoming",
}
local existing_env, existing_history = support.load({
    files = { ["/history/events-v2.ndjson"] = support.line(formal_record) },
    legacy = { ["history-v1-sms-1"] = ignored_legacy },
})
assertEqual(existing_history.getSms()[1].sequence, 20, "existing formal history remains authoritative")
assertTrue(existing_env.store["history-v1-sms-1"] ~= nil, "formal history prevents duplicate import")

local corrupt_record = {
    kind = "sms", sequence = 31, sender = "10086", content = "valid",
    received_at = "2026-08-03 10:00:31", direction = "incoming",
}
local corrupt_env, corrupt_history = support.load({
    files = { ["/history/events-v2.ndjson"] = support.line(corrupt_record) .. "{\"kind\":\"sms\",\"sequence\":\n" },
})
assertEqual(corrupt_history.getSms()[1].sequence, 31, "valid line survives corrupt line")
assertEqual(corrupt_history.getStats().corrupt_records, 1, "corrupt line counted")
assertTrue(corrupt_env.files["/history/events-v2.ndjson"] ~= nil, "corrupt history file remains readable")

local recovery_old = {
    kind = "sms", sequence = 40, sender = "10086", content = "old",
    received_at = "2026-08-03 10:00:40", direction = "incoming",
}
local recovery_new = {
    kind = "sms", sequence = 41, sender = "10086", content = "new",
    received_at = "2026-08-03 10:00:41", direction = "incoming",
}
local recovery_env, recovery_history = support.load({
    files = {
        ["/history/events-v2.ndjson"] = support.line(recovery_old),
        ["/history/events-v2.new"] = support.line(recovery_old) .. support.line(recovery_new),
        ["/history/events-v2.bak"] = support.line(recovery_old),
    },
})
assertEqual(recovery_history.getSms()[1].sequence, 41, "latest valid .new file selected")
assertTrue(recovery_env.files["/history/events-v2.new"] == nil, "recovered .new file promoted")
assertTrue(recovery_env.files["/history/events-v2.bak"] == nil, "recovered backup cleaned")

local backup_record = {
    kind = "call", sequence = 52, number = "13800138002", call_state = "CONNECTED",
    received_at = "2026-08-03 10:00:52",
}
local backup_env, backup_history = support.load({
    files = {
        ["/history/events-v2.ndjson"] = support.line(recovery_old),
        ["/history/events-v2.new"] = "{broken half-line\n",
        ["/history/events-v2.bak"] = support.line(backup_record),
    },
})
assertEqual(backup_history.getCalls()[1].sequence, 52, "valid backup selected over invalid temporary file")
assertTrue(backup_env.files["/history/events-v2.ndjson"] ~= nil, "backup promoted to formal file")
assertTrue(backup_env.files["/history/events-v2.bak"] == nil, "backup cleanup after recovery")

print("history recovery tests passed")
