local util_history = {}

local HISTORY_DIR = "/history"
local HISTORY_FILE = HISTORY_DIR .. "/events-v2.ndjson"
local HISTORY_NEW_FILE = HISTORY_DIR .. "/events-v2.new"
local HISTORY_BACKUP_FILE = HISTORY_DIR .. "/events-v2.bak"

local SMS_CONTENT_LIMIT = 512
local NUMBER_LIMIT = 32
local RECEIVED_AT_LIMIT = 32
local DIRECTION_LIMIT = 16
local CALL_STATE_LIMIT = 48
local MAX_RECORDS = 500
local HISTORY_BUDGET = 256 * 1024
local PAGE_LIMIT = 100

local state = {
    sequence = 0,
    records = {},
    records_count = 0,
    sms_count = 0,
    call_count = 0,
    bytes = 0,
    corrupt_records = 0,
    last_compact = "never",
}

local function pathExists(path)
    local ok, exists = pcall(io.exists, path)
    return ok and exists == true
end

local function directoryExists(path)
    local ok, exists = pcall(io.dexist, path)
    return ok and exists == true
end

local function ensureHistoryDir()
    if directoryExists(HISTORY_DIR) then return true end
    local ok, created = pcall(io.mkdir, HISTORY_DIR)
    if ok and created == true then return true end
    return directoryExists(HISTORY_DIR)
end

local function removePath(path)
    if not pathExists(path) then return true end
    local ok = pcall(os.remove, path)
    return ok and not pathExists(path)
end

local function renamePath(from_path, to_path)
    if not pathExists(from_path) then return false end
    local ok = pcall(os.rename, from_path, to_path)
    return ok and not pathExists(from_path) and pathExists(to_path)
end

local function readFile(path)
    local open_ok, file = pcall(io.open, path, "rb")
    if not open_ok or not file then return nil end

    local read_ok, data = pcall(function()
        return file:read("*a")
    end)
    local close_ok = pcall(function()
        file:close()
    end)
    if not read_ok or not close_ok then return nil end
    return type(data) == "string" and data or ""
end

local function fileEndsWithNewline(path)
    local size_ok, size = pcall(io.fileSize, path)
    if not size_ok or type(size) ~= "number" or size <= 0 then return true end

    local open_ok, file = pcall(io.open, path, "rb")
    if not open_ok or not file then return false end
    local seek_ok = pcall(function()
        return file:seek("end", -1)
    end)
    local read_ok, last = pcall(function()
        return file:read(1)
    end)
    local close_ok = pcall(function()
        file:close()
    end)
    return seek_ok and read_ok and close_ok and last == "\n"
end

local function utf8Width(text, position)
    local first = string.byte(text, position)
    if not first then return nil end
    if first < 0x80 then return 1 end
    if first >= 0xC2 and first <= 0xDF then return 2 end
    if first >= 0xE0 and first <= 0xEF then return 3 end
    if first >= 0xF0 and first <= 0xF4 then return 4 end
    return nil
end

local function truncateUtf8(value, limit)
    value = tostring(value or "")
    limit = math.max(0, math.floor(tonumber(limit) or 0))
    if #value <= limit then return value end

    local position, last = 1, 0
    while position <= #value do
        local width = utf8Width(value, position)
        if not width or position + width - 1 > limit then break end
        local valid = true
        for offset = 1, width - 1 do
            local byte = string.byte(value, position + offset)
            if not byte or byte < 0x80 or byte > 0xBF then
                valid = false
                break
            end
        end
        if not valid then break end
        last = position + width - 1
        position = last + 1
    end
    return value:sub(1, last)
end

local function text(value, limit)
    return truncateUtf8(value, limit)
end

local function normalizeRecord(kind, value)
    if type(value) ~= "table" or value.kind ~= kind then return nil end
    local sequence = tonumber(value.sequence)
    if not sequence or sequence <= 0 then return nil end
    sequence = math.floor(sequence)

    if kind == "sms" then
        return {
            kind = "sms",
            sequence = sequence,
            sender = text(value.sender, NUMBER_LIMIT),
            content = text(value.content, SMS_CONTENT_LIMIT),
            received_at = text(value.received_at, RECEIVED_AT_LIMIT),
            direction = text(value.direction or "incoming", DIRECTION_LIMIT),
        }
    end
    return {
        kind = "call",
        sequence = sequence,
        number = text(value.number, NUMBER_LIMIT),
        call_state = text(value.call_state, CALL_STATE_LIMIT),
        received_at = text(value.received_at, RECEIVED_AT_LIMIT),
    }
end

local function encodeRecord(record)
    local ok, encoded = pcall(json.encode, record)
    if not ok or type(encoded) ~= "string" then return nil end
    return encoded
end

local function parseFileData(data)
    local records, corrupt, max_sequence = {}, 0, 0
    local position = 1
    while position <= #data do
        local newline = data:find("\n", position, true)
        local line
        if newline then
            line = data:sub(position, newline - 1)
            position = newline + 1
        else
            line = data:sub(position)
            position = #data + 1
        end
        if line:sub(-1) == "\r" then line = line:sub(1, -2) end
        if line ~= "" then
            local ok, value = pcall(json.decode, line)
            local record = nil
            if ok and type(value) == "table" then record = normalizeRecord(value.kind, value) end
            if record then
                table.insert(records, record)
                if record.sequence > max_sequence then max_sequence = record.sequence end
            else
                corrupt = corrupt + 1
            end
        end
    end
    table.sort(records, function(a, b) return a.sequence < b.sequence end)
    return records, corrupt, max_sequence
end

local function scanFile(path, priority)
    if not pathExists(path) then return nil end
    local data = readFile(path)
    if data == nil then
        return { path = path, priority = priority, valid = false }
    end
    local records, corrupt, max_sequence = parseFileData(data)
    return {
        path = path,
        priority = priority,
        valid = true,
        usable = #records > 0 or #data == 0,
        records = records,
        bytes = #data,
        corrupt_records = corrupt,
        max_sequence = max_sequence,
    }
end

local function isBetterCandidate(candidate, current)
    if not current then return true end
    if candidate.max_sequence ~= current.max_sequence then
        return candidate.max_sequence > current.max_sequence
    end
    if #candidate.records ~= #current.records then
        return #candidate.records > #current.records
    end
    if candidate.bytes ~= current.bytes then
        return candidate.bytes > current.bytes
    end
    return candidate.priority > current.priority
end

local function bestCandidate()
    local selected
    for _, item in ipairs({
        scanFile(HISTORY_FILE, 3),
        scanFile(HISTORY_NEW_FILE, 2),
        scanFile(HISTORY_BACKUP_FILE, 1),
    }) do
        if item and item.valid and item.usable and isBetterCandidate(item, selected) then selected = item end
    end
    return selected
end

local function installCandidate(candidate)
    if not candidate then return false end
    if candidate.path == HISTORY_FILE then
        removePath(HISTORY_NEW_FILE)
        removePath(HISTORY_BACKUP_FILE)
        return true
    end

    if candidate.path == HISTORY_BACKUP_FILE then
        if not removePath(HISTORY_NEW_FILE) then return false end
        if not renamePath(HISTORY_BACKUP_FILE, HISTORY_NEW_FILE) then return false end
    end

    if not removePath(HISTORY_BACKUP_FILE) then return false end
    if pathExists(HISTORY_FILE) and not renamePath(HISTORY_FILE, HISTORY_BACKUP_FILE) then return false end
    if not renamePath(HISTORY_NEW_FILE, HISTORY_FILE) then
        if not pathExists(HISTORY_FILE) and pathExists(HISTORY_BACKUP_FILE) then
            renamePath(HISTORY_BACKUP_FILE, HISTORY_FILE)
        end
        return false
    end
    removePath(HISTORY_BACKUP_FILE)
    return true
end

local function updateState(scanned)
    state.records = scanned and scanned.records or {}
    state.records_count = #state.records
    state.sms_count, state.call_count = 0, 0
    for _, record in ipairs(state.records) do
        if record.kind == "sms" then state.sms_count = state.sms_count + 1 end
        if record.kind == "call" then state.call_count = state.call_count + 1 end
    end
    state.sequence = scanned and scanned.max_sequence or 0
    state.bytes = scanned and scanned.bytes or 0
    state.corrupt_records = scanned and scanned.corrupt_records or 0
end

local function recoverHistoryFile()
    local formal_was_present = pathExists(HISTORY_FILE)
    local candidate = bestCandidate()
    if candidate and candidate.path ~= HISTORY_FILE then
        if not installCandidate(candidate) then
            log.error("history", "recovery_install_failed")
            return formal_was_present, false
        end
        state.last_compact = os.date("%Y-%m-%d %H:%M:%S")
    elseif candidate then
        installCandidate(candidate)
    end

    local active = scanFile(HISTORY_FILE, 3)
    if active and active.valid then
        updateState(active)
    else
        updateState(nil)
    end
    return formal_was_present, candidate ~= nil
end

local function appendLine(encoded)
    if not ensureHistoryDir() then return false end
    local open_ok, file = pcall(io.open, HISTORY_FILE, "ab")
    if not open_ok or not file then return false end

    local prefix = fileEndsWithNewline(HISTORY_FILE) and "" or "\n"
    local write_ok, write_result = pcall(function()
        return file:write(prefix .. encoded .. "\n")
    end)
    local close_ok = pcall(function()
        file:close()
    end)
    return write_ok and close_ok and write_result ~= false, #prefix + #encoded + 1
end

local function encodeRecords(records)
    local entries, total = {}, 0
    for _, record in ipairs(records) do
        local encoded = encodeRecord(record)
        if not encoded then return nil end
        local entry = { record = record, encoded = encoded, bytes = #encoded + 1 }
        table.insert(entries, entry)
        total = total + entry.bytes
    end
    return entries, total
end

local function trimRecords(records)
    local entries, total = encodeRecords(records)
    if not entries then return nil end
    local first = 1
    while first <= #entries and (total > HISTORY_BUDGET or #entries - first + 1 > MAX_RECORDS) do
        total = total - entries[first].bytes
        first = first + 1
    end

    local kept = {}
    for index = first, #entries do table.insert(kept, entries[index].record) end
    return kept
end

local function writeRecordSet(path, records)
    if not ensureHistoryDir() then return false end
    local entries = encodeRecords(records)
    if not entries then return false end

    local open_ok, file = pcall(io.open, path, "wb")
    if not open_ok or not file then return false end
    local write_ok = true
    for _, entry in ipairs(entries) do
        local ok, result = pcall(function()
            return file:write(entry.encoded .. "\n")
        end)
        if not ok or result == false then
            write_ok = false
            break
        end
    end
    local close_ok = pcall(function()
        file:close()
    end)
    return write_ok and close_ok
end

local function sameRecord(left, right)
    if not left or not right or left.kind ~= right.kind or left.sequence ~= right.sequence then return false end
    if left.kind == "sms" then
        return left.sender == right.sender and left.content == right.content
            and left.received_at == right.received_at and left.direction == right.direction
    end
    return left.number == right.number and left.call_state == right.call_state
        and left.received_at == right.received_at
end

local function validateFile(path, expected_records)
    local scanned = scanFile(path, 2)
    if not scanned or not scanned.valid or not scanned.usable or scanned.corrupt_records ~= 0 then return nil end
    if #scanned.records ~= #expected_records then return nil end
    for index, record in ipairs(expected_records) do
        if not sameRecord(record, scanned.records[index]) then return nil end
    end
    return scanned
end

local function compact()
    local active = scanFile(HISTORY_FILE, 3)
    if not active or not active.valid then return false end
    local kept = trimRecords(active.records)
    if not kept then return false end

    if not writeRecordSet(HISTORY_NEW_FILE, kept) then
        log.error("history", "compact_write_failed")
        return false
    end
    local written = validateFile(HISTORY_NEW_FILE, kept)
    if not written then
        log.error("history", "compact_validate_failed")
        return false
    end

    if not removePath(HISTORY_BACKUP_FILE) then return false end
    if not renamePath(HISTORY_FILE, HISTORY_BACKUP_FILE) then return false end
    if not renamePath(HISTORY_NEW_FILE, HISTORY_FILE) then
        if not pathExists(HISTORY_FILE) and pathExists(HISTORY_BACKUP_FILE) then
            renamePath(HISTORY_BACKUP_FILE, HISTORY_FILE)
        end
        return false
    end

    local final = scanFile(HISTORY_FILE, 3)
    if not final or not final.valid or final.corrupt_records ~= 0 then
        removePath(HISTORY_FILE)
        if pathExists(HISTORY_BACKUP_FILE) then renamePath(HISTORY_BACKUP_FILE, HISTORY_FILE) end
        return false
    end
    updateState(final)
    state.last_compact = os.date("%Y-%m-%d %H:%M:%S")
    return removePath(HISTORY_BACKUP_FILE)
end

local function add(kind, value)
    local sequence = state.sequence + 1
    value.kind, value.sequence = kind, sequence
    local encoded = encodeRecord(value)
    if not encoded then
        log.error("history", "record_encode_failed", kind)
        return false
    end
    local appended, added_bytes = appendLine(encoded)
    if not appended then
        log.error("history", "record_append_failed", kind)
        return false
    end

    state.sequence = sequence
    table.insert(state.records, value)
    table.sort(state.records, function(a, b) return a.sequence < b.sequence end)
    state.records_count = state.records_count + 1
    if kind == "sms" then state.sms_count = state.sms_count + 1 end
    if kind == "call" then state.call_count = state.call_count + 1 end
    state.bytes = state.bytes + added_bytes
    if state.records_count > MAX_RECORDS or state.bytes > HISTORY_BUDGET then
        if not compact() then log.error("history", "compact_failed") end
    end
    return true
end

local function pageRecords(kind, limit, before)
    limit = math.floor(tonumber(limit) or PAGE_LIMIT)
    if limit < 1 then limit = 1 end
    local max_page_limit = kind == "sms" and MAX_RECORDS or PAGE_LIMIT
    if limit > max_page_limit then limit = max_page_limit end
    before = tonumber(before)
    if before then before = math.floor(before) end

    local result = {}
    for index = #state.records, 1, -1 do
        local record = state.records[index]
        if record.kind == kind and (not before or record.sequence < before) then
            local copy = {}
            for key, value in pairs(record) do copy[key] = value end
            table.insert(result, copy)
            if #result >= limit then break end
        end
    end
    return result
end

function util_history.addSms(sender, content, received_at, direction)
    return add("sms", {
        sender = text(sender, NUMBER_LIMIT),
        content = text(content, SMS_CONTENT_LIMIT),
        received_at = text(received_at, RECEIVED_AT_LIMIT),
        direction = text(direction or "incoming", DIRECTION_LIMIT),
    })
end

function util_history.addCall(number, call_state, received_at)
    return add("call", {
        number = text(number, NUMBER_LIMIT),
        call_state = text(call_state, CALL_STATE_LIMIT),
        received_at = text(received_at, RECEIVED_AT_LIMIT),
    })
end

function util_history.getSms(limit, before)
    return pageRecords("sms", limit, before)
end

function util_history.getCalls(limit, before)
    return pageRecords("call", limit, before)
end

function util_history.getAll()
    return {
        sms = util_history.getSms(PAGE_LIMIT),
        calls = util_history.getCalls(PAGE_LIMIT),
        limits = {
            sms = PAGE_LIMIT,
            calls = PAGE_LIMIT,
            records = MAX_RECORDS,
            bytes = HISTORY_BUDGET,
            sms_content_bytes = SMS_CONTENT_LIMIT,
        },
    }
end

function util_history.getStats()
    return {
        storage = "lfs",
        records = state.records_count,
        sms_count = state.sms_count,
        call_count = state.call_count,
        bytes = state.bytes,
        budget = HISTORY_BUDGET,
        corrupt_records = state.corrupt_records,
        last_compact = state.last_compact,
    }
end

if not ensureHistoryDir() then log.error("history", "directory_init_failed") end
recoverHistoryFile()

return util_history
