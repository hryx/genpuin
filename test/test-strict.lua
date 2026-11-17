-- test-strict.lua: strict reads of globals and of the gen table, and gen
-- as the only entry point.

local T = require("test.testkit")

local check = T.check

local function errorOf(fn)
    local ok, err = pcall(fn)
    if ok then return nil end
    return err
end

print("gen global")

check("gen is preinstalled", rawget(_G, "gen") ~= nil)
check("the prelude is not requirable", not pcall(require, "genpuin") and not pcall(require, "genpuin.core"))

print("\nStrict gen")

local err = errorOf(function() return gen.cirlce end)
check("unknown gen key raises", err ~= nil)
check("the error names the key and suggests a fix",
    err and err:find("gen.cirlce does not exist (did you mean gen.circle?)", 1, true), err)
check("the error points at the reading line", err and err:find("test%-strict.lua:21:"), err)
err = errorOf(function() return gen.qqqzzz end)
check("no suggestion when nothing is close", err and not err:find("did you mean", 1, true), err)
check("rawget on gen still yields nil", rawget(gen, "cirlce") == nil)

print("\nStrict globals")

local step = 1
err = errorOf(function() return stpe + step end)
check("undefined global raises", err ~= nil)
check("the error names the variable", err and err:find("undefined global 'stpe'", 1, true), err)
check("the error suggests a visible name", err and err:find("did you mean 'step'", 1, true), err)
check("the error mentions rawget", err and err:find('rawget(_G, "stpe")', 1, true), err)
check("rawget tests for a global", rawget(_G, "stpe") == nil)

assignedLater = nil
check("a global assigned nil reads nil", assignedLater == nil)
newGlobal = 3
check("a new global reads back", newGlobal == 3)
function globalFn() return 7 end
check("a global function can be called", globalFn() == 7)

T.summary()
