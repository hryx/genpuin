-- test-mod.lua: gen.mod gives the same bits on every Lua flavor
-- It is src/math.zig's mod, Lua 5.4's float % with an exact fmod, in
-- the interpreter and in compiled traces. On Lua 5.4 it must equal %.

local T = require("test.testkit")
local check = T.check
local bits, num, call = testing.bits, testing.num, testing.call
local jit = rawget(_G, "jit")

local function same(a, b)
    return (a ~= a and b ~= b) or bits(a) == bits(b)
end

-- {a, b, gen.mod(a, b)}
local golden = {
    {"401c000000000000", "4010000000000000", "4008000000000000"}, -- 7, 4
    {"c01c000000000000", "4010000000000000", "3ff0000000000000"}, -- -7, 4
    {"401c000000000000", "c010000000000000", "bff0000000000000"}, -- 7, -4
    {"c01c000000000000", "c010000000000000", "c008000000000000"}, -- -7, -4
    {"4004000000000000", "3ff0000000000000", "3fe0000000000000"}, -- 2.5, 1
    {"c004000000000000", "3ff0000000000000", "3fe0000000000000"}, -- -2.5, 1
    {"3ff0000000000000", "3fb999999999999a", "3fb9999999999996"}, -- 1, 0.1
    {"bff0000000000000", "3fb999999999999a", "3c90000000000000"}, -- -1, 0.1
    {"3ff0000000000000", "bfb999999999999a", "bc90000000000000"}, -- 1, -0.1
    {"3fd3333333333333", "3fb999999999999a", "3fb9999999999998"}, -- 0.3, 0.1
    {"401921fb54442d18", "3fb999999999999a", "3fb54ba1ddd812b4"}, -- 2pi, 0.1
    {"c01921fb54442d18", "3ff0000000000000", "3fe6f0255dde9740"}, -- -2pi, 1
    {"4077280000000000", "3ffb333333333333", "3ff99999999999c5"}, -- 370.5, 1.7
    {"c077280000000000", "3ffb333333333333", "3fb99999999996e0"}, -- -370.5, 1.7
    {"3fe6666666666666", "3fc999999999999a", "3fb9999999999994"}, -- 0.7, 0.2
    {"bfe6666666666666", "3fc999999999999a", "3fb99999999999a0"}, -- -0.7, 0.2
    {"40fe240c9fbe76c9", "bf50624dd2f1a9fc", "bf50624dd27767a8"}, -- 123456.789, -0.001
    {"7e37e43c8800759c", "3fb999999999999a", "3f1d66e81bc37800"}, -- 1e300, 0.1
    {"01a56e1fc2f8f359", "3ff0000000000000", "01a56e1fc2f8f359"}, -- 1e-300, 1
    {"81a56e1fc2f8f359", "3ff0000000000000", "3ff0000000000000"}, -- -1e-300, 1
    {"0000000000000001", "3ff0000000000000", "0000000000000001"}, -- min subnormal, 1
    {"8000000000000001", "3ff0000000000000", "3ff0000000000000"}, -- -min subnormal, 1
    {"0000000000000000", "3ff0000000000000", "0000000000000000"}, -- 0, 1
    {"8000000000000000", "3ff0000000000000", "8000000000000000"}, -- -0, 1
    {"c014000000000000", "4014000000000000", "8000000000000000"}, -- -5, 5
    {"4014000000000000", "c014000000000000", "0000000000000000"}, -- 5, -5
    {"3ff0000000000000", "7ff0000000000000", "3ff0000000000000"}, -- 1, inf
    {"bff0000000000000", "7ff0000000000000", "7ff0000000000000"}, -- -1, inf
    {"3ff0000000000000", "fff0000000000000", "fff0000000000000"}, -- 1, -inf
    {"3ff0000000000000", "0000000000000000", "nan"}, -- 1, 0
    {"7ff0000000000000", "3ff0000000000000", "nan"}, -- inf, 1
    {"7ff8000000000000", "3ff0000000000000", "nan"}, -- nan, 1
}

local xs, ys = {}, {}
for i, g in ipairs(golden) do xs[i], ys[i] = num(g[1]), num(g[2]) end
gen.seed(20261117)
for _ = 1, 400 do
    local sign = gen.rand() < 0.5 and -1 or 1
    xs[#xs + 1] = sign * 10 ^ gen.randRange(-3, 12)
    ys[#ys + 1] = (gen.rand() < 0.5 and -1 or 1) * 10 ^ gen.randRange(-3, 3)
end

-- Enough passes over the inputs for LuaJIT to compile the loop.
local function evaluate(f)
    local out = {}
    for _ = 1, 100 do
        for i = 1, #xs do out[i] = f(xs[i], ys[i]) end
    end
    return out
end

local function modCheck(mode)
    local mod = gen.mod
    local out = evaluate(mod)
    local fails = {}
    for i, g in ipairs(golden) do
        local got = out[i] ~= out[i] and "nan" or bits(out[i])
        if got ~= g[3] then
            fails[#fails + 1] = string.format("mod(%s, %s) = %s, expected %s", g[1], g[2], got, g[3])
        end
    end
    check(string.format("%s: %d golden results", mode, #golden), #fails == 0,
        table.concat(fails, "\n    "))
    local bad
    for i = 1, #xs do
        if not same(out[i], call("mod", xs[i], ys[i])) then bad = i break end
    end
    check(string.format("%s: matches src/math.zig on %d inputs", mode, #xs), bad == nil,
        bad and string.format("x=%s y=%s got=%s zig=%s", bits(xs[bad]), bits(ys[bad]),
            bits(out[bad]), bits(call("mod", xs[bad], ys[bad]))))
end

if jit then
    jit.off()
    jit.flush()
    modCheck("interpreter")
    jit.on()
    modCheck("jit")
else
    modCheck(_VERSION)
    local out = evaluate(function(a, b) return a % b end)
    local mod, bad = gen.mod
    for i = 1, #xs do
        if not same(out[i], mod(xs[i], ys[i])) then bad = i break end
    end
    check(string.format("%s: gen.mod equals float %% on %d inputs", _VERSION, #xs), bad == nil,
        bad and string.format("x=%s y=%s %%=%s mod=%s", bits(xs[bad]), bits(ys[bad]),
            bits(out[bad]), bits(mod(xs[bad], ys[bad]))))
    check("gen.mod returns a float for integer operands", math.type(mod(7, 4)) == "float")
end

T.summary()
