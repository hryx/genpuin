-- poisson-text.lua — Draw text using Poisson disk grid points
-- Each letter is defined with minimal control points, snapped to
-- the nearest Poisson disk sample, then connected with jittery lines.

local gen = require("genpuin")

local M = {}

-- Letter definitions: control points in [0,1] space + stroke index pairs
local alphabet = {
    A = {
        pts = {{0.1,1},{0.3,0.5},{0.5,0},{0.7,0.5},{0.9,1}},
        strokes = {{1,2},{2,3},{3,4},{4,5},{2,4}},
    },
    B = {
        pts = {{0.15,0},{0.15,0.5},{0.15,1},{0.7,0.15},{0.7,0.35},{0.75,0.65},{0.75,0.85},{0.6,0},{0.6,1}},
        strokes = {{1,3},{1,8},{8,4},{4,5},{5,2},{2,6},{6,7},{7,9},{9,3}},
    },
    C = {
        pts = {{0.8,0.15},{0.4,0},{0.15,0.5},{0.4,1},{0.8,0.85}},
        strokes = {{1,2},{2,3},{3,4},{4,5}},
    },
    D = {
        pts = {{0.15,0},{0.15,1},{0.55,0},{0.85,0.5},{0.55,1}},
        strokes = {{1,2},{1,3},{3,4},{4,5},{5,2}},
    },
    E = {
        pts = {{0.15,0},{0.8,0},{0.15,0.5},{0.7,0.5},{0.15,1},{0.8,1}},
        strokes = {{1,2},{1,5},{3,4},{5,6}},
    },
    F = {
        pts = {{0.15,0},{0.8,0},{0.15,0.5},{0.7,0.5},{0.15,1}},
        strokes = {{1,2},{1,5},{3,4}},
    },
    G = {
        pts = {{0.8,0.15},{0.4,0},{0.15,0.5},{0.4,1},{0.8,0.85},{0.8,0.5},{0.55,0.5}},
        strokes = {{1,2},{2,3},{3,4},{4,5},{5,6},{6,7}},
    },
    H = {
        pts = {{0.15,0},{0.15,0.5},{0.15,1},{0.85,0},{0.85,0.5},{0.85,1}},
        strokes = {{1,3},{4,6},{2,5}},
    },
    I = {
        pts = {{0.25,0},{0.75,0},{0.5,0},{0.5,1},{0.25,1},{0.75,1}},
        strokes = {{1,2},{3,4},{5,6}},
    },
    J = {
        pts = {{0.7,0},{0.7,0.8},{0.4,1},{0.15,0.8}},
        strokes = {{1,2},{2,3},{3,4}},
    },
    K = {
        pts = {{0.15,0},{0.15,0.5},{0.15,1},{0.85,0},{0.85,1}},
        strokes = {{1,3},{4,2},{2,5}},
    },
    L = {
        pts = {{0.15,0},{0.15,1},{0.85,1}},
        strokes = {{1,2},{2,3}},
    },
    M = {
        pts = {{0.1,1},{0.1,0},{0.5,0.5},{0.9,0},{0.9,1}},
        strokes = {{1,2},{2,3},{3,4},{4,5}},
    },
    N = {
        pts = {{0.15,1},{0.15,0},{0.85,1},{0.85,0}},
        strokes = {{1,2},{2,3},{3,4}},
    },
    O = {
        pts = {{0.5,0},{0.1,0.5},{0.5,1},{0.9,0.5}},
        strokes = {{1,2},{2,3},{3,4},{4,1}},
    },
    P = {
        pts = {{0.15,0},{0.15,0.5},{0.15,1},{0.7,0.1},{0.7,0.4}},
        strokes = {{1,3},{1,4},{4,5},{5,2}},
    },
    Q = {
        pts = {{0.5,0},{0.1,0.5},{0.5,1},{0.9,0.5},{0.6,0.7},{0.9,1}},
        strokes = {{1,2},{2,3},{3,4},{4,1},{5,6}},
    },
    R = {
        pts = {{0.15,0},{0.15,0.5},{0.15,1},{0.7,0.1},{0.7,0.4},{0.85,1}},
        strokes = {{1,3},{1,4},{4,5},{5,2},{2,6}},
    },
    S = {
        pts = {{0.8,0.15},{0.4,0},{0.15,0.25},{0.5,0.5},{0.85,0.75},{0.6,1},{0.2,0.85}},
        strokes = {{1,2},{2,3},{3,4},{4,5},{5,6},{6,7}},
    },
    T = {
        pts = {{0.1,0},{0.9,0},{0.5,0},{0.5,1}},
        strokes = {{1,2},{3,4}},
    },
    U = {
        pts = {{0.15,0},{0.15,0.8},{0.5,1},{0.85,0.8},{0.85,0}},
        strokes = {{1,2},{2,3},{3,4},{4,5}},
    },
    V = {
        pts = {{0.1,0},{0.5,1},{0.9,0}},
        strokes = {{1,2},{2,3}},
    },
    W = {
        pts = {{0.05,0},{0.3,1},{0.5,0.4},{0.7,1},{0.95,0}},
        strokes = {{1,2},{2,3},{3,4},{4,5}},
    },
    X = {
        pts = {{0.1,0},{0.5,0.5},{0.9,1},{0.9,0},{0.1,1}},
        strokes = {{1,2},{2,3},{4,2},{2,5}},
    },
    Y = {
        pts = {{0.1,0},{0.5,0.45},{0.9,0},{0.5,1}},
        strokes = {{1,2},{3,2},{2,4}},
    },
    Z = {
        pts = {{0.1,0},{0.9,0},{0.1,1},{0.9,1}},
        strokes = {{1,2},{2,3},{3,4}},
    },
}

-- Find nearest point in a set to a target position
local function nearest(pts, tx, ty)
    local best, bestD = nil, math.huge
    for _, p in ipairs(pts) do
        local dx, dy = p[1] - tx, p[2] - ty
        local d = dx * dx + dy * dy
        if d < bestD then best = p; bestD = d end
    end
    return best
end

-- Draw a jittery line between two points
local function jitterLine(canvas, a, b, jitterAmt, color, strokeWidth)
    local n = 10
    local pts = {}
    for i = 0, n do
        local t = i / n
        local x = gen.lerp(a[1], b[1], t)
        local y = gen.lerp(a[2], b[2], t)
        if i > 0 and i < n then
            x = x + gen.randRange(-jitterAmt, jitterAmt)
            y = y + gen.randRange(-jitterAmt, jitterAmt)
        end
        pts[#pts + 1] = {x, y}
    end
    gen.draw(canvas, gen.polyline(pts), {
        stroke = color,
        strokeWidth = strokeWidth,
        fill = "none",
        strokeLinecap = "round",
        strokeLinejoin = "round",
    })
end

--- Draw text using Poisson disk grid points.
--- @param canvas  The genpuin canvas to draw on
--- @param text    String to render (uppercase A-Z and spaces)
--- @param opts    Table with fields:
---   x, y         — top-left of the text area (required)
---   lineHeight   — height of each character cell (required)
---   spacing      — Poisson disk minDist (default: lineHeight / 20)
---   points       — pre-generated Poisson disk points (optional)
---   color        — stroke color (default: white)
---   strokeWidth  — line width (default: 1.2)
---   jitter       — jitter displacement (default: 2.5)
---   dotSize      — vertex dot radius (default: 1.5, 0 to disable)
function M.draw(canvas, text, opts)
    local ox = opts.x
    local oy = opts.y
    local lh = opts.lineHeight
    local cellW = lh * 0.55
    local spacing = opts.spacing or (lh / 20)
    local color = opts.color or gen.rgb(1, 1, 1)
    local sw = opts.strokeWidth or 1.2
    local jitterAmt = opts.jitter or 2.5
    local dotSize = opts.dotSize
    if dotSize == nil then dotSize = 1.5 end

    -- Generate or reuse Poisson disk points
    local pts = opts.points
    if not pts then
        pts = gen.poissonDisk({0, 0, canvas.width, canvas.height}, spacing)
    end

    -- Collapse all whitespace to single spaces, uppercase
    text = text:upper():gsub("%s+", " ")

    local padX = cellW * 0.08
    local padY = lh * 0.05
    local innerW = cellW - padX * 2
    local innerH = lh - padY * 2

    local cursorX = ox
    for i = 1, #text do
        local ch = text:sub(i, i)
        local letter = alphabet[ch]

        if letter then
            -- Map ideal points to canvas coords, snap to nearest Poisson point
            local mapped = {}
            for _, pt in ipairs(letter.pts) do
                local tx = cursorX + padX + pt[1] * innerW
                local ty = oy + padY + pt[2] * innerH
                mapped[#mapped + 1] = nearest(pts, tx, ty)
            end

            -- Draw strokes
            for _, s in ipairs(letter.strokes) do
                jitterLine(canvas, mapped[s[1]], mapped[s[2]], jitterAmt, color, sw)
            end

            -- Vertex dots
            if dotSize > 0 then
                for _, mp in ipairs(mapped) do
                    gen.draw(canvas, gen.circle(mp, dotSize), {
                        fill = color,
                        opacity = 0.5,
                    })
                end
            end
        end
        -- Advance cursor (for space or letter)
        cursorX = cursorX + cellW
    end

    return cursorX
end

return M
