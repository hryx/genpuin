-- ants-text.lua — Draw text as swarms of tiny dots along curvy letter paths
-- Letters are defined with cubic bezier curves for a rounded, organic look.
-- Hundreds of small circles are scattered along each curve like ants on trails.

local gen = require("genpuin")

local M = {}

-- Sample points along a cubic bezier curve
local function sampleBezier(p0, p1, p2, p3, n)
    local pts = {}
    for i = 0, n do
        local t = i / n
        local u = 1 - t
        pts[#pts + 1] = {
            u*u*u*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t*t*t*p3[1],
            u*u*u*p0[2] + 3*u*u*t*p1[2] + 3*u*t*t*p2[2] + t*t*t*p3[2],
        }
    end
    return pts
end

-- Curvy letter definitions: each letter is a list of cubic bezier curves
-- {p0, p1, p2, p3} in [0,1] normalized space
local alphabet = {
    A = {
        {{0.1,1}, {0.15,0.5}, {0.35,0.05}, {0.5,0}},
        {{0.5,0}, {0.65,0.05}, {0.85,0.5}, {0.9,1}},
        {{0.27,0.55}, {0.4,0.5}, {0.6,0.5}, {0.73,0.55}},
    },
    B = {
        {{0.15,0}, {0.15,0.33}, {0.15,0.67}, {0.15,1}},
        {{0.15,0}, {0.7,0}, {0.75,0.5}, {0.15,0.5}},
        {{0.15,0.5}, {0.8,0.5}, {0.8,1}, {0.15,1}},
    },
    C = {
        {{0.8,0.1}, {0.4,-0.05}, {0.1,0.15}, {0.1,0.5}},
        {{0.1,0.5}, {0.1,0.85}, {0.4,1.05}, {0.8,0.9}},
    },
    D = {
        {{0.15,0}, {0.15,0.33}, {0.15,0.67}, {0.15,1}},
        {{0.15,0}, {0.6,0}, {0.85,0.15}, {0.85,0.5}},
        {{0.85,0.5}, {0.85,0.85}, {0.6,1}, {0.15,1}},
    },
    E = {
        {{0.15,0}, {0.15,0.33}, {0.15,0.67}, {0.15,1}},
        {{0.15,0}, {0.4,-0.02}, {0.6,-0.02}, {0.8,0.03}},
        {{0.15,0.5}, {0.3,0.47}, {0.5,0.47}, {0.65,0.5}},
        {{0.15,1}, {0.4,1.02}, {0.6,1.02}, {0.8,0.97}},
    },
    F = {
        {{0.15,0}, {0.15,0.33}, {0.15,0.67}, {0.15,1}},
        {{0.15,0}, {0.4,-0.02}, {0.6,-0.02}, {0.8,0.03}},
        {{0.15,0.5}, {0.3,0.47}, {0.5,0.47}, {0.65,0.5}},
    },
    G = {
        {{0.8,0.1}, {0.4,-0.05}, {0.1,0.15}, {0.1,0.5}},
        {{0.1,0.5}, {0.1,0.85}, {0.4,1.05}, {0.8,0.9}},
        {{0.8,0.9}, {0.8,0.75}, {0.8,0.6}, {0.8,0.5}},
        {{0.8,0.5}, {0.7,0.5}, {0.6,0.5}, {0.5,0.5}},
    },
    H = {
        {{0.15,0}, {0.15,0.33}, {0.15,0.67}, {0.15,1}},
        {{0.85,0}, {0.85,0.33}, {0.85,0.67}, {0.85,1}},
        {{0.15,0.5}, {0.35,0.45}, {0.65,0.45}, {0.85,0.5}},
    },
    I = {
        {{0.3,0}, {0.4,0}, {0.6,0}, {0.7,0}},
        {{0.5,0}, {0.5,0.33}, {0.5,0.67}, {0.5,1}},
        {{0.3,1}, {0.4,1}, {0.6,1}, {0.7,1}},
    },
    J = {
        {{0.7,0}, {0.7,0.33}, {0.7,0.67}, {0.7,0.85}},
        {{0.7,0.85}, {0.7,1.05}, {0.3,1.05}, {0.15,0.8}},
    },
    K = {
        {{0.15,0}, {0.15,0.33}, {0.15,0.67}, {0.15,1}},
        {{0.85,0}, {0.55,0.2}, {0.3,0.35}, {0.15,0.5}},
        {{0.15,0.5}, {0.3,0.65}, {0.55,0.8}, {0.85,1}},
    },
    L = {
        {{0.15,0}, {0.15,0.33}, {0.15,0.67}, {0.15,1}},
        {{0.15,1}, {0.4,1.02}, {0.6,1.02}, {0.85,0.97}},
    },
    M = {
        {{0.1,1}, {0.1,0.67}, {0.1,0.33}, {0.1,0}},
        {{0.1,0}, {0.2,0.15}, {0.4,0.45}, {0.5,0.5}},
        {{0.5,0.5}, {0.6,0.45}, {0.8,0.15}, {0.9,0}},
        {{0.9,0}, {0.9,0.33}, {0.9,0.67}, {0.9,1}},
    },
    N = {
        {{0.15,1}, {0.15,0.67}, {0.15,0.33}, {0.15,0}},
        {{0.15,0}, {0.3,0.3}, {0.7,0.7}, {0.85,1}},
        {{0.85,1}, {0.85,0.67}, {0.85,0.33}, {0.85,0}},
    },
    O = {
        {{0.5,0}, {0.85,0}, {0.9,0.3}, {0.9,0.5}},
        {{0.9,0.5}, {0.9,0.7}, {0.85,1}, {0.5,1}},
        {{0.5,1}, {0.15,1}, {0.1,0.7}, {0.1,0.5}},
        {{0.1,0.5}, {0.1,0.3}, {0.15,0}, {0.5,0}},
    },
    P = {
        {{0.15,0}, {0.15,0.33}, {0.15,0.67}, {0.15,1}},
        {{0.15,0}, {0.75,0}, {0.75,0.5}, {0.15,0.5}},
    },
    Q = {
        {{0.5,0}, {0.85,0}, {0.9,0.3}, {0.9,0.5}},
        {{0.9,0.5}, {0.9,0.7}, {0.85,1}, {0.5,1}},
        {{0.5,1}, {0.15,1}, {0.1,0.7}, {0.1,0.5}},
        {{0.1,0.5}, {0.1,0.3}, {0.15,0}, {0.5,0}},
        {{0.6,0.75}, {0.7,0.85}, {0.8,0.95}, {0.95,1.05}},
    },
    R = {
        {{0.15,0}, {0.15,0.33}, {0.15,0.67}, {0.15,1}},
        {{0.15,0}, {0.75,0}, {0.75,0.5}, {0.15,0.5}},
        {{0.15,0.5}, {0.35,0.65}, {0.6,0.85}, {0.85,1}},
    },
    S = {
        {{0.8,0.1}, {0.6,-0.05}, {0.2,0.05}, {0.15,0.25}},
        {{0.15,0.25}, {0.1,0.45}, {0.9,0.55}, {0.85,0.75}},
        {{0.85,0.75}, {0.8,0.95}, {0.4,1.05}, {0.2,0.9}},
    },
    T = {
        {{0.1,0}, {0.3,-0.02}, {0.7,-0.02}, {0.9,0}},
        {{0.5,0}, {0.5,0.33}, {0.5,0.67}, {0.5,1}},
    },
    U = {
        {{0.15,0}, {0.15,0.4}, {0.15,0.7}, {0.15,0.85}},
        {{0.15,0.85}, {0.15,1.05}, {0.85,1.05}, {0.85,0.85}},
        {{0.85,0.85}, {0.85,0.7}, {0.85,0.4}, {0.85,0}},
    },
    V = {
        {{0.1,0}, {0.2,0.4}, {0.35,0.75}, {0.5,1}},
        {{0.5,1}, {0.65,0.75}, {0.8,0.4}, {0.9,0}},
    },
    W = {
        {{0.05,0}, {0.12,0.5}, {0.2,0.85}, {0.3,1}},
        {{0.3,1}, {0.38,0.7}, {0.42,0.45}, {0.5,0.35}},
        {{0.5,0.35}, {0.58,0.45}, {0.62,0.7}, {0.7,1}},
        {{0.7,1}, {0.8,0.85}, {0.88,0.5}, {0.95,0}},
    },
    X = {
        {{0.1,0}, {0.25,0.2}, {0.4,0.4}, {0.5,0.5}},
        {{0.5,0.5}, {0.6,0.6}, {0.75,0.8}, {0.9,1}},
        {{0.9,0}, {0.75,0.2}, {0.6,0.4}, {0.5,0.5}},
        {{0.5,0.5}, {0.4,0.6}, {0.25,0.8}, {0.1,1}},
    },
    Y = {
        {{0.1,0}, {0.2,0.15}, {0.35,0.3}, {0.5,0.45}},
        {{0.9,0}, {0.8,0.15}, {0.65,0.3}, {0.5,0.45}},
        {{0.5,0.45}, {0.5,0.6}, {0.5,0.8}, {0.5,1}},
    },
    Z = {
        {{0.1,0}, {0.3,-0.02}, {0.7,-0.02}, {0.9,0.02}},
        {{0.9,0.02}, {0.7,0.35}, {0.3,0.65}, {0.1,0.98}},
        {{0.1,0.98}, {0.3,1.02}, {0.7,1.02}, {0.9,0.98}},
    },
}

--- Draw text as ant swarms along curvy letter paths.
--- @param canvas  The genpuin canvas
--- @param text    String to render (A-Z and spaces)
--- @param opts    Table with fields:
---   x, y         — top-left position (required)
---   lineHeight   — total height of a character cell (required)
---   color        — ant color (default: white)
---   density      — ants per unit length of curve (default: 0.8)
---   spread       — perpendicular scatter distance (default: lineHeight * 0.02)
---   dotRadius    — radius of each ant dot (default: 1.0)
---   opacity      — base opacity (default: 0.7)
function M.draw(canvas, text, opts)
    local ox = opts.x
    local oy = opts.y
    local lh = opts.lineHeight
    local cellW = lh * 0.55
    local color = opts.color or gen.rgb(1, 1, 1)
    local density = opts.density or 0.8
    local spread = opts.spread or (lh * 0.02)
    local dotRadius = opts.dotRadius or 1.0
    local baseOpacity = opts.opacity or 0.7

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
            -- Process each bezier curve in the letter
            for _, curve in ipairs(letter) do
                -- Map control points from [0,1] to canvas coords
                local p0 = {cursorX + padX + curve[1][1] * innerW, oy + padY + curve[1][2] * innerH}
                local p1 = {cursorX + padX + curve[2][1] * innerW, oy + padY + curve[2][2] * innerH}
                local p2 = {cursorX + padX + curve[3][1] * innerW, oy + padY + curve[3][2] * innerH}
                local p3 = {cursorX + padX + curve[4][1] * innerW, oy + padY + curve[4][2] * innerH}

                -- Sample points along the bezier
                local samples = sampleBezier(p0, p1, p2, p3, 40)

                -- Walk consecutive samples to scatter ants
                for j = 1, #samples - 1 do
                    local a = samples[j]
                    local b = samples[j + 1]
                    local dx, dy = b[1] - a[1], b[2] - a[2]
                    local segLen = math.sqrt(dx * dx + dy * dy)
                    if segLen > 0 then
                        local nx, ny = -dy / segLen, dx / segLen
                        local count = math.max(1, math.floor(segLen * density + 0.5))
                        for _ = 1, count do
                            local t = gen.rand()
                            local px = gen.lerp(a[1], b[1], t)
                            local py = gen.lerp(a[2], b[2], t)
                            local off = (gen.randRange(-spread, spread)
                                       + gen.randRange(-spread, spread)) * 0.5
                            px = px + nx * off
                            py = py + ny * off
                            local r = dotRadius * gen.randRange(0.5, 1.2)
                            local op = baseOpacity * gen.randRange(0.4, 1.0)
                            gen.draw(canvas, gen.circle({px, py}, r), {
                                fill = color,
                                opacity = op,
                            })
                        end
                    end
                end
            end
        end
        cursorX = cursorX + cellW
    end

    return cursorX
end

return M
