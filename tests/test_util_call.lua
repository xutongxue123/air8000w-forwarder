local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local test_dir = source:match("^(.*[/])") or "tests/"
package.path = test_dir .. "../script/?.lua;" .. test_dir .. "?.lua;" .. (package.path or "")
local support = dofile(test_dir .. "test_support.lua")
support.clearModules({ "util_call" })

local subscriptions, calls, history_records, logs, diagnostics = {}, {}, {}, {}, {}
local last_number = "+8613800138000"
config = { DIAGNOSTIC_LOGS = true, CALL = {
    enabled = true,
    events = { INCOMINGCALL = true, CONNECTED = true, DISCONNECTED = true, MAKE_CALL_OK = false },
} }
log = {
    info = function(...) table.insert(logs, { ... }) end,
    warn = function(...) table.insert(logs, { ... }) end,
    error = function(...) table.insert(logs, { ... }) end,
}
USER_LOG_INFO = function(component, ...) table.insert(logs, { component, ... }) end
USER_DIAG = function(component, event, ...) table.insert(diagnostics, { component, event, ... }) end
mcu = { ticks = function() return 1234000 end }
cc = { lastNum = function() return last_number end }
sys = { subscribe = function(event, handler) subscriptions[event] = handler end }
package.loaded.util_notify = { addCall = function(envelope) table.insert(calls, envelope) return true end }
package.loaded.util_history = { addCall = function(...) table.insert(history_records, { ... }) return true end }

local util_call = require "util_call"
support.assertTrue(util_call.init(), "call listener initialized")
support.assertFalse(util_call.init(), "call listener initialized once")
support.assertEqual(type(subscriptions.CC_IND), "function", "CC_IND subscription")
support.assertEqual(type(subscriptions.CC_READY), "function", "CC_READY subscription")
subscriptions.CC_READY()
subscriptions.CC_IND("READY")
subscriptions.CC_IND("PLAY")
support.assertEqual(#calls, 0, "ready/play do not notify")

subscriptions.CC_IND("INCOMINGCALL", "ignored")
support.assertEqual(#history_records, 1, "incoming call saved to history")
support.assertEqual(history_records[1][1], last_number, "cc.lastNum number preferred")
support.assertEqual(#calls, 1, "incoming call notified")
support.assertEqual(calls[1].call_state, "INCOMINGCALL", "incoming call state")

subscriptions.CC_IND("INCOMINGCALL", { number = "10010" })
support.assertEqual(#history_records, 1, "duplicate incoming call not duplicated")
support.assertEqual(#calls, 1, "duplicate incoming call not notified")

last_number = ""
subscriptions.CC_IND("CALL_NUMBER", { caller = "  10010-200  " })
support.assertEqual(#calls, 1, "number-only event not notified")
subscriptions.CC_IND("CONNECTED")
support.assertEqual(#calls, 2, "enabled connected event notified")
support.assertEqual(calls[2].sender, "10010200", "fallback caller number normalized")
subscriptions.CC_IND("CONNECTED")
support.assertEqual(#calls, 2, "duplicate connected event not notified")

subscriptions.CC_IND("MAKE_CALL_FAILED", { phone = "12345" })
support.assertEqual(#calls, 2, "disabled call event ignored")
config.CALL.events.MAKE_CALL_OK = true
subscriptions.CC_IND("MAKE_CALL_OK", { phone = "12345" })
support.assertEqual(#calls, 3, "enabled dial event notified")

subscriptions.CC_IND("DISCONNECTED")
support.assertEqual(#calls, 4, "disconnect event notified")
subscriptions.CC_IND("CONNECTED")
support.assertEqual(calls[5].sender, "", "number cleared after disconnect")
support.assertTrue(#diagnostics > 0, "call diagnostics emitted")

print("util_call tests passed")
