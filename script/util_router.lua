local util_router = {}

local VALID_SMS_MODES = { all = true, verification = true }

local function sortedChannelNames(app_config)
    local names = {}
    local channels = type(app_config) == "table" and app_config.CHANNELS or nil
    if type(channels) ~= "table" then return names end
    for name in pairs(channels) do
        if type(name) == "string" and name ~= "" then table.insert(names, name) end
    end
    table.sort(names)
    return names
end

local function patternMatches(value, pattern)
    if type(value) ~= "string" or type(pattern) ~= "string" or pattern == "" then
        return false, nil
    end
    local ok, matched = pcall(string.find, value, pattern)
    if not ok then return false, matched end
    return matched ~= nil, nil
end

local function keywordFilter(app_config, channel_config)
    local global_filter = type(app_config) == "table" and app_config.KEYWORD_FILTER or nil
    if type(global_filter) == "table" then return global_filter end
    -- Compatibility for configurations saved by older firmware.
    return type(channel_config.match) == "table" and channel_config.match or {}
end

local function collectConditions(message, match)
    local conditions, errors = {}, {}
    for _, pattern in ipairs(match.content_patterns or {}) do
        local matched, err = patternMatches(message.content or "", pattern)
        table.insert(conditions, matched)
        if err then table.insert(errors, tostring(err)) end
    end
    for _, pattern in ipairs(match.sender_patterns or {}) do
        local matched, err = patternMatches(message.sender or "", pattern)
        table.insert(conditions, matched)
        if err then table.insert(errors, tostring(err)) end
    end
    return conditions, errors
end

function util_router.matches(message, channel_config, app_config)
    if type(message) ~= "table" or type(channel_config) ~= "table" then
        return false, { "invalid message or channel policy" }
    end
    local match = keywordFilter(app_config, channel_config)
    local conditions, errors = collectConditions(message, match)
    if #conditions == 0 then return false, errors end
    if match.mode == "all" then
        for _, matched in ipairs(conditions) do
            if not matched then return false, errors end
        end
        return true, errors
    end
    for _, matched in ipairs(conditions) do
        if matched then return true, errors end
    end
    return false, errors
end

local function validatePatterns(patterns, field)
    if patterns == nil then return true, nil, 0 end
    if type(patterns) ~= "table" then return false, field .. " must be a table", 0 end
    local count = 0
    for index, pattern in ipairs(patterns) do
        if type(pattern) ~= "string" or pattern == "" then
            return false, field .. " pattern " .. tostring(index) .. " is invalid", count
        end
        local ok = pcall(string.find, "", pattern)
        if not ok then return false, field .. " pattern " .. tostring(index) .. " is invalid", count end
        count = count + 1
    end
    return true, nil, count
end

function util_router.validatePolicy(channel_name, channel_config, app_config)
    if type(channel_config) ~= "table" then return false, "channel policy is missing" end
    local mode = channel_config.sms_mode
    if not VALID_SMS_MODES[mode] then return false, "sms_mode is invalid" end
    if channel_config.system_enabled ~= nil and type(channel_config.system_enabled) ~= "boolean" then
        return false, "system_enabled must be boolean"
    end
    if channel_config.call_enabled ~= nil and type(channel_config.call_enabled) ~= "boolean" then
        return false, "call_enabled must be boolean"
    end
    if mode ~= "verification" then return true end
    local match = keywordFilter(app_config, channel_config)
    if type(match) ~= "table" then return false, "keyword filter is missing" end
    local match_mode = match.mode
    if match_mode ~= nil and match_mode ~= "any" and match_mode ~= "all" then
        return false, "match mode is invalid"
    end
    local content_ok, content_err, content_count = validatePatterns(
        match.content_patterns, "content_patterns")
    if not content_ok then return false, content_err end
    local sender_ok, sender_err, sender_count = validatePatterns(
        match.sender_patterns, "sender_patterns")
    if not sender_ok then return false, sender_err end
    if content_count + sender_count == 0 then return false, "keyword filter has no patterns" end
    return true
end

function util_router.route(message, app_config, bark_enabled)
    app_config = type(app_config) == "table" and app_config or {}
    local result, errors = {}, {}
    local channels = type(app_config.CHANNELS) == "table" and app_config.CHANNELS or {}
    for _, name in ipairs(sortedChannelNames(app_config)) do
        local channel_config = channels[name]
        if type(channel_config) == "table" and channel_config.enabled ~= false then
            local valid, detail = util_router.validatePolicy(name, channel_config, app_config)
            if not valid then
                table.insert(errors, name .. ": " .. tostring(detail))
            elseif channel_config.type ~= "bark" or bark_enabled == true then
                if channel_config.sms_mode == "all" then
                    table.insert(result, name)
                elseif channel_config.sms_mode == "verification" then
                    local matched, match_errors = util_router.matches(message, channel_config, app_config)
                    for _, err in ipairs(match_errors) do table.insert(errors, name .. ": " .. err) end
                    if matched then table.insert(result, name) end
                end
            end
        end
    end
    return result, errors
end

function util_router.systemChannels(app_config, bark_enabled, include_bark)
    app_config = type(app_config) == "table" and app_config or {}
    local result = {}
    local channels = type(app_config.CHANNELS) == "table" and app_config.CHANNELS or {}
    for _, name in ipairs(sortedChannelNames(app_config)) do
        local channel_config = channels[name]
        local valid = type(channel_config) == "table"
            and util_router.validatePolicy(name, channel_config, app_config)
        if type(channel_config) == "table"
            and valid == true
            and channel_config.enabled ~= false
            and channel_config.system_enabled == true
            and (channel_config.type ~= "bark" or (include_bark == true and bark_enabled == true)) then
            table.insert(result, name)
        end
    end
    return result
end

function util_router.callChannels(app_config, bark_enabled)
    app_config = type(app_config) == "table" and app_config or {}
    local result = {}
    local channels = type(app_config.CHANNELS) == "table" and app_config.CHANNELS or {}
    for _, name in ipairs(sortedChannelNames(app_config)) do
        local channel_config = channels[name]
        local valid = type(channel_config) == "table"
            and util_router.validatePolicy(name, channel_config, app_config)
        if type(channel_config) == "table"
            and valid == true
            and channel_config.enabled ~= false
            and channel_config.call_enabled == true
            and (channel_config.type ~= "bark" or bark_enabled == true) then
            table.insert(result, name)
        end
    end
    return result
end

function util_router.sortedChannelNames(app_config)
    return sortedChannelNames(app_config or {})
end

return util_router
