-- test-algo.lua: the gen.* algorithm API against values printed by the
-- original pure Lua library, plus a colorMap render check.

local T = require("test.testkit")
local gen = require("genpuin")

local check = T.check

local function near(name, got, want)
    check(name, got == want, string.format("got %.17g, want %.17g", got, want))
end

print("Random stream")
gen.seed(42)
near("seed 42, first", gen.rand(), 0.41605908889323473)
near("seed 42, second", gen.rand(), 0.020210096146911383)
gen.seed(42)
check("randInt", gen.randInt(1, 100) == 42 and gen.randInt(1, 100) == 3 and gen.randInt(-5, 5) == 4)
near("randRange", gen.randRange(-3, 7), 2.2892230707220733)
near("gaussian", gen.gaussian(0, 1), -1.5335276938166165)
gen.seed(3)
local pd = gen.poissonDisk({0, 0, 50, 50}, 10)
check("poissonDisk count", #pd == 17, "got " .. #pd)
near("poissonDisk last x", pd[#pd][1], 19.213472129636944)

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

print("colorMap render")
local c = gen.canvas(40, 20)
gen.background(c, {1, 1, 1})
gen.draw(c, gen.rect(0, 0, 20, 20), {fill = {1, 0, 0}})
gen.draw(c, gen.rect(10, 0, 30, 20), {fill = {0, 0, 0}, colorMap = {
    {from = {0, 0, 0}, to = {1, 1, 1}},
    {from = {1, 1, 1}, to = {0, 0, 0}},
}})
os.execute("mkdir -p out/test")
gen.exportPpm(c, "out/test/test-algo.ppm")
local px = T.readPpm("out/test/test-algo.ppm")
local function isRgb(name, x, y, r, g, b)
    local pr, pg, pb = T.rgb(px, x, y)
    check(name, pr == r and pg == g and pb == b, string.format("(%d,%d) = %d,%d,%d", x, y, pr, pg, pb))
end
isRgb("red outside the map", 5, 10, 255, 0, 0)
isRgb("inverted red is cyan", 15, 10, 0, 255, 255)
isRgb("inverted white is black", 30, 10, 0, 0, 0)

T.summary()
