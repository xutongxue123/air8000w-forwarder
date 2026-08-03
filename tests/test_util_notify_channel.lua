local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local test_dir = source:match("^(.*[/])") or "tests/"
package.path = test_dir .. "../script/?.lua;" .. test_dir .. "?.lua;" .. (package.path or "")
local support = dofile(test_dir .. "test_support.lua")
support.clearModules({ "util_notify_channel" })

if not string.urlEncode then
    function string.urlEncode(value)
        return tostring(value):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", string.byte(c)) end)
    end
end

local captured, requests = {}, {}
local response_code, response_body = 200, "ok"
local sync_count = 0
config = {}
log = { info = function() end, warn = function() end, error = function() end }
package.loaded.util_http = {
    fetch = function(_, method, url, headers, body)
        table.insert(requests, { method = method, url = url, headers = headers, body = body })
        return response_code, {}, response_body
    end,
}
package.loaded.util_network = { syncTime = function() sync_count = sync_count + 1 return true end }
crypto = {
    hmac_sha256 = function(message, key)
        captured.hmac_message, captured.hmac_key = message, key
        local value = {}
        value.feishu = message == ""
        function value:fromHex() return self end
        function value:toBase64()
            if self.feishu then return "encoded-feishu-signature" end
            return self
        end
        function value:urlEncode() return "encoded-signature" end
        return value
    end,
}
json = {
    encode = function(value) captured.json_value = value return "encoded-body" end,
    decode = function(value)
        if value == "bark-reject" then return { code = 400 } end
        if value == "ding-ok" then return { errcode = 0 } end
        if value == "ding-reject" then return { errcode = 310000, errmsg = "rejected" } end
        if value == "feishu-ok" then return { code = 0 } end
        if value == "feishu-reject" then return { code = 1, msg = "rejected" } end
        if value == "custom-ok" then return { ok = 1 } end
        if value == "custom-bad" then return { ok = 0 } end
        error("invalid response")
    end,
}

local app_config = {
    CHANNELS = {
        bark = { type = "bark", api = "https://bark.test/", key = "device-key", group = "ops",
            sms_title_template = "{sender}", sms_template = "SMS {content} {device_info}" },
        dingtalk = { type = "dingtalk", webhook = "https://ding.test/robot?access_token=token",
            secret = "secret", require_signature = true, sms_title_template = "{sender}" },
        feishu = { type = "feishu", webhook = "https://feishu.test/hook", secret = "feishu-secret",
            require_signature = true, title_template = "title" },
        webhook = { type = "webhook", url = "https://webhook.test", headers = { ["X-Test"] = "yes" },
            sms_title_template = "SMS", sms_template = "{content}" },
        custom = { type = "custom_post", url = "https://custom.test", headers = {}, body = {
            message_id = "{message_id}", nested = { content = "{content}" },
        }, success_json_field = "ok", success_json_value = 1 },
        form = { type = "custom_post", url = "https://form.test", content_type = "text/plain",
            body = { message_id = "{message_id}", content = "{content}" } },
    },
}
local envelope = {
    id = "m-1", kind = "sms", sender = "10086", content = "code 123456",
    received_at = "2026-08-03 10:00:00", device_info = "device-info",
}
local registry = require "util_notify_channel"

support.assertFalse(registry.validate("missing", app_config), "missing channel validation")
support.assertTrue(registry.validate("bark", app_config), "Bark validation")
support.assertTrue(registry.validate("custom", app_config), "custom validation")
support.assertFalse(registry.validate("unknown", { CHANNELS = { unknown = { type = "unknown" } } }),
    "unsupported channel validation")
support.assertTrue(registry.ready("bark", app_config), "Bark ready")

local result = registry.send("bark", envelope, app_config)
support.assertTrue(result.success, "Bark success")
support.assertEqual(requests[#requests].url, "https://bark.test/push", "Bark URL normalization")
support.assertEqual(captured.json_value.device_key, "device-key", "Bark key")
support.assertContains(captured.json_value.body, "device-info", "Bark device information")
response_body = "bark-reject"
support.assertFalse(registry.send("bark", envelope, app_config).success, "Bark business rejection")
response_body = ""
support.assertFalse(registry.send("bark", envelope, app_config).success, "Bark empty response")
response_body = "ok"
response_code = 503
local bark_failure = registry.send("bark", envelope, app_config)
support.assertEqual(bark_failure.failure_class, "remote", "Bark HTTP failure class")
response_code = 200

local original_time = os.time
os.time = function() return 1760000000 end
support.assertTrue(registry.ready("feishu", app_config), "Feishu ready with synchronized clock")
response_body = "feishu-ok"
result = registry.send("feishu", envelope, app_config)
support.assertTrue(result.success, "Feishu success")
support.assertEqual(captured.hmac_message, "", "Feishu signing message")
support.assertEqual(captured.hmac_key, "1760000000\nfeishu-secret", "Feishu signing key")
support.assertEqual(captured.json_value.timestamp, "1760000000", "Feishu timestamp")
support.assertEqual(captured.json_value.sign, "encoded-feishu-signature", "Feishu signature")
response_body = "feishu-reject"
support.assertContains(registry.send("feishu", envelope, app_config).detail,
    "Feishu rejected code=1", "Feishu business rejection")
response_code = -1
support.assertEqual(registry.send("feishu", envelope, app_config).failure_class, "network", "Feishu network class")
response_code = 200
os.time = original_time

result = registry.send("webhook", envelope, app_config)
support.assertTrue(result.success, "Webhook success")
support.assertEqual(requests[#requests].headers["X-Test"], "yes", "Webhook custom header")
support.assertEqual(requests[#requests].headers["X-Message-ID"], "m-1", "Webhook idempotency header")
support.assertEqual(requests[#requests].headers["Content-Type"], "application/json; charset=utf-8", "Webhook content type")

original_time = os.time
os.time = function() return 1600000000 end
support.assertFalse(registry.ready("dingtalk", app_config), "DingTalk waits for valid clock")
support.assertEqual(sync_count, 1, "DingTalk requests time sync")
os.time = function() return 1760000000 end
response_body = "ding-ok"
result = registry.send("dingtalk", envelope, app_config)
support.assertTrue(result.success, "DingTalk signed success")
support.assertContains(requests[#requests].url, "timestamp=1760000000000", "DingTalk timestamp")
support.assertContains(requests[#requests].url, "sign=encoded-signature", "DingTalk signature")
support.assertEqual(captured.hmac_key, "secret", "DingTalk signing key")
response_body = "ding-reject"
support.assertContains(registry.send("dingtalk", envelope, app_config).detail,
    "DingTalk rejected errcode=310000", "DingTalk rejection")
os.time = original_time
response_body = "ok"

response_body = "custom-ok"
result = registry.send("custom", envelope, app_config)
support.assertTrue(result.success, "custom JSON success")
support.assertContains(captured.json_value.nested.content, "code 123456", "nested template replacement")
support.assertEqual(app_config.CHANNELS.custom.body.message_id, "{message_id}", "custom template not mutated")
response_body = "custom-bad"
support.assertEqual(registry.send("custom", envelope, app_config).detail,
    "archive rejected configured success field", "custom JSON rejection")
response_body = "ok"
result = registry.send("form", envelope, app_config)
support.assertTrue(result.success, "custom form success")
support.assertContains(requests[#requests].body, "message_id=m-1", "form message id")

local nested_form = { CHANNELS = { form = { type = "custom_post", url = "x", content_type = "text/plain", body = { nested = { value = "x" } } } } }
support.assertEqual(registry.send("form", envelope, nested_form).failure_class, "configuration", "nested form rejected")
support.assertEqual(registry.send("missing", envelope, app_config).failure_class, "configuration", "missing send rejected")

print("util_notify_channel tests passed")
