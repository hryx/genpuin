-- 2D Perlin noise (improved, Ken Perlin 2002)

local M = {}

-- Permutation table (doubled to avoid wrapping)
local perm = {}
local grad = {
    {1, 1}, {-1, 1}, {1, -1}, {-1, -1},
    {1, 0}, {-1, 0}, {0, 1}, {0, -1},
}

-- Initialize permutation table with a seed
local function initPerm(seed)
    local p = {}
    for i = 0, 255 do p[i] = i end
    -- Fisher-Yates shuffle using simple LCG seeded from seed
    local s = seed
    for i = 255, 1, -1 do
        s = (s * 1103515245 + 12345) % 0x7FFFFFFF
        local j = s % (i + 1)
        p[i], p[j] = p[j], p[i]
    end
    for i = 0, 511 do
        perm[i] = p[i % 256]
    end
end

-- Default init
initPerm(0)

local function fade(t)
    return t * t * t * (t * (t * 6 - 15) + 10)
end

local function dot2(g, x, y)
    return g[1] * x + g[2] * y
end

-- Seed the noise permutation table.
function M.seed(n)
    initPerm(n)
end

-- 2D Perlin noise, returns a value in approximately [-1, 1].
function M.perlin(x, y)
    local xi = math.floor(x) % 256
    local yi = math.floor(y) % 256
    local xf = x - math.floor(x)
    local yf = y - math.floor(y)

    local u = fade(xf)
    local v = fade(yf)

    local aa = perm[perm[xi] + yi] % 8 + 1
    local ab = perm[perm[xi] + yi + 1] % 8 + 1
    local ba = perm[perm[xi + 1] + yi] % 8 + 1
    local bb = perm[perm[xi + 1] + yi + 1] % 8 + 1

    local x1 = dot2(grad[aa], xf, yf) * (1 - u) + dot2(grad[ba], xf - 1, yf) * u
    local x2 = dot2(grad[ab], xf, yf - 1) * (1 - u) + dot2(grad[bb], xf - 1, yf - 1) * u

    return x1 * (1 - v) + x2 * v
end

-- Fractal Brownian motion (layered Perlin noise).
function M.fbm(x, y, octaves, lacunarity, gain)
    octaves = octaves or 6
    lacunarity = lacunarity or 2.0
    gain = gain or 0.5
    local sum = 0
    local amp = 1
    local freq = 1
    local maxAmp = 0
    for i = 1, octaves do
        sum = sum + M.perlin(x * freq, y * freq) * amp
        maxAmp = maxAmp + amp
        amp = amp * gain
        freq = freq * lacunarity
    end
    return sum / maxAmp
end

return M
