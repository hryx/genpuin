-- showcase-patterns.lua — Grid, radial, Poisson, randomness
-- Demonstrates: grid, radial, poissonDisk,
-- hsv, gaussian, pick, randInCircle, randOnCircle

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#1a1a2e"))
gen.seed(42)
gen.noiseSeed(42)

-- === Top: Grid of tiled motifs ===

local cols, rows = 8, 4
local tileSize = W / cols
local motifs = {"circles", "cross", "burst", "diamond"}

gen.grid(cols, rows, tileSize, function(x, y, col, row)
    local cx = x + tileSize / 2
    local cy = y + tileSize / 2
    local hue = (col + row) / (cols + rows)
    local color = gen.hsv(hue, 0.5, 0.85)
    local motif = gen.pick(motifs)

    if motif == "circles" then
        for r = 3, 1, -1 do
            gen.draw(c, gen.circle({cx, cy}, r * tileSize * 0.12), {
                stroke = color, strokeWidth = 1, fill = "none", opacity = 0.6,
            })
        end
    elseif motif == "cross" then
        local m = tileSize * 0.35
        gen.draw(c, gen.line({cx - m, cy - m}, {cx + m, cy + m}), {
            stroke = color, strokeWidth = 1.5, opacity = 0.7,
        })
        gen.draw(c, gen.line({cx - m, cy + m}, {cx + m, cy - m}), {
            stroke = color, strokeWidth = 1.5, opacity = 0.7,
        })
    elseif motif == "burst" then
        local n = gen.randInt(5, 8)
        local r = tileSize * 0.35
        gen.radial(n, {cx, cy}, r, function(pos)
            gen.draw(c, gen.line({cx, cy}, pos), {
                stroke = color, strokeWidth = 0.8, opacity = 0.6,
            })
        end)
    else
        local m = tileSize * 0.3
        gen.draw(c, gen.polygon({
            {cx, cy - m}, {cx + m, cy}, {cx, cy + m}, {cx - m, cy},
        }), {stroke = color, strokeWidth = 1, fill = "none", opacity = 0.7})
    end
end)

-- === Middle: Poisson disk + radial bursts ===

local midY = rows * tileSize + 10
local points = gen.poissonDisk({20, midY, W - 40, 200}, 35)

for _, pt in ipairs(points) do
    local hue = gen.perlin(pt[1] * 0.005, pt[2] * 0.005) * 0.5 + 0.5
    local col = gen.hsv(hue, 0.6, 0.9)
    gen.draw(c, gen.circle(pt, 2.5), {fill = col, opacity = 0.8})

    local n = gen.randInt(4, 7)
    local r = gen.randRange(8, 20)
    gen.radial(n, pt, r, function(pos)
        gen.draw(c, gen.line(pt, pos), {
            stroke = col, strokeWidth = 0.6, opacity = 0.4,
        })
        gen.draw(c, gen.circle(pos, 1.2), {fill = col, opacity = 0.5})
    end)
end

-- Gaussian-distributed cluster overlay
local gCenter = {W / 2, midY + 100}
for _ = 1, 60 do
    local gx = gCenter[1] + gen.gaussian(0, 60)
    local gy = gCenter[2] + gen.gaussian(0, 30)
    gen.draw(c, gen.circle({gx, gy}, 1), {
        fill = gen.hex("#ffffff"), opacity = 0.3,
    })
end

-- randInCircle + randOnCircle demo
local rcCenter = {650, midY + 100}
for _ = 1, 40 do
    local pt = gen.randInCircle(rcCenter, 50)
    gen.draw(c, gen.circle(pt, 1.5), {
        fill = gen.hex("#42d4f4"), opacity = 0.5,
    })
end
for _ = 1, 20 do
    local pt = gen.randOnCircle(rcCenter, 55)
    gen.draw(c, gen.circle(pt, 2), {
        fill = gen.hex("#f032e6"), opacity = 0.7,
    })
end

return c
