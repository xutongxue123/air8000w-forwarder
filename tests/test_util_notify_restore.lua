local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local test_dir = source:match("^(.*[/])") or "tests/"
package.path = test_dir .. "../script/?.lua;" .. test_dir .. "?.lua;" .. (package.path or "")
local support = dofile(test_dir .. "test_support.lua")
support.clearModules({ "util_notify", "util_router", "util_notify_channel", "util_mobile", "util_network" })

local store = {
    ["notify-v2-new-task"] = "new-record",
    ["msg-legacy-task"] = "legacy-record",
}
local keys = { "notify-v2-new-task", "msg-legacy-task" }
local sent, worker = {}, nil
config = { DIAGNOSTIC_LOGS = false, CHANNELS = {
    archive = { type = "custom_post", enabled = true, sms_mode = "all", system_enabled = true },
} }
mcu = { ticks = function() return 1000 end }
log = { info = function() end, warn = function() end, error = function() end }
json = {
    encode = function() return "encoded" end,
    decode = function(value)
        if value == "new-record" then
            return { schema = "notify_task_v2", task_id = "new-task", message_id = "new-message",
                channel = "archive", envelope = { id = "new-message", kind = "sms", sender = "10086",
                    content = "new content", received_at = "now" }, created_at = 1 }
        end
        if value == "legacy-record" then
            return { notify_queue_v1 = true, id = "legacy-message", channel = "archive", msg = "legacy content" }
        end
        error("unexpected record")
    end,
}
fskv = {
    get = function(key) return store[key] end,
    set = function(key, value) store[key] = value return true end,
    del = function(key) store[key] = nil return true end,
    iter = function() return { index = 0 } end,
    next = function(iter) iter.index = iter.index + 1 return keys[iter.index] end,
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
        return { success = true }
    end,
}
package.loaded.util_network = { isReady = function() return true end, currentAdapter = function() return 2 end }
package.loaded.util_mobile = { deviceInfo = function() return "device-info" end }

local util_notify = require "util_notify"
util_notify.init()
support.assertEqual(util_notify.getStatus().queue_length, 2, "new and legacy tasks restored")

local function runWorker()
    local ok, err = pcall(worker)
    support.assertFalse(ok, "worker stopped by harness")
end
runWorker()
runWorker()
support.assertEqual(#sent, 2, "restored tasks sent")
support.assertEqual(sent[1].envelope.content, "new content", "new task content")
support.assertEqual(sent[2].envelope.content, "legacy content", "legacy task content")
support.assertEqual(store["notify-v2-new-task"], nil, "new task removed")
support.assertEqual(store["msg-legacy-task"], nil, "legacy task removed")
support.assertEqual(util_notify.getStatus().queue_length, 0, "restored queue drained")

print("util_notify restore tests passed")
