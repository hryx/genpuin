-- test-algo.lua: the gen.* algorithm API against values printed by the
-- original pure Lua library or derived from the random stream, plus a
-- colorMap render check.

local T = require("test.testkit")
local check = T.check

local function near(name, got, want)
    check(name, got == want, string.format("got %.17g, want %.17g", got, want))
end

print("Random stream")
gen.seed(42)
near("seed 42, first", gen.rand(), 0.8143051451229099)
near("seed 42, second", gen.rand(), 0.3188210400616611)
gen.seed(42)
local u = {}
for i = 1, 6 do u[i] = gen.rand() end
gen.seed(42)
check("randInt", gen.randInt(1, 100) == 1 + math.floor(u[1] * 100) and gen.randInt(-5, 5) == -5 + math.floor(u[2] * 11))
near("randRange", gen.randRange(-3, 7), -3 + u[3] * 10)
check("gaussian", math.abs(gen.gaussian(0, 1) - math.sqrt(-2 * math.log(1 - u[4])) * math.cos(2 * math.pi * u[5])) < 1e-12)
gen.seed(3)
local pd = gen.poissonDisk({0, 0, 50, 50}, 10)
local apart = #pd >= 10
for i = 1, #pd do
    for k = i + 1, #pd do
        apart = apart and math.sqrt((pd[i][1] - pd[k][1]) ^ 2 + (pd[i][2] - pd[k][2]) ^ 2) >= 10
    end
end
check("poissonDisk points are apart", apart, "got " .. #pd)

print("Streams from one seed")
local function draws(n)
    local t = {}
    for i = 1, n do t[i] = gen.rand() end
    return table.concat(t, " ")
end
gen.seed(5)
local base5 = draws(3)
gen.mixSeed(1)
local mix1 = draws(3)
gen.mixSeed(2)
local mix2 = draws(3)
gen.mixSeed(1)
check("the same k restarts the same stream", draws(3) == mix1)
check("distinct k give distinct streams", mix1 ~= mix2 and mix1 ~= base5)
gen.seed(6)
gen.mixSeed(1)
check("the same k under another base differs", draws(3) ~= mix1)
gen.seed(5)
check("mixSeed leaves the base alone", draws(3) == base5)

local list = {"a", "b", "c", "d", "e"}
local sh = gen.shuffle(list)
local seen = {}
for _, v in ipairs(sh) do seen[v] = true end
check("shuffle is a permutation", #sh == 5 and seen.a and seen.e)
check("shuffle leaves the input alone", list[1] == "a" and list[5] == "e")
check("weightedPick skips zero weights", gen.weightedPick({"x", "y"}, {0, 1}) == "y")

print("Noise")
gen.noiseSeed(42)
near("perlin", gen.perlin(1.25, 3.75), -0.13116359710693359)
near("fbm defaults", gen.fbm(0.3, 0.7), -0.28546561015873007)
near("fbm options", gen.fbm(12.1, -4.4, 3, 2.5, 0.4), -0.27284709159655451)

print("Geometry")
local cells = gen.voronoi({{25, 50}, {75, 50}}, {0, 0, 100, 100})
check("voronoi cells", #cells == 2 and cells[1].cell.type == "polygon")
check("voronoi keeps the site table", cells[2].site[1] == 75)
check("pointInPolygon", gen.pointInPolygon({5, 5}, gen.polygon({{0, 0}, {10, 0}, {10, 10}, {0, 10}})))
local hits = gen.withinRadius({0, 0}, {{3, 0}, {0, 1}, {9, 9}, {0, 2}}, 3)
check("withinRadius order", #hits == 3 and hits[1].index == 2 and hits[3].index == 1)
local s = gen.sampleAlong(gen.polyline({{0, 0}, {10, 0}, {10, 10}}), 5)
check("sampleAlong", s.type == "polyline" and s.points[4][1] == 10 and s.points[4][2] == 5)
local dashes = gen.dash(gen.line({0, 0}, {10, 0}), 2, 3)
check("dash", #dashes == 2 and dashes[2].points[1][1] == 5)

print("Rewriting and automata")
check("rewrite", gen.rewrite("A", {A = "AB", B = "A"}, 4) == "ABAABABA")
local rows = gen.elementary(90, 7, 2)
check("elementary rule 90", table.concat(rows[3]) == "0100010")
local chain = gen.markovFrom({"a", "b", "a", "c", "a", "b"})
check("markovFrom first-appearance order",
    chain.a.nexts[1] == "b" and chain.a.nexts[2] == "c" and chain.a.weights[1] == 2)
local seq = gen.markovGenerate(chain, "c", 4)
check("markovGenerate", #seq == 4 and seq[2] == "a")

-- gen.life as the rule runs in Zig. Wrapping it in a function forces the
-- Lua rule loop, which must agree cell for cell.
local soup = {}
for y = 1, 9 do
    soup[y] = {}
    for x = 1, 11 do soup[y][x] = gen.rand() < 0.4 and 1 or 0 end
end
local function viaLua(v, n) return gen.life(v, n) end
local function same(a, b)
    for y = 1, #b do
        for x = 1, #b[y] do
            if a[y][x] ~= b[y][x] then return false end
        end
    end
    return #a == #b
end
for _, wrap in ipairs({true, false}) do
    local g1, g2 = soup, soup
    for _ = 1, 5 do
        g1 = gen.evolve(g1, gen.life, {wrap = wrap})
        g2 = gen.evolve(g2, viaLua, {wrap = wrap})
    end
    check("life in Zig matches the rule loop, wrap " .. tostring(wrap), same(g1, g2))
end
check("a ragged grid takes the rule loop and keeps its nil cells alive",
    same(gen.evolve({{1, 1, 1}, {1, 0}, {0, 1, 1}}, gen.life), gen.evolve({{1, 1, 1}, {1, 0}, {0, 1, 1}}, viaLua)))

print("colorMap render")
gen.canvas(40, 20)
gen.background({1, 1, 1})
gen.draw(gen.rect(0, 0, 20, 20), {fill = {1, 0, 0}})
gen.draw(gen.rect(10, 0, 30, 20), {fill = {0, 0, 0}, colorMap = {
    {from = {0, 0, 0}, to = {1, 1, 1}},
    {from = {1, 1, 1}, to = {0, 0, 0}},
}})
gen.exportPpm("out/test/test-algo.ppm")
local px = T.readPpm("out/test/test-algo.ppm")
local function isRgb(name, x, y, r, g, b)
    local pr, pg, pb = T.rgb(px, x, y)
    check(name, pr == r and pg == g and pb == b, string.format("(%d,%d) = %d,%d,%d", x, y, pr, pg, pb))
end
isRgb("red outside the map", 5, 10, 255, 0, 0)
isRgb("inverted red is cyan", 15, 10, 0, 255, 255)
isRgb("inverted white is black", 30, 10, 0, 0, 0)

T.summary()
