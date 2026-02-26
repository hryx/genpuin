-- alphabet.lua — Poisson Grid Letters
-- Displays the full alphabet using the poisson-text module.

local gen = require("genpuin")
local poissonText = require("examples.poisson-text")

local W, H = 1450, 500
local c = gen.canvas(W, H)
gen.background(c, gen.rgb(0, 0, 0))
gen.seed(42)

-- Generate shared Poisson disk points
local pts = gen.poissonDisk({0, 0, W, H}, 10)

local lineHeight = 200

-- Row 1: A-M
poissonText.draw(c, "ABCDEFGHIJKLM", {
    x = 10, y = 25,
    lineHeight = lineHeight,
    points = pts,
})

-- Row 2: N-Z
poissonText.draw(c, "NOPQRSTUVWXYZ", {
    x = 10, y = 275,
    lineHeight = lineHeight,
    points = pts,
})

gen.exportSvg(c, "out/alphabet.svg")
local scale = tonumber(arg and arg[1]) or 1
gen.exportPpm(c, "out/alphabet.ppm", scale)
print(string.format("Wrote out/alphabet.svg and out/alphabet.ppm (scale=%g)", scale))
