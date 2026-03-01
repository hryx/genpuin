-- markov-weave.lua — Markov chain-driven woven pattern
-- Demonstrates: gen.markov, gen.markovStep, gen.markovGenerate, grid layout

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#1a1a2e"))
gen.seed(42)

-- A Markov chain controlling the "mood" of each grid row/column.
-- States represent visual modes: thin strokes, thick strokes, dots, gaps.
local mood = gen.markov({
    thin  = {{"thin", 3}, {"thick", 2}, {"dot", 1}},
    thick = {{"thick", 2}, {"thin", 2}, {"gap", 1}},
    dot   = {{"dot", 1}, {"thin", 3}, {"thick", 1}},
    gap   = {{"thin", 3}, {"dot", 1}},
})

-- Generate mood sequences for rows and columns
local cols = 40
local rows = 40
local rowMoods = gen.markovGenerate(mood, "thin", rows)
local colMoods = gen.markovGenerate(mood, "thick", cols)

local cellW = W / cols
local cellH = H / rows
local margin = 40

-- Palette per mood
local palette = {
    thin  = {hue = 0.55, sat = 0.6, val = 0.7},
    thick = {hue = 0.08, sat = 0.7, val = 0.8},
    dot   = {hue = 0.75, sat = 0.5, val = 0.7},
    gap   = nil,
}

-- Draw horizontal strands (rows)
for row = 1, rows do
    local m = rowMoods[row]
    local p = palette[m]
    if p then
        local y = margin + (row - 0.5) * ((H - 2 * margin) / rows)
        for col = 1, cols do
            local x = margin + (col - 0.5) * ((W - 2 * margin) / cols)
            -- Weave: skip every other column based on row parity
            if (row + col) % 2 == 0 then
                if m == "thin" then
                    gen.draw(c, gen.line({x - cellW * 0.4, y}, {x + cellW * 0.4, y}), {
                        stroke = gen.hsv(p.hue, p.sat, p.val),
                        strokeWidth = 1,
                        strokeLinecap = "round",
                        opacity = 0.8,
                    })
                elseif m == "thick" then
                    gen.draw(c, gen.line({x - cellW * 0.4, y}, {x + cellW * 0.4, y}), {
                        stroke = gen.hsv(p.hue, p.sat, p.val),
                        strokeWidth = 3,
                        strokeLinecap = "round",
                        opacity = 0.7,
                    })
                elseif m == "dot" then
                    gen.draw(c, gen.circle({x, y}, 2), {
                        fill = gen.hsv(p.hue, p.sat, p.val),
                        opacity = 0.8,
                    })
                end
            end
        end
    end
end

-- Draw vertical strands (columns)
for col = 1, cols do
    local m = colMoods[col]
    local p = palette[m]
    if p then
        local x = margin + (col - 0.5) * ((W - 2 * margin) / cols)
        for row = 1, rows do
            local y = margin + (row - 0.5) * ((H - 2 * margin) / rows)
            -- Weave: draw on the opposite parity from horizontal
            if (row + col) % 2 == 1 then
                if m == "thin" then
                    gen.draw(c, gen.line({x, y - cellH * 0.4}, {x, y + cellH * 0.4}), {
                        stroke = gen.hsv(p.hue, p.sat, p.val),
                        strokeWidth = 1,
                        strokeLinecap = "round",
                        opacity = 0.8,
                    })
                elseif m == "thick" then
                    gen.draw(c, gen.line({x, y - cellH * 0.4}, {x, y + cellH * 0.4}), {
                        stroke = gen.hsv(p.hue, p.sat, p.val),
                        strokeWidth = 3,
                        strokeLinecap = "round",
                        opacity = 0.7,
                    })
                elseif m == "dot" then
                    gen.draw(c, gen.circle({x, y}, 2), {
                        fill = gen.hsv(p.hue, p.sat, p.val),
                        opacity = 0.8,
                    })
                end
            end
        end
    end
end

return c
