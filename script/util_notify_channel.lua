local util_http = require "util_http"
local util_network = require "util_network"

local util_notify_channel = {}
local channels = {}
local renderTemplate
local renderTitle

local function failure(class, detail)
    return { success = false, failure_class = class, detail = detail }
end

local function httpFailureClass(code)
    if type(code) ~= "number" or code < 0 then return "network" end
    return "remote"
end

local function responseText(response_body)
    if type(response_body) ~= "string" or response_body == "" then return "<empty>" end
    if #response_body > 1024 then
        return response_body:sub(1, 1024) .. "...<truncated>"
    end
    return response_body
end

local function httpFailure(channel_name, code, response_body)
    return failure(httpFailureClass(code), channel_name .. " HTTP request failed"
        .. "; code=" .. tostring(code or "nil")
        .. "; response=" .. responseText(response_body))
end

local function renderBark(envelope, channel_config)
    local templated = (envelope.kind == "sms" or envelope.kind == "call" or envelope.kind == "system")
        and renderTemplate(channel_config and channel_config[envelope.kind .. "_template"], envelope)
    if templated then return templated end
    local content
    if envelope.kind == "sms" then
        content = table.concat({
            tostring(envelope.content or ""),
            "",
            "发件号码: " .. tostring(envelope.sender or ""),
            "发件时间: " .. tostring(envelope.received_at or ""),
            "#SMS",
        }, "\n")
    elseif envelope.kind == "call" then
        local raw_content = tostring(envelope.content or "")
        local status = raw_content:match("(状态: .*)") or raw_content
        local event_tag = envelope.call_state and ("#" .. tostring(envelope.call_state))
            or "#CALL"
        content = table.concat({
            "电话号码: " .. tostring(envelope.sender or ""),
            status,
            "事件时间: " .. tostring(envelope.received_at or ""),
            event_tag,
        }, "\n")
    else
        content = tostring(envelope.content or "")
    end
    if type(envelope.device_info) == "string" and envelope.device_info ~= "" then
        content = content .. "\n\n" .. envelope.device_info
    end
    return content
end

channels.bark = {
    validate = function(channel_config)
        if type(channel_config.api) ~= "string" or channel_config.api == "" then
            return false, "Bark API is empty"
        end
        if type(channel_config.key) ~= "string" or channel_config.key == "" then
            return false, "Bark key is empty"
        end
        return true
    end,
    send = function(envelope, channel_config)
        local url = channel_config.api:gsub("/+$", "") .. "/push"
        local headers = { ["Content-Type"] = "application/json; charset=utf-8" }
        local body = json.encode({
            device_key = channel_config.key,
            title = renderTitle(envelope, channel_config),
            body = envelope.kind == "sms"
                and (renderTemplate(channel_config.sms_template, envelope) or renderBark(envelope, channel_config))
                or renderBark(envelope, channel_config),
            group = channel_config.group or "Air8000W",
        })
        if type(body) ~= "string" then
            return failure("exception", "Bark request encoding failed")
        end
        local code, _, response_body = util_http.fetch(nil, "POST", url, headers, body)
        if type(code) ~= "number" or code < 200 or code >= 300 then
            return failure(httpFailureClass(code), "Bark HTTP request failed")
        end
        if type(response_body) ~= "string" or response_body == "" then
            return failure("remote", "Bark response is empty")
        end
        -- Bark 已返回 2xx 即表示 HTTP 请求成功。不同 Bark 服务端版本的
        -- 响应 JSON 结构可能不同，因此只在能明确读到非 200 业务码时判失败。
        local decoded_ok, response = pcall(json.decode, response_body)
        if decoded_ok and type(response) == "table" and response.code ~= nil then
            local response_code = tonumber(response.code)
            if response_code ~= nil and response_code ~= 200 then
                return failure("remote", "Bark rejected the request")
            end
        end
        return { success = true }
    end,
}

local function clone(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[clone(key, seen)] = clone(item, seen) end
    return result
end

local function replaceString(value, replacements)
    for placeholder, replacement in pairs(replacements) do
        value = value:gsub("{" .. placeholder .. "}", function() return replacement end)
    end
    return value
end

local function replace(value, replacements, seen)
    if type(value) == "string" then return replaceString(value, replacements) end
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return value end
    seen[value] = true
    for key, item in pairs(value) do value[key] = replace(item, replacements, seen) end
    return value
end

local function urlencodeTable(params)
    local parts = {}
    for key, value in pairs(params) do
        if type(value) == "table" then return nil end
        table.insert(parts, string.urlEncode(tostring(key)) .. "=" .. string.urlEncode(tostring(value)))
    end
    return table.concat(parts, "&")
end

local function templateReplacements(envelope)
    local call_status = tostring(envelope.content or ""):match("状态: (.*)")
    return {
        message_id = tostring(envelope.id or ""),
        kind = tostring(envelope.kind or ""),
        sender = tostring(envelope.sender or ""),
        content = tostring(envelope.content or ""),
        call_status = call_status or tostring(envelope.content or ""),
        received_at = tostring(envelope.received_at or ""),
        device_info = tostring(envelope.device_info or ""),
    }
end

renderTemplate = function(template, envelope)
    if type(template) ~= "string" or template == "" then return nil end
    return replaceString(template, templateReplacements(envelope))
end

local function renderContent(envelope, channel_config)
    local template = channel_config and channel_config[envelope.kind .. "_template"]
    local content = (envelope.kind == "sms" or envelope.kind == "call" or envelope.kind == "system")
        and renderTemplate(template, envelope)
        or nil
    content = content or tostring(envelope.content or "")
    local template_has_device_info = type(template) == "string"
        and template:find("{device_info}", 1, true) ~= nil
    if type(envelope.device_info) == "string" and envelope.device_info ~= ""
        and not template_has_device_info then
        content = content .. "\n\n" .. envelope.device_info
    end
    return content
end

renderTitle = function(envelope, channel_config)
    local key = envelope.kind == "sms" and "sms_title_template"
        or envelope.kind == "call" and "call_title_template"
        or envelope.kind == "system" and "system_title_template"
        or "title_template"
    return renderTemplate(channel_config and channel_config[key], envelope)
        or renderTemplate(channel_config and channel_config.title_template, envelope)
        or ""
end

local function renderNotificationText(envelope, channel_config)
    local title = renderTitle(envelope, channel_config)
    local content = renderContent(envelope, channel_config)
    if title == "" then return content end
    return title .. "\n" .. content
end

channels.feishu = {
    ready = function(channel_config)
        local secret = channel_config.secret
        if type(secret) ~= "string" or secret == "" then return true end
        local now = os.time()
        if type(now) == "number" and now >= 1714500000 then return true end
        util_network.syncTime()
        return false, "clock"
    end,
    validate = function(channel_config)
        if type(channel_config.webhook) ~= "string" or channel_config.webhook == "" then
            return false, "Feishu webhook is empty"
        end
        if channel_config.secret ~= nil and type(channel_config.secret) ~= "string" then
            return false, "Feishu secret is invalid"
        end
        if channel_config.require_signature == true
            and (type(channel_config.secret) ~= "string" or channel_config.secret == "") then
            return false, "Feishu secret is empty"
        end
        return true
    end,
    send = function(envelope, channel_config)
        local timestamp
        local sign
        local secret = channel_config.secret
        if type(secret) == "string" and secret ~= "" then
            local now = os.time()
            if type(now) ~= "number" or now < 1714500000 then
                util_network.syncTime()
                return failure("network", "Feishu clock is not synchronized")
            end
            timestamp = tostring(now)
            local sign_ok, sign_value = pcall(function()
                return crypto.hmac_sha256("", timestamp .. "\n" .. secret)
                    :fromHex():toBase64()
            end)
            if not sign_ok or type(sign_value) ~= "string" or sign_value == "" then
                return failure("exception", "Feishu signature generation failed")
            end
            sign = sign_value
        end
        local request = {
            msg_type = "text",
            content = { text = renderNotificationText(envelope, channel_config) },
        }
        if timestamp and sign then
            request.timestamp = timestamp
            request.sign = sign
        end
        local ok, body = pcall(json.encode, request)
        if not ok or type(body) ~= "string" then return failure("exception", "Feishu request encoding failed") end
        local code, _, response_body = util_http.fetch(nil, "POST", channel_config.webhook,
            { ["Content-Type"] = "application/json; charset=utf-8" }, body)
        if type(code) ~= "number" or code < 200 or code >= 300 then
            return httpFailure("Feishu", code, response_body)
        end
        local decode_ok, response = pcall(json.decode, response_body or "")
        if not decode_ok or type(response) ~= "table" then
            return failure("remote", "Feishu response JSON is invalid; response="
                .. responseText(response_body))
        end
        local response_code = response.code
        if response_code == nil then response_code = response.StatusCode end
        if response_code == nil then response_code = response.status_code end
        local response_message = response.msg
            or response.StatusMessage
            or response.status_message
            or ""
        if response_code == nil then
            return failure("remote", "Feishu response is missing status code; response="
                .. responseText(response_body))
        end
        if tonumber(response_code) ~= 0 then
            return failure("remote", "Feishu rejected code=" .. tostring(response_code)
                .. "; msg=" .. tostring(response_message)
                .. "; response=" .. responseText(response_body))
        end
        return { success = true }
    end,
}

channels.webhook = {
    validate = function(channel_config)
        if type(channel_config.url) ~= "string" or channel_config.url == "" then
            return false, "Webhook URL is empty"
        end
        return channel_config.headers == nil or type(channel_config.headers) == "table", "Webhook headers are invalid"
    end,
    send = function(envelope, channel_config)
        local ok, body = pcall(json.encode, {
            message_id = tostring(envelope.id or ""),
            kind = tostring(envelope.kind or ""),
            sender = tostring(envelope.sender or ""),
            title = renderTitle(envelope, channel_config),
            content = renderContent(envelope, channel_config),
            received_at = tostring(envelope.received_at or ""),
        })
        if not ok or type(body) ~= "string" then return failure("exception", "Webhook request encoding failed") end
        local headers = clone(channel_config.headers or {})
        headers["Content-Type"] = headers["Content-Type"] or "application/json; charset=utf-8"
        headers["X-Message-ID"] = tostring(envelope.id or "")
        local code = util_http.fetch(nil, "POST", channel_config.url, headers, body)
        if type(code) ~= "number" or code < 200 or code >= 300 then
            return httpFailure("Webhook", code)
        end
        return { success = true }
    end,
}

local function renderDingTalk(envelope, channel_config)
    local templated = (envelope.kind == "sms" or envelope.kind == "call" or envelope.kind == "system")
        and renderTemplate(channel_config and channel_config[envelope.kind .. "_template"], envelope)
    if templated then return templated end
    local titles = {
        sms = "Air8000W 短信归档",
        call = "Air8000W 通话通知",
        system = "Air8000W 系统通知",
    }
    local sender_label = envelope.kind == "call" and "电话号码" or "发送方"
    return table.concat({
        titles[envelope.kind] or "Air8000W 通知",
        "消息ID: " .. tostring(envelope.id or ""),
        "类型: " .. tostring(envelope.kind or ""),
        sender_label .. ": " .. tostring(envelope.sender or ""),
        "时间: " .. tostring(envelope.received_at or ""),
        "内容: " .. renderContent(envelope, channel_config),
    }, "\n")
end

local function dingTalkUrl(channel_config)
    local webhook = channel_config.webhook
    local secret = channel_config.secret
    if type(secret) ~= "string" or secret == "" then return webhook end

    local now = os.time()
    if type(now) ~= "number" or now < 1714500000 then
        util_network.syncTime()
        return nil, "DingTalk clock is not synchronized"
    end
    local timestamp = tostring(now) .. "000"
    local ok, sign = pcall(function()
        return crypto.hmac_sha256(timestamp .. "\n" .. secret, secret)
            :fromHex():toBase64():urlEncode()
    end)
    if not ok or type(sign) ~= "string" or sign == "" then
        return nil, "DingTalk signature generation failed"
    end
    local separator = webhook:find("?", 1, true) and "&" or "?"
    return webhook .. separator .. "timestamp=" .. timestamp .. "&sign=" .. sign
end

channels.dingtalk = {
    ready = function(channel_config)
        local secret = channel_config.secret
        if type(secret) ~= "string" or secret == "" then return true end
        local now = os.time()
        if type(now) == "number" and now >= 1714500000 then return true end
        util_network.syncTime()
        return false, "clock"
    end,
    validate = function(channel_config)
        if type(channel_config.webhook) ~= "string" or channel_config.webhook == "" then
            return false, "DingTalk webhook is empty"
        end
        if channel_config.secret ~= nil and type(channel_config.secret) ~= "string" then
            return false, "DingTalk secret is invalid"
        end
        if channel_config.require_signature == true
            and (type(channel_config.secret) ~= "string" or channel_config.secret == "") then
            return false, "DingTalk secret is empty"
        end
        return true
    end,
    send = function(envelope, channel_config)
        local url, url_error = dingTalkUrl(channel_config)
        if not url then return failure("network", url_error) end

        local ok, body = pcall(json.encode, {
            msgtype = "text",
            text = { content = renderNotificationText(envelope, channel_config) },
        })
        if not ok or type(body) ~= "string" then
            return failure("exception", "DingTalk request encoding failed")
        end
        local headers = { ["Content-Type"] = "application/json; charset=utf-8" }
        local code, _, response_body = util_http.fetch(nil, "POST", url, headers, body)
        if type(code) ~= "number" or code < 200 or code >= 300 then
            return httpFailure("DingTalk", code, response_body)
        end

        local decode_ok, response = pcall(json.decode, response_body or "")
        if not decode_ok or type(response) ~= "table" then
            return failure("remote", "DingTalk response JSON is invalid; response="
                .. responseText(response_body))
        end
        local errcode = tonumber(response.errcode)
        if errcode ~= 0 then
            local errmsg = type(response.errmsg) == "string" and response.errmsg or ""
            if errcode == 310000
                and (errmsg:find("timestamp", 1, true) or errmsg:find("过期", 1, true)) then
                util_network.syncTime()
            end
            return failure("remote", "DingTalk rejected errcode=" .. tostring(errcode)
                .. "; errmsg=" .. tostring(errmsg)
                .. "; response=" .. responseText(response_body))
        end
        return { success = true }
    end,
}

channels.custom_post = {
    validate = function(channel_config)
        if type(channel_config.url) ~= "string" or channel_config.url == "" then
            return false, "archive URL is empty"
        end
        if channel_config.headers ~= nil and type(channel_config.headers) ~= "table" then
            return false, "archive headers are invalid"
        end
        if type(channel_config.body) ~= "table" then
            return false, "archive body template is invalid"
        end
        if channel_config.success_json_field ~= nil
            and (type(channel_config.success_json_field) ~= "string"
                or channel_config.success_json_field == "") then
            return false, "archive success JSON field is invalid"
        end
        return true
    end,
    send = function(envelope, channel_config)
        local replacements = templateReplacements(envelope)
        replacements.title = renderTitle(envelope, channel_config)
        replacements.content = renderContent(envelope, channel_config)
        local headers = clone(channel_config.headers or {})
        headers["X-Message-ID"] = tostring(envelope.id or "")
        local body_table = replace(clone(channel_config.body), replacements)
        local content_type = tostring(channel_config.content_type or "application/json")
        local body
        if content_type:lower():find("json", 1, true) then
            local ok
            ok, body = pcall(json.encode, body_table)
            if not ok or type(body) ~= "string" then
                return failure("configuration", "archive body JSON encoding failed")
            end
        else
            body = urlencodeTable(body_table)
            if not body then return failure("configuration", "archive form body cannot be nested") end
        end

        local code, _, response_body = util_http.fetch(nil, "POST", channel_config.url, headers, body)
        if type(code) ~= "number" or code < 200 or code >= 300 then
            return failure(httpFailureClass(code), "archive HTTP request failed")
        end
        local success_field = channel_config.success_json_field
        if type(success_field) == "string" and success_field ~= "" then
            local ok, response = pcall(json.decode, response_body or "")
            if not ok or type(response) ~= "table" then
                return failure("remote", "archive response JSON is invalid")
            end
            local actual = response[success_field]
            local expected = channel_config.success_json_value
            local matches
            if type(expected) == "number" then
                matches = tonumber(actual) == expected
            else
                matches = actual == expected
            end
            if not matches then
                return failure("remote", "archive rejected configured success field")
            end
        else
            local keyword = channel_config.success_keyword
            if type(keyword) == "string" and keyword ~= ""
                and (type(response_body) ~= "string" or not response_body:find(keyword, 1, true)) then
                return failure("remote", "archive success keyword is missing")
            end
        end
        return { success = true }
    end,
}

local function getChannel(channel_type)
    local channel = channels[channel_type]
    if not channel then return nil, "unsupported channel type" end
    return channel
end

function util_notify_channel.validate(channel_name, app_config)
    local channel_config = app_config.CHANNELS and app_config.CHANNELS[channel_name]
    if type(channel_config) ~= "table" then
        return false, "channel is not configured"
    end
    local channel, err = getChannel(channel_config.type)
    if not channel then return false, err end
    local ok, valid, detail = pcall(channel.validate, channel_config)
    if not ok then return false, "channel validation exception" end
    return valid == true, detail
end

function util_notify_channel.ready(channel_name, app_config)
    local channel_config = app_config.CHANNELS and app_config.CHANNELS[channel_name]
    if type(channel_config) ~= "table" then return true end
    local channel = getChannel(channel_config.type)
    if not channel or type(channel.ready) ~= "function" then return true end
    local ok, ready, reason = pcall(channel.ready, channel_config)
    if not ok then return true end
    return ready ~= false, reason
end

function util_notify_channel.send(channel_name, envelope, app_config)
    local channel_config = app_config.CHANNELS and app_config.CHANNELS[channel_name]
    if type(channel_config) ~= "table" then
        return failure("configuration", "channel is not configured")
    end
    local channel, err = getChannel(channel_config.type)
    if not channel then return failure("configuration", err) end

    local valid, detail = channel.validate(channel_config)
    if not valid then return failure("configuration", detail) end
    local ok, result = pcall(channel.send, envelope, channel_config)
    if not ok then
        log.error("notify", "channel exception", channel_name, tostring(result))
        return failure("exception", "channel raised an exception: " .. tostring(result))
    end
    if type(result) ~= "table" or type(result.success) ~= "boolean" then
        return failure("exception", "channel returned an invalid result")
    end
    return result
end

return util_notify_channel
