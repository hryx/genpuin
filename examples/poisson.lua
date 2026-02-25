-- poisson.lua — Poisson disk sampling + radial patterns
-- Blue noise points with small radial bursts at each

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#0a0a1a"))
gen.seed(42)
gen.noiseSeed(42)

-- Generate evenly-spaced points via Poisson disk sampling
local points = gen.poissonDisk({0, 0, W, H}, 50)

-- At each point, draw a small radial burst
for i, pt in ipairs(points) do
    local hue = gen.perlin(pt[1] * 0.005, pt[2] * 0.005) * 0.5 + 0.5
    local col = gen.hsv(hue, 0.6, 0.9)

    -- center dot
    gen.draw(c, gen.circle(pt, 2), {fill = col, opacity = 0.8})

    -- radial spokes
    local n = gen.randInt(4, 8)
    local r = gen.randRange(10, 25)
    gen.radial(n, pt, r, function(pos, angle, j)
        gen.draw(c, gen.line(pt, pos), {
            stroke = col,
            strokeWidth = 0.6,
            opacity = 0.4,
        })
        gen.draw(c, gen.circle(pos, 1.5), {fill = col, opacity = 0.5})
    end)
end

gen.exportSvg(c, "out/poisson.svg")
print("Wrote out/poisson.svg (" .. #points .. " points)")
