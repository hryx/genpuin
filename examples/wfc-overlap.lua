-- A small hand-drawn sample grown into a circuit texture. Shows
-- gen.wfcOverlap.

local W, H = 800, 800
local CELL = 5
local COLS, ROWS = W / CELL, H / CELL

gen.seed(21)
gen.noiseSeed(21)

local c = gen.canvas(W, H)
gen.background(c, gen.hex("#0e1d22"))

-- 1 ground, 2 trace, 3 trace edge, 4 solder pad.
local sample = {
    {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
    {1, 3, 3, 3, 3, 3, 3, 3, 3, 1, 1, 1, 1, 1},
    {1, 3, 2, 2, 2, 2, 2, 2, 3, 1, 1, 1, 1, 1},
    {1, 3, 2, 2, 2, 2, 2, 2, 3, 1, 1, 1, 1, 1},
    {1, 3, 2, 2, 3, 3, 2, 2, 3, 3, 3, 3, 3, 1},
    {1, 3, 2, 2, 3, 3, 2, 2, 2, 2, 2, 2, 3, 1},
    {1, 3, 2, 2, 3, 3, 2, 2, 2, 2, 2, 2, 3, 1},
    {1, 3, 2, 2, 3, 3, 3, 3, 3, 3, 2, 2, 3, 1},
    {1, 3, 2, 2, 3, 1, 1, 1, 1, 3, 2, 2, 3, 1},
    {1, 3, 4, 4, 3, 1, 1, 1, 1, 3, 2, 2, 3, 1},
    {1, 3, 4, 4, 3, 1, 1, 1, 1, 3, 2, 2, 3, 1},
    {1, 3, 3, 3, 3, 1, 1, 1, 1, 3, 4, 4, 3, 1},
    {1, 1, 1, 1, 1, 1, 1, 1, 1, 3, 4, 4, 3, 1},
    {1, 1, 1, 1, 1, 1, 1, 1, 1, 3, 3, 3, 3, 1},
}

local grid = gen.wfcOverlap({
    sample = sample, n = 4, w = COLS, h = ROWS, symmetry = 8,
})

local mask = gen.hex("#173038")
local copper = {gen.hex("#c8643b"), gen.hex("#e9a54a"), gen.hex("#f4dc8c")}
local pad, hole = gen.hex("#bfeedd"), gen.hex("#0b1418")

-- Board grain: one faint dot per bare cell pair.
for y = 1, ROWS, 2 do
    for x = 1, COLS, 2 do
        if grid[y][x] == 1 then
            gen.draw(c, gen.circle({(x - 0.5) * CELL, (y - 0.5) * CELL}, 0.7), {fill = mask, opacity = 0.8})
        end
    end
end

local function copperAt(x, y)
    local t = gen.clamp(0.5 + 0.5 * (x + y) / (COLS + ROWS) - 0.25 + 0.5 * gen.fbm(x * 0.02, y * 0.02, 3), 0, 1)
    if t < 0.5 then return gen.lerpColor(copper[1], copper[2], t * 2) end
    return gen.lerpColor(copper[2], copper[3], (t - 0.5) * 2)
end

local S = CELL + 0.6
for y = 1, ROWS do
    for x = 1, COLS do
        local v = grid[y][x]
        local px, py = (x - 1) * CELL, (y - 1) * CELL
        if v == 2 or v == 4 then
            gen.draw(c, gen.rect(px, py, S, S), {fill = copperAt(x, y)})
        elseif v == 3 then
            gen.draw(c, gen.rect(px, py, S, S), {fill = mask})
        end
    end
end

-- Pads are 2x2 blocks of 4. Drill one hole at each block's center.
local function at(x, y) return grid[y] and grid[y][x] end
for y = 1, ROWS - 1 do
    for x = 1, COLS - 1 do
        if at(x, y) == 4 and at(x + 1, y) == 4 and at(x, y + 1) == 4 and at(x + 1, y + 1) == 4
            and at(x - 1, y) ~= 4 and at(x, y - 1) ~= 4 then
            local center = {x * CELL, y * CELL}
            gen.draw(c, gen.circle(center, CELL * 1.25), {fill = pad})
            gen.draw(c, gen.circle(center, CELL * 0.55), {fill = hole})
        end
    end
end

return c
