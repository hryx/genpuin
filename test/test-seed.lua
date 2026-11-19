-- test-seed.lua: --seed and --noise-seed (testing.render's seed and
-- noiseSeed) render exactly what a script edited to call gen.seed(n) or
-- gen.noiseSeed(n) renders, and leave seeds given in calls alone. Scripts
-- run through testing.render get the seeding rules of a normal render.

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
    mixed = canvas .. "gen.seed(3)\n" .. dots .. "gen.mixSeed(11)\n" .. dots,
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
check("a script that never seeds renders as gen.seed(0)",
    render("never-zero", canvas .. dots) == render("seed-zero", canvas .. "gen.seed(0)\n" .. dots))
check("a script that never noise seeds renders as gen.noiseSeed(0)",
    render("never-nzero", canvas .. fog) == render("nseed-zero", canvas .. "gen.noiseSeed(0)\n" .. fog))

print("\ngen.mixSeed makes streams from one seed")

local plates = canvas .. [[
gen.seed(3)
for i = 1, 9 do
    gen.mixSeed(i)
    local x, y = (i - 1) % 3 * 13 + 1, math.floor((i - 1) / 3) * 10 + 1
    for _ = 1, 4 do
        gen.draw(gen.rect(x + gen.randRange(0, 8), y + gen.randRange(0, 6), 3, 3), {fill = {gen.rand(), 0.4, 0.7}})
    end
end
]]
check("--seed changes every plate's stream", render("plates", plates) ~= render("plates-forced", plates, {seed = 9}))
check("--seed acts on the base under gen.mixSeed",
    render("plates-forced", plates, {seed = 9}) == render("plates-edited", (plates:gsub("gen%.seed%(3%)", "gen.seed(9)"))))

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

-- The error of rendering source, or nil.
local function failure(name, source, opts)
    local script = "out/test/seed-" .. name .. ".lua"
    write(script, source)
    local ok, e = pcall(testing.render, script, "out/test/seed-" .. name .. ".ppm", opts)
    if ok then return nil end
    return e
end

-- Each case is an argument, called on line 3, and the message after the
-- function name.
local values = {
    {"-1", "(-1): a seed must be a whole number from 0 to 4294967295"},
    {"1.5", "(1.5): a seed must be a whole number from 0 to 4294967295"},
    {"2 ^ 32", "(4294967296): a seed must be a whole number from 0 to 4294967295"},
    {"0 / 0", "(nan): a seed must be a whole number from 0 to 4294967295"},
    {"math.huge", "(inf): a seed must be a whole number from 0 to 4294967295"},
    {"'5'", " needs a whole number from 0 to 4294967295, got string"},
    {"", " needs a whole number from 0 to 4294967295, got no value"},
}
for _, fn in ipairs({"seed", "mixSeed", "noiseSeed"}) do
    for i, v in ipairs(values) do
        local e = failure("value-" .. fn .. i, canvas .. "gen." .. fn .. "(" .. v[1] .. ")\n")
        local want = "seed-value-" .. fn .. i .. ".lua:3: gen." .. fn .. v[2]
        check("gen." .. fn .. "(" .. v[1] .. ") is refused at its line", e and e:find(want, 1, true), e)
    end
end
check("4294967295 is a seed", failure("max", canvas .. "gen.seed(4294967295)\ngen.mixSeed(4294967295)\ngen.noiseSeed(4294967295)\n") == nil)

print("\nSeeds are set once, before use")

local advice = ". It may only be called once, before any random draws. Use gen.mixSeed(k) for more streams"
local rules = {
    {"twice", "gen.seed(1)\ngen.seed(2)\n", "gen.seed called twice" .. advice},
    {"after a draw", "local _ = gen.rand()\ngen.seed(2)\n", "gen.seed called after the random stream was used" .. advice},
    {"after a pick", "local _ = gen.pick({1, 2})\ngen.seed(2)\n", "gen.seed called after the random stream was used" .. advice},
    {"after mixSeed", "gen.mixSeed(1)\ngen.seed(2)\n", "gen.seed called after the random stream was used" .. advice},
    {"after a default seed", "gen.post.grain{amount = 0.1}\ngen.seed(2)\n", "gen.seed called after the random stream was used" .. advice},
}
for _, opts in ipairs({{}, {seed = 9}}) do
    local tag = opts.seed and " under --seed" or ""
    for i, r in ipairs(rules) do
        local e = failure("rule" .. i .. (opts.seed or ""), canvas .. r[2], opts)
        local want = "seed-rule" .. i .. (opts.seed or "") .. ".lua:4: " .. r[3]
        check("gen.seed " .. r[1] .. tag .. " is an error at its line", e and e:find(want, 1, true), e)
    end
end
check("drawing without randomness leaves gen.seed open",
    failure("shapes-first", canvas .. "gen.draw(gen.circle({5, 5}, 3))\ngen.seed(2)\n") == nil)

local nadvice = ". It may only be called once, before any noise function"
local nrules = {
    {"twice", "gen.noiseSeed(1)\ngen.noiseSeed(2)\n", "gen.noiseSeed called twice" .. nadvice},
    {"after perlin", "local _ = gen.perlin(0.5, 0.5)\ngen.noiseSeed(2)\n", "gen.noiseSeed called after noise was used" .. nadvice},
    {"after fbm", "local _ = gen.fbm(0.5, 0.5)\ngen.noiseSeed(2)\n", "gen.noiseSeed called after noise was used" .. nadvice},
    {"after simplex", "local _ = gen.simplex(0.5, 0.5)\ngen.noiseSeed(2)\n", "gen.noiseSeed called after noise was used" .. nadvice},
    {"after noiseGrid", "local _ = gen.noiseGrid(4, 4)\ngen.noiseSeed(2)\n", "gen.noiseSeed called after noise was used" .. nadvice},
}
for _, opts in ipairs({{}, {noiseSeed = 9}}) do
    local tag = opts.noiseSeed and " under --noise-seed" or ""
    for i, r in ipairs(nrules) do
        local e = failure("nrule" .. i .. (opts.noiseSeed or ""), canvas .. r[2], opts)
        local want = "seed-nrule" .. i .. (opts.noiseSeed or "") .. ".lua:4: " .. r[3]
        check("gen.noiseSeed " .. r[1] .. tag .. " is an error at its line", e and e:find(want, 1, true), e)
    end
end
check("random draws leave gen.noiseSeed open",
    failure("noise-after-rand", canvas .. "local _ = gen.rand()\ngen.noiseSeed(2)\n") == nil)
check("noise with its own seed leaves gen.noiseSeed open",
    failure("noise-own-seed", canvas .. "local _ = gen.noiseGrid(4, 4, {seed = 3})\ngen.noiseSeed(2)\n") == nil)

T.summary()
