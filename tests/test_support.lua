local support = {}

function support.testDir(source)
    source = source or debug.getinfo(2, "S").source
    source = source:sub(1, 1) == "@" and source:sub(2) or source
    source = source:gsub("\\", "/")
    return source:match("^(.*[/])") or "tests/"
end

function support.setupPath(test_dir)
    package.path = test_dir .. "../script/?.lua;" .. test_dir .. "?.lua;" .. (package.path or "")
end

function support.clearModules(names)
    for _, name in ipairs(names or {}) do package.loaded[name] = nil end
end

function support.assertTrue(value, message)
    if not value then error(message or "expected true", 2) end
end

function support.assertFalse(value, message)
    if value then error(message or "expected false", 2) end
end

function support.assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message or "values differ",
            tostring(expected), tostring(actual)), 2)
    end
end

function support.assertContains(value, expected, message)
    support.assertTrue(type(value) == "string" and value:find(expected, 1, true) ~= nil,
        message or ("expected string to contain " .. tostring(expected)))
end

function support.assertNotContains(value, unexpected, message)
    support.assertTrue(type(value) ~= "string" or value:find(unexpected, 1, true) == nil,
        message or ("expected string not to contain " .. tostring(unexpected)))
end

return support
