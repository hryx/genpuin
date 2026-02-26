-- dotmatrix-text.lua — Draw text as 5x7 dot matrix characters
-- Each letter is a 5-wide, 7-tall bitmap. Dots are drawn as circles
-- with optional size variation driven by noise.

local gen = require("genpuin")

local M = {}

-- 5x7 bitmaps, each row is a string of 5 chars ("." = off, "#" = on)
local glyphs = {
    A = {
        ".###.",
        "#...#",
        "#...#",
        "#####",
        "#...#",
        "#...#",
        "#...#",
    },
    B = {
        "####.",
        "#...#",
        "#...#",
        "####.",
        "#...#",
        "#...#",
        "####.",
    },
    C = {
        ".###.",
        "#...#",
        "#....",
        "#....",
        "#....",
        "#...#",
        ".###.",
    },
    D = {
        "####.",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        "####.",
    },
    E = {
        "#####",
        "#....",
        "#....",
        "###..",
        "#....",
        "#....",
        "#####",
    },
    F = {
        "#####",
        "#....",
        "#....",
        "###..",
        "#....",
        "#....",
        "#....",
    },
    G = {
        ".###.",
        "#...#",
        "#....",
        "#.###",
        "#...#",
        "#...#",
        ".###.",
    },
    H = {
        "#...#",
        "#...#",
        "#...#",
        "#####",
        "#...#",
        "#...#",
        "#...#",
    },
    I = {
        "###",
        ".#.",
        ".#.",
        ".#.",
        ".#.",
        ".#.",
        "###",
    },
    J = {
        "..###",
        "...#.",
        "...#.",
        "...#.",
        "#..#.",
        "#..#.",
        ".##..",
    },
    K = {
        "#...#",
        "#..#.",
        "#.#..",
        "##...",
        "#.#..",
        "#..#.",
        "#...#",
    },
    L = {
        "#....",
        "#....",
        "#....",
        "#....",
        "#....",
        "#....",
        "#####",
    },
    M = {
        "#...#",
        "##.##",
        "#.#.#",
        "#.#.#",
        "#...#",
        "#...#",
        "#...#",
    },
    N = {
        "#...#",
        "##..#",
        "#.#.#",
        "#..##",
        "#...#",
        "#...#",
        "#...#",
    },
    O = {
        ".###.",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        ".###.",
    },
    P = {
        "####.",
        "#...#",
        "#...#",
        "####.",
        "#....",
        "#....",
        "#....",
    },
    Q = {
        ".###.",
        "#...#",
        "#...#",
        "#...#",
        "#.#.#",
        "#..#.",
        ".##.#",
    },
    R = {
        "####.",
        "#...#",
        "#...#",
        "####.",
        "#.#..",
        "#..#.",
        "#...#",
    },
    S = {
        ".###.",
        "#...#",
        "#....",
        ".###.",
        "....#",
        "#...#",
        ".###.",
    },
    T = {
        "#####",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
    },
    U = {
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        ".###.",
    },
    V = {
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        ".#.#.",
        ".#.#.",
        "..#..",
    },
    W = {
        "#...#",
        "#...#",
        "#...#",
        "#.#.#",
        "#.#.#",
        "##.##",
        "#...#",
    },
    X = {
        "#...#",
        "#...#",
        ".#.#.",
        "..#..",
        ".#.#.",
        "#...#",
        "#...#",
    },
    Y = {
        "#...#",
        "#...#",
        ".#.#.",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
    },
    Z = {
        "#####",
        "....#",
        "...#.",
        "..#..",
        ".#...",
        "#....",
        "#####",
    },
}

--- Draw text as dot matrix.
--- @param canvas  The genpuin canvas
--- @param text    String to render (A-Z and spaces)
--- @param opts    Table with fields:
---   x, y         — top-left position (required)
---   lineHeight   — total height of a character cell (required)
---   color        — dot color (default: white)
---   dotScale     — base dot radius as fraction of grid spacing (default: 0.35)
---   noiseScale   — how much noise affects dot size, 0 to disable (default: 0.15)
---   opacity      — base opacity (default: 0.9)
function M.draw(canvas, text, opts)
    local ox = opts.x
    local oy = opts.y
    local lh = opts.lineHeight
    local color = opts.color or gen.rgb(1, 1, 1)
    local dotScale = opts.dotScale or 0.35
    local noiseScale = opts.noiseScale or 0.15
    local baseOpacity = opts.opacity or 0.9

    text = text:upper():gsub("%s+", " ")

    -- Grid sizing: 7 rows fit in lineHeight, derive cell from that
    local gridY = lh / 7
    local gridX = gridY  -- square cells
    local charGap = gridX * 1.0  -- gap between characters
    local glyphW = 5  -- max columns

    local cursorX = ox
    for i = 1, #text do
        local ch = text:sub(i, i)
        local glyph = glyphs[ch]

        if glyph then
            local actualW = #glyph[1]  -- handle variable-width (e.g. I is 3 wide)
            for row = 1, 7 do
                local rowStr = glyph[row]
                for col = 1, #rowStr do
                    if rowStr:sub(col, col) == "#" then
                        local cx = cursorX + (col - 1) * gridX + gridX / 2
                        local cy = oy + (row - 1) * gridY + gridY / 2
                        local nv = gen.perlin(cx * 0.03, cy * 0.03)
                        local r = gridX * dotScale * (1 + nv * noiseScale)
                        local op = baseOpacity * gen.clamp(1 + nv * 0.2, 0.6, 1)
                        gen.draw(canvas, gen.circle({cx, cy}, r), {
                            fill = color,
                            opacity = op,
                        })
                    end
                end
            end
            cursorX = cursorX + actualW * gridX + charGap
        elseif ch == " " then
            cursorX = cursorX + glyphW * gridX + charGap
        end
    end

    return cursorX
end

return M
