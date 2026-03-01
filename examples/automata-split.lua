-- automata-split.lua — Two elementary cellular automata meeting at the diagonal
-- Demonstrates: gen.elementary with custom init, triangle clipping, dual palettes

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#f5f0e8"))

local cellW = 200
local steps = 200
local cellSize = W / cellW

-- === Top automaton: Rule 110, spine along right edge, growing down-left ===
local initTop = {}
for i = 1, cellW do initTop[i] = 0 end
initTop[cellW] = 1

local rowsTop = gen.elementary(110, cellW, steps, initTop)

for row = 1, #rowsTop do
    for col = 1, cellW do
        if rowsTop[row][col] == 1 and col >= cellW - row + 1 then
            local t = (row - 1) / #rowsTop
            local hue = gen.lerp(0.0, 0.08, t)
            local sat = gen.lerp(0.7, 0.5, t)
            local val = gen.lerp(0.2, 0.4, t)
            local x = (col - 1) * cellSize
            local y = (row - 1) * cellSize
            gen.draw(c, gen.rect(x, y, cellSize, cellSize), {
                fill = gen.hsv(hue, sat, val),
            })
        end
    end
end

-- === Bottom automaton: Rule 30, spine along left edge, growing up-right ===
local initBot = {}
for i = 1, cellW do initBot[i] = 0 end
initBot[1] = 1

local rowsBot = gen.elementary(30, cellW, steps, initBot)

for row = 1, #rowsBot do
    for col = 1, cellW do
        if rowsBot[row][col] == 1 and col <= row then
            local t = (row - 1) / #rowsBot
            local hue = gen.lerp(0.58, 0.52, t)
            local sat = gen.lerp(0.6, 0.4, t)
            local val = gen.lerp(0.25, 0.45, t)
            local x = (col - 1) * cellSize
            -- Flip vertically: row 1 at bottom, last row at top
            local y = H - row * cellSize
            gen.draw(c, gen.rect(x, y, cellSize, cellSize), {
                fill = gen.hsv(hue, sat, val),
            })
        end
    end
end

return c
