local support = {}

local function jsonEncodeString(value)
    value = tostring(value)
    value = value:gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\r", "\\r")
        :gsub("\n", "\\n")
        :gsub("\t", "\\t")
    return '"' .. value .. '"'
end

local function jsonEncode(value)
    local value_type = type(value)
    if value_type == "nil" then return "null" end
    if value_type == "string" then return jsonEncodeString(value) end
    if value_type == "number" or value_type == "boolean" then return tostring(value) end
    if value_type ~= "table" then error("unsupported JSON value: " .. value_type) end

    local is_array, maximum, count = true, 0, 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            is_array = false
            break
        end
        maximum = math.max(maximum, key)
        count = count + 1
    end
    if is_array and maximum == count then
        local parts = {}
        for index = 1, maximum do table.insert(parts, jsonEncode(value[index])) end
        return "[" .. table.concat(parts, ",") .. "]"
    end

    local keys = {}
    for key in pairs(value) do table.insert(keys, tostring(key)) end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        table.insert(parts, jsonEncodeString(key) .. ":" .. jsonEncode(value[key]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function jsonDecode(text)
    local position = 1

    local function skipWhitespace()
        while text:sub(position, position):match("%s") do position = position + 1 end
    end

    local function parseString()
        if text:sub(position, position) ~= '"' then error("JSON string expected") end
        position = position + 1
        local result = {}
        while position <= #text do
            local character = text:sub(position, position)
            position = position + 1
            if character == '"' then return table.concat(result) end
            if character ~= "\\" then
                table.insert(result, character)
            else
                local escaped = text:sub(position, position)
                position = position + 1
                local replacements = { ["\\"] = "\\", ['"'] = '"', ["/"] = "/", n = "\n", r = "\r", t = "\t" }
                if replacements[escaped] then
                    table.insert(result, replacements[escaped])
                elseif escaped == "b" then
                    table.insert(result, "\b")
                elseif escaped == "f" then
                    table.insert(result, "\f")
                elseif escaped == "u" then
                    local hex = text:sub(position, position + 3)
                    if not hex:match("^%x%x%x%x$") then error("invalid JSON unicode escape") end
                    local codepoint = tonumber(hex, 16)
                    position = position + 4
                    if codepoint < 0x80 then
                        table.insert(result, string.char(codepoint))
                    elseif codepoint < 0x800 then
                        table.insert(result, string.char(0xC0 + math.floor(codepoint / 0x40), 0x80 + codepoint % 0x40))
                    else
                        table.insert(result, string.char(
                            0xE0 + math.floor(codepoint / 0x1000),
                            0x80 + math.floor(codepoint / 0x40) % 0x40,
                            0x80 + codepoint % 0x40))
                    end
                else
                    error("invalid JSON escape")
                end
            end
        end
        error("unterminated JSON string")
    end

    local parseValue
    local function parseArray()
        if text:sub(position, position) ~= "[" then error("JSON array expected") end
        position = position + 1
        local result = {}
        skipWhitespace()
        if text:sub(position, position) == "]" then position = position + 1 return result end
        while true do
            table.insert(result, parseValue())
            skipWhitespace()
            local delimiter = text:sub(position, position)
            position = position + 1
            if delimiter == "]" then return result end
            if delimiter ~= "," then error("JSON array delimiter expected") end
        end
    end

    local function parseObject()
        if text:sub(position, position) ~= "{" then error("JSON object expected") end
        position = position + 1
        local result = {}
        skipWhitespace()
        if text:sub(position, position) == "}" then position = position + 1 return result end
        while true do
            skipWhitespace()
            local key = parseString()
            skipWhitespace()
            if text:sub(position, position) ~= ":" then error("JSON colon expected") end
            position = position + 1
            result[key] = parseValue()
            skipWhitespace()
            local delimiter = text:sub(position, position)
            position = position + 1
            if delimiter == "}" then return result end
            if delimiter ~= "," then error("JSON object delimiter expected") end
        end
    end

    local function parseNumber()
        local start = position
        while text:sub(position, position):match("[%d%+%-%e%E%.]") do position = position + 1 end
        local number = tonumber(text:sub(start, position - 1))
        if number == nil then error("invalid JSON number") end
        return number
    end

    parseValue = function()
        skipWhitespace()
        local character = text:sub(position, position)
        if character == '"' then return parseString() end
        if character == "{" then return parseObject() end
        if character == "[" then return parseArray() end
        if text:sub(position, position + 3) == "true" then position = position + 4 return true end
        if text:sub(position, position + 4) == "false" then position = position + 5 return false end
        if text:sub(position, position + 3) == "null" then position = position + 4 return nil end
        return parseNumber()
    end

    local result = parseValue()
    skipWhitespace()
    if position <= #text then error("trailing JSON data") end
    return result
end

local native_os = os

function support.encode(value)
    return jsonEncode(value)
end

function support.line(value)
    return jsonEncode(value) .. "\n"
end

function support.load(options)
    options = options or {}
    local files = {}
    for path, value in pairs(options.files or {}) do files[path] = value end
    local store = {}
    for key, value in pairs(options.legacy or {}) do
        store[key] = type(value) == "string" and value or jsonEncode(value)
    end
    local directories = { ["/"] = true }
    local opened, closed = 0, 0
    local fail_write_path = options.fail_write_path
    local fail_remove_path = options.fail_remove_path
    local fail_rename_from = options.fail_rename_from
    local fail_rename_to = options.fail_rename_to

    local function open(path, mode)
        if mode == "rb" and files[path] == nil then return nil, "missing file" end
        if mode == "wb" then files[path] = "" end
        if mode == "ab" and files[path] == nil then files[path] = "" end
        if files[path] == nil then return nil, "unsupported mode" end

        opened = opened + 1
        local handle = { path = path, mode = mode, position = mode == "ab" and #files[path] + 1 or 1, is_closed = false }
        function handle:read(length)
            if self.is_closed then error("read after close") end
            if length == "*a" then
                local result = files[self.path]:sub(self.position)
                self.position = #files[self.path] + 1
                return result
            end
            local result = files[self.path]:sub(self.position, self.position + length - 1)
            self.position = self.position + #result
            return result
        end
        function handle:seek(whence, offset)
            if self.is_closed then error("seek after close") end
            offset = offset or 0
            if whence == "end" then
                self.position = #files[self.path] + 1 + offset
            elseif whence == "set" then
                self.position = offset + 1
            else
                self.position = self.position + offset
            end
            return self.position - 1
        end
        function handle:write(value)
            if self.is_closed then error("write after close") end
            if self.mode == "rb" then error("write on read-only handle") end
            if fail_write_path == self.path then return false end
            local data = files[self.path]
            files[self.path] = data:sub(1, self.position - 1) .. tostring(value) .. data:sub(self.position)
            self.position = self.position + #tostring(value)
            return true
        end
        function handle:close()
            if not self.is_closed then
                self.is_closed = true
                closed = closed + 1
            end
            return true
        end
        return handle
    end

    local io_mock = {
        open = open,
        exists = function(path) return files[path] ~= nil end,
        fileSize = function(path) return files[path] and #files[path] or nil end,
        dexist = function(path) return directories[path] == true end,
        mkdir = function(path) directories[path] = true return true end,
    }
    local os_mock = {
        date = native_os.date,
        remove = function(path)
            if fail_remove_path == path then return false end
            files[path] = nil
            return true
        end,
        rename = function(from_path, to_path)
            if fail_rename_from == from_path or fail_rename_to == to_path then return false end
            if files[from_path] == nil then return false end
            files[to_path] = files[from_path]
            files[from_path] = nil
            return true
        end,
    }

    _G.io, _G.os, _G.fskv, _G.json = io_mock, os_mock, {
        get = function(key) return store[key] end,
        del = function(key) store[key] = nil return true end,
        set = function(key, value) store[key] = value return true end,
    }, {
        encode = jsonEncode,
        decode = jsonDecode,
    }
    _G.log = { info = function() end, warn = function() end, error = function() end }

    package.loaded.util_history = nil
    local history = require "util_history"
    return {
        files = files,
        store = store,
        opened = function() return opened end,
        closed = function() return closed end,
        history = history,
    }, history
end

return support
