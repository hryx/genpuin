-- test-seed.lua: --seed and --noise-seed (testing.render's seed and
-- noiseSeed) render exactly what a script edited to call gen.seed(n) or
-- gen.noiseSeed(n) renders, and leave seeds given in calls alone.

local T = require("test.testkit")
local check = T.check

local function write(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
end

local function read(path)
    local f = assert(io.open(path, "rb"))
    local bytes = f:read("*a")
    f:close()
    return bytes
end

-- Render source as out/test/seed-<name>.lua and return the PPM bytes.
local function render(name, source, opts)
    local script = "out/test/seed-" .. name .. ".lua"
    local out = "out/test/seed-" .. name .. ".ppm"
    write(script, source)
    testing.render(script, out, opts)
    return read(out)
end

local dots = [[
for _ = 1, 25 do
    gen.draw(gen.circle({gen.randRange(0, 40), gen.randRange(0, 30)}, gen.randRange(1, 5)), {fill = {gen.rand(), 0.3, 0.6}})
end
]]

local canvas = "gen.canvas(40, 30)\ngen.background({1, 1, 1})\n"

local streams = {
    once = canvas .. "gen.seed(3)\n" .. dots,
    twice = canvas .. "gen.seed(3)\n" .. dots .. "gen.seed(11)\n" .. dots,
    never = canvas .. dots,
}

print("--seed n acts as gen.seed(n)")

for name, source in pairs(streams) do
    local forced = render("forced-" .. name, source, {seed = 9})
    local edited = source:gsub("gen%.seed%(%d+%)", "gen.seed(9)")
    if name == "never" then edited = canvas .. "gen.seed(9)\n" .. dots end
    check(name .. ": same bytes as the edited script", forced == render("edited-" .. name, edited))
    check(name .. ": differs from the plain script", forced ~= render("plain-" .. name, source))
end

local fog = [[
local grid = gen.noiseGrid(40, 30, {scale = 0.1})
gen.draw(gen.image(grid, 0, 0, 40, 30))
for i = 0, 39 do
    local y = 15 + 8 * gen.simplex(i * 0.1, 0.5) + 4 * gen.perlin(i * 0.2, 0.3)
    gen.draw(gen.circle({i, y}, 1.5), {fill = {0.8, 0.1, 0.1}})
end
]]

local noises = {
    once = canvas .. "gen.noiseSeed(3)\n" .. fog,
    twice = canvas .. "gen.noiseSeed(3)\n" .. fog .. "gen.noiseSeed(11)\n" .. fog,
    never = canvas .. fog,
}

print("\n--noise-seed n acts as gen.noiseSeed(n)")

for name, source in pairs(noises) do
    local forced = render("nforced-" .. name, source, {noiseSeed = 9})
    local edited = source:gsub("gen%.noiseSeed%(%d+%)", "gen.noiseSeed(9)")
    if name == "never" then edited = canvas .. "gen.noiseSeed(9)\n" .. fog end
    check(name .. ": same bytes as the edited script", forced == render("nedited-" .. name, edited))
    check(name .. ": differs from the plain script", forced ~= render("nplain-" .. name, source))
end

check("--seed alone leaves noise as it was",
    render("noise-seed-only", canvas .. fog, {seed = 9}) == render("noise-plain", canvas .. fog))
check("--noise-seed alone leaves the random stream as it was",
    render("stream-noise-only", canvas .. dots, {noiseSeed = 9}) == render("stream-plain", canvas .. dots))

print("\nSeeds given in calls are used as written")

local function sim(seedOpt)
    return [[
gen.canvas(32, 32)
local b = gen.reactionDiffusion{w = 32, h = 32, preset = "mitosis", steps = 60, seeds = 6]] .. seedOpt .. [[}
gen.draw(gen.image(b, 0, 0, 32, 32))
]]
end

local function grain(seedOpt)
    return [[
gen.canvas(32, 32)
gen.background({0.5, 0.5, 0.5})
gen.post.grain{amount = 0.3]] .. seedOpt .. [[}
]]
end

local function grid(seedOpt)
    return [[
gen.canvas(32, 32)
gen.draw(gen.image(gen.noiseGrid(32, 32, {scale = 0.2]] .. seedOpt .. [[}), 0, 0, 32, 32))
]]
end

local explicit = {
    {"simulation", sim, "seed"},
    {"post pass", grain, "seed"},
    {"noiseGrid", grid, "noiseSeed"},
}

for _, e in ipairs(explicit) do
    local label, make, flag = e[1], e[2], e[3]
    local key = label:gsub(" ", "-")
    check(label .. ": seed = 5 ignores the flag",
        render(key .. "-5", make(", seed = 5")) == render(key .. "-5-forced", make(", seed = 5"), {[flag] = 9}))
    check(label .. ": no seed follows the flag",
        render(key .. "-none", make("")) ~= render(key .. "-none-forced", make(""), {[flag] = 9}))
end

print("\nBad values are refused")

local ok, err = pcall(testing.render, "out/test/seed-plain-never.lua", "out/test/seed-bad.ppm", {seed = -1})
check("a negative seed is an error", not ok and err:find("option 'seed' must be an integer", 1, true), err)
ok, err = pcall(testing.render, "out/test/seed-plain-never.lua", "out/test/seed-bad.ppm", {noiseSeed = 2 ^ 32})
check("2^32 is an error", not ok and err:find("option 'noiseSeed' must be an integer", 1, true), err)

T.summary()
