local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local test_dir = source:match("^(.*[/])") or "tests/"
package.path = test_dir .. "../script/?.lua;" .. test_dir .. "?.lua;" .. (package.path or "")
local support = dofile(test_dir .. "test_support.lua")
support.clearModules({ "util_notify", "util_router", "util_notify_channel", "util_mobile", "util_network" })

local tick = 1000
local store, log_events, diag_events = {}, {}, {}
local worker
local network_ready = false
local send_success = true
local sent = {}

config = {
    DIAGNOSTIC_LOGS = true,
    CHANNELS = {
        archive = { type = "custom_post", enabled = true, sms_mode = "all", system_enabled = true, call_enabled = true },
        bark = { type = "bark", enabled = true, sms_mode = "verification", system_enabled = true, call_enabled = true,
            match = { content_patterns = { "code" }, sender_patterns = {}, mode = "any" } },
    },
}
mcu = { ticks = function() return tick end }
log = {
    info = function(...) table.insert(log_events, { ... }) end,
    warn = function(...) table.insert(log_events, { ... }) end,
    error = function(...) table.insert(log_events, { ... }) end,
}
USER_DIAG = function(component, event, ...) table.insert(diag_events, { component, event, ... }) end
json = {
    encode = function(value) return "encoded:" .. tostring(value.task_id or "task") end,
    decode = function() error("no restore records") end,
}
fskv = {
    get = function(key) return store[key] end,
    set = function(key, value) store[key] = value return true end,
    del = function(key) store[key] = nil return true end,
    iter = function() return nil end,
}
sys = {
    publish = function() end,
    taskInit = function(handler) worker = handler end,
    waitUntil = function() error("STOP_WORKER") end,
    wait = function() error("STOP_WORKER") end,
    timerStart = function() end,
}
package.loaded.util_notify_channel = {
    validate = function() return true end,
    ready = function() return true end,
    send = function(channel, envelope)
        table.insert(sent, { channel = channel, envelope = envelope })
        if send_success then return { success = true } end
        return { success = false, failure_class = "network", detail = "remote-sensitive" }
    end,
}
package.loaded.util_network = {
    isReady = function() return network_ready end,
    currentAdapter = function() return network_ready and 2 or nil end,
}
package.loaded.util_mobile = { deviceInfo = function() return "device-info" end }

local util_notify = require "util_notify"
local function runWorker()
    local ok, err = pcall(worker)
    support.assertFalse(ok, "worker stopped by harness")
    support.assertContains(tostring(err), "STOP_WORKER", "worker stop reason")
end
local function storedCount()
    local count = 0
    for key in pairs(store) do if key:match("^notify%-v2%-") then count = count + 1 end end
    return count
end

util_notify.init()
support.assertTrue(util_notify.isBarkEnabled(), "enabled Bark detected")
support.assertEqual(util_notify.getStatus().enabled_channels, 2, "enabled channel count")
support.assertTrue(util_notify.addSms({ sender = "10086", content = "ordinary", received_at = "now" }), "SMS queued")
support.assertEqual(storedCount(), 1, "task persisted before delivery")
runWorker()
support.assertEqual(#sent, 0, "offline worker does not send")
support.assertEqual(util_notify.getStatus().retrying_count, 0, "offline wait is not retry")

network_ready = true
runWorker()
support.assertEqual(#sent, 1, "SMS sent after network recovery")
support.assertEqual(sent[1].channel, "archive", "ordinary SMS uses all channel")
support.assertEqual(storedCount(), 0, "successful task removed")
support.assertEqual(util_notify.getStatus().last_full_success_tick, tick, "full channel success tracked")

send_success = false
support.assertTrue(util_notify.addSms({ sender = "10086", content = "code 123", received_at = "now" }), "verification SMS queued")
runWorker()
support.assertEqual(#sent, 2, "verification task attempted")
support.assertEqual(util_notify.getStatus().retrying_count, 1, "failed task retained for retry")
local rendered_logs = ""
for _, entry in ipairs(log_events) do for _, value in ipairs(entry) do rendered_logs = rendered_logs .. " " .. tostring(value) end end
support.assertContains(rendered_logs, "remote-sensitive", "remote failure detail logged")

send_success = true
support.assertTrue(util_notify.addSms({ sender = "10086", content = "new", received_at = "now" }), "new SMS queued")
runWorker()
support.assertEqual(#sent, 3, "new due task bypasses delayed retry")
support.assertEqual(util_notify.getStatus().queue_length, 2, "failed tasks remain delayed")

local before_system = #sent
support.assertTrue(util_notify.addSystem("#TEST", true, true), "system notification queued")
runWorker()
runWorker()
support.assertEqual(#sent, before_system + 2, "system notification reaches both channels")
support.assertTrue(sent[#sent - 1].envelope.device_info == "device-info"
    or sent[#sent].envelope.device_info == "device-info", "device info added")

local test_ok, message_id = util_notify.addChannelTest("archive")
support.assertTrue(test_ok, "channel test queued")
support.assertEqual(util_notify.getChannelTest("archive").state, "queued", "channel test queued state")
for _ = 1, 3 do
    if util_notify.getChannelTest("archive").state == "success" then break end
    runWorker()
end
support.assertEqual(util_notify.getChannelTest("archive").state, "success", "channel test success state")
support.assertEqual(util_notify.getChannelTest("archive").message_id, message_id, "channel test message id")
support.assertFalse(util_notify.addChannelTest("missing"), "missing channel test rejected")

support.assertFalse(util_notify.setBarkEnabled(false), "Bark disabled")
support.assertFalse(util_notify.isBarkEnabled(), "Bark state false")
support.assertTrue(util_notify.toggleBark(), "Bark toggled on")
support.assertTrue(util_notify.isBarkEnabled(), "Bark state true")
support.assertTrue(util_notify.addCall({ sender = "10010", content = "call", call_state = "CONNECTED" }), "call queued")
runWorker()

config.DIAGNOSTIC_LOGS = false
local diagnostic_count = #diag_events
util_notify.addSystem("#SILENT", false, false)
support.assertEqual(#diag_events, diagnostic_count, "diagnostics disabled")

print("util_notify tests passed")
