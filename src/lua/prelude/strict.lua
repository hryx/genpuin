-- Strict reads. Reading a global that was never assigned, or a name the
-- gen table does not have, raises an error at the reading line instead of
-- yielding nil. The checks sit in __index, which only runs on a miss, so
-- reads of names that exist cost nothing extra.

local import = ...
local closest = import("core").closest

local M = {}

-- Names a misspelled global might have meant: globals, and the locals and
-- upvalues of the function doing the read, which sits at level 3 from here.
local function candidates(globals, declared)
    local names = {}
    for k in pairs(globals) do names[k] = true end
    for k in pairs(declared) do names[k] = true end
    local i = 1
    while true do
        local name = debug.getlocal(3, i)
        if not name then break end
        names[name] = true
        i = i + 1
    end
    local fn = debug.getinfo(3, "f").func
    i = 1
    while true do
        local name = debug.getupvalue(fn, i)
        if not name then break end
        names[name] = true
        i = i + 1
    end
    return names
end

-- Make reads of never assigned globals an error. Assigning a global
-- declares it, so it keeps reading as nil after being set to nil.
function M.globals()
    local declared = {}
    setmetatable(_G, {
        __newindex = function(t, k, v)
            declared[k] = true
            rawset(t, k, v)
        end,
        __index = function(t, k)
            if declared[k] then return nil end
            local name = tostring(k)
            local near = closest(name, candidates(t, declared))
            error(string.format("undefined global '%s'%s. Assign it first, or test for it with rawget(_G, \"%s\")",
                name, near and string.format(" (did you mean '%s'?)", near) or "", name), 2)
        end,
    })
end

-- Make reads of missing keys on t an error naming them as prefix.key.
-- Returns t.
function M.api(t, prefix)
    return setmetatable(t, {
        __index = function(_, k)
            local name = tostring(k)
            local near = closest(name, t)
            error(string.format("%s.%s does not exist%s", prefix, name,
                near and string.format(" (did you mean %s.%s?)", prefix, near) or ""), 2)
        end,
    })
end

-- Raise an error at the line that called the function `what` when opts
-- holds a key that is not in known, a set of option names. opts must be
-- nil or a table.
function M.options(what, opts, known)
    if opts == nil then return end
    if type(opts) ~= "table" then error(what .. ": options must be a table", 3) end
    for k in pairs(opts) do
        if not known[k] then
            local name = tostring(k)
            local near = type(k) == "string" and closest(name, known) or nil
            error(string.format("%s: unknown option '%s'%s", what, name,
                near and string.format(" (did you mean '%s'?)", near) or ""), 3)
        end
    end
end

return M
