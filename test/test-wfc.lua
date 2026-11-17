-- test-wfc.lua: Wave function collapse through the Lua API
-- Checks socket rules, constraints, weight maps and errors on the returned
-- grids, then renders a forced checkerboard and reads its pixels back.

local T = require("test.testkit")
local gen = require("genpuin")

local check = T.check
local rgb = T.rgb

------------------------------------------------------------
-- Test 1: socket rule holds for every neighbour pair
------------------------------------------------------------
print("Test 1: pipe tiles connect")

local tiles = {
    {name = "blank", edges = {0, 0, 0, 0}},
    {name = "line", edges = {1, 0, 1, 0}, symmetry = "I", weight = 2},
    {name = "bend", edges = {1, 1, 0, 0}, symmetry = "L", weight = 2},
    {name = "tee", edges = {1, 1, 1, 0}, symmetry = "T"},
}
local base = {}
for _, t in ipairs(tiles) do base[t.name] = t.edges end

-- Edges n, e, s, w after a clockwise turn by rot (no flips in this set).
local function edges(cell)
    local e = base[cell.tile]
    local out = {e[1], e[2], e[3], e[4]}
    for _ = 1, cell.rot do out = {out[4], out[1], out[2], out[3]} end
    return out
end

local grid, attempts = gen.wfc({w = 30, h = 20, tiles = tiles, seed = 5, wrap = true})
check("grid has 20 rows of 30", #grid == 20 and #grid[1] == 30,
    string.format("%d rows, %d cols", #grid, #grid[1]))
check("attempt count returned", type(attempts) == "number" and attempts >= 1, tostring(attempts))
local bad = 0
for y = 1, 20 do
    for x = 1, 30 do
        local e = edges(grid[y][x])
        local east = edges(grid[y][x % 30 + 1])
        local south = edges(grid[y % 20 + 1][x])
        if e[2] ~= east[4] or e[3] ~= south[1] then bad = bad + 1 end
    end
end
check("every pair matches, wrapping", bad == 0, bad .. " mismatches")

------------------------------------------------------------
-- Test 2: constraints, weight maps, determinism
------------------------------------------------------------
print("\nTest 2: steering")

local g2 = gen.wfc({w = 12, h = 12, tiles = tiles, seed = 9,
    constraints = {{x = 1, y = 1, tile = "tee", rot = 2}, {x = 6, y = 6, tile = 2}}})
check("pinned tee", g2[1][1].tile == "tee" and g2[1][1].rot == 2,
    tostring(g2[1][1].tile) .. " rot " .. g2[1][1].rot)
check("pinned by index", g2[6][6].tile == "line", tostring(g2[6][6].tile))

local noTee = gen.field(1, 1, 0)
local g3 = gen.wfc({w = 16, h = 16, tiles = tiles, seed = 3, weightMap = {tee = noTee}})
local tees = 0
for y = 1, 16 do for x = 1, 16 do if g3[y][x].tile == "tee" then tees = tees + 1 end end end
check("zero weight map removes a tile", tees == 0, tees .. " tees")

local a = gen.wfc({w = 10, h = 10, tiles = tiles, seed = 77})
local b = gen.wfc({w = 10, h = 10, tiles = tiles, seed = 77})
local same = true
for y = 1, 10 do for x = 1, 10 do
    if a[y][x].tile ~= b[y][x].tile or a[y][x].rot ~= b[y][x].rot then same = false end
end end
check("same seed, same grid", same)

------------------------------------------------------------
-- Test 3: errors
------------------------------------------------------------
print("\nTest 3: unsolvable input")

local ok, err = pcall(gen.wfc, {w = 4, h = 4, retries = 2, tiles = {{edges = {"a", "a", "b", "a"}}}})
check("raises", not ok)
check("message names retries", tostring(err):find("2 retries") ~= nil, tostring(err))

------------------------------------------------------------
-- Test 4: overlapping model
------------------------------------------------------------
print("\nTest 4: overlap")

local sample = {
    {1, 1, 1, 1},
    {1, 5, 5, 1},
    {1, 5, 9, 1},
    {1, 1, 1, 1},
}
local o = gen.wfcOverlap({sample = sample, n = 2, w = 40, h = 30, seed = 2})
local foreign = 0
for y = 1, 30 do for x = 1, 40 do
    local v = o[y][x]
    if v ~= 1 and v ~= 5 and v ~= 9 then foreign = foreign + 1 end
end end
check("output is 30 rows of 40", #o == 30 and #o[1] == 40)
check("only sample values", foreign == 0, foreign .. " foreign cells")

------------------------------------------------------------
-- Test 5: directional sockets force a checkerboard, read back as pixels
------------------------------------------------------------
print("\nTest 5: checkerboard render")

-- "rb" fits only "br", so red and blue must alternate.
local board = gen.wfc({w = 6, h = 6, seed = 1, tiles = {
    {name = "red", edges = {"rb", "rb", "rb", "rb"}},
    {name = "blue", edges = {"br", "br", "br", "br"}},
}, constraints = {{x = 1, y = 1, tile = "red"}}})

local c = gen.canvas(60, 60)
gen.background(c, gen.rgb(1, 1, 1))
local colors = {red = gen.rgb(1, 0, 0), blue = gen.rgb(0, 0, 1)}
local placed = gen.wfcDraw(c, board, {size = 10, draw = function(tile, x, y, size)
    return gen.rect(x - size / 2, y - size / 2, size, size), {fill = colors[tile]}
end})
check("one placement per cell", #placed == 36, #placed .. " placements")
check("placement is the cell center", placed[1].x == 5 and placed[1].y == 5,
    string.format("(%g, %g)", placed[1].x, placed[1].y))

gen.exportPpm(c, "out/test/test-wfc.ppm")
local pixels = T.readPpm("out/test/test-wfc.ppm")
local wrong = 0
for row = 0, 5 do
    for col = 0, 5 do
        local r, _, bl = rgb(pixels, col * 10 + 5, row * 10 + 5)
        local wantRed = (row + col) % 2 == 0
        if (wantRed and not (r > 250 and bl < 5)) or (not wantRed and not (bl > 250 and r < 5)) then
            wrong = wrong + 1
        end
    end
end
check("pixels alternate red and blue from a red corner", wrong == 0, wrong .. " wrong cells")

T.summary()
