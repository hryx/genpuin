-- tiles.lua — tiled patterns demo
-- Grid of tiles with rotating geometric motifs

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#1a1a2e"))
gen.seed(42)

local cols, rows = 8, 8
local tileSize = W / cols

gen.grid(cols, rows, tileSize, function(x, y, col, row)
    local cx = x + tileSize / 2
    local cy = y + tileSize / 2
    local hue = (col + row) / (cols + rows)
    local color = gen.hsv(hue, 0.5, 0.85)

    -- each tile gets a random motif
    local motif = gen.randInt(0, 3)

    if motif == 0 then
        -- concentric circles
        for r = 3, 1, -1 do
            gen.draw(c, gen.circle({cx, cy}, r * tileSize * 0.12), {
                stroke = color,
                strokeWidth = 1,
                fill = "none",
                opacity = 0.6,
            })
        end
    elseif motif == 1 then
        -- diagonal cross
        local m = tileSize * 0.35
        gen.draw(c, gen.line({cx - m, cy - m}, {cx + m, cy + m}), {
            stroke = color, strokeWidth = 1.5, opacity = 0.7,
        })
        gen.draw(c, gen.line({cx - m, cy + m}, {cx + m, cy - m}), {
            stroke = color, strokeWidth = 1.5, opacity = 0.7,
        })
    elseif motif == 2 then
        -- small radial burst
        local n = gen.randInt(5, 8)
        local r = tileSize * 0.35
        gen.radial(n, {cx, cy}, r, function(pos, angle, i)
            gen.draw(c, gen.line({cx, cy}, pos), {
                stroke = color, strokeWidth = 0.8, opacity = 0.6,
            })
        end)
    else
        -- diamond
        local m = tileSize * 0.3
        gen.draw(c, gen.polygon({
            {cx, cy - m}, {cx + m, cy}, {cx, cy + m}, {cx - m, cy},
        }), {
            stroke = color,
            strokeWidth = 1,
            fill = "none",
            opacity = 0.7,
        })
    end
end)

gen.exportSvg(c, "out/tiles.svg")
gen.exportPpm(c, "out/tiles.ppm")
print("Wrote out/tiles.svg and out/tiles.ppm")
