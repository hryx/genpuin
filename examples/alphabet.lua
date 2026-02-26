-- alphabet.lua — Poisson Grid Letters
-- Displays the full alphabet using the text-scratch module.

local gen = require("genpuin")
local poissonText = require("examples.text-scratch")

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

return c
