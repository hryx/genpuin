-- A wireframe cube sketched in pencil, each edge built from many noisy
-- strands. Shows gen.gaussian and gen.perlin.

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#f4f1eb"))
gen.seed(42)
gen.noiseSeed(11)

local cx, cy = 400, 380
local s = 160

-- Asymmetric isometric, rotated up and slightly right
local angleR = math.rad(22)
local angleL = math.rad(42)
local cosR, sinR = math.cos(angleR), math.sin(angleR)
local cosL, sinL = math.cos(angleL), math.sin(angleL)

local function iso(x, y, z)
    local sx = cx + x * cosR * s - y * cosL * s
    local sy = cy - z * 1.15 * s + x * sinR * s + y * sinL * s
    return {sx, sy}
end

-- Cube corners
local v = {
    A = iso(0, 0, 0),
    B = iso(1, 0, 0),
    C = iso(1, 1, 0),
    D = iso(0, 1, 0),
    E = iso(0, 0, 1),
    F = iso(1, 0, 1),
    G = iso(1, 1, 1),
    H = iso(0, 1, 1),
}

-- All 12 edges
local edges = {
    {v.A, v.B}, {v.B, v.C}, {v.C, v.D}, {v.A, v.D},
    {v.E, v.F}, {v.F, v.G}, {v.G, v.H}, {v.E, v.H},
    {v.A, v.E}, {v.B, v.F}, {v.C, v.G}, {v.D, v.H},
}

-- Draw a single edge as many sand-spline strands
local function pencilEdge(a, b, nStrands, seedBase)
    -- Extend edge beyond both endpoints for sloppy overshoot
    local overshoot = 12
    local rawDx = b[1] - a[1]
    local rawDy = b[2] - a[2]
    local rawLen = math.sqrt(rawDx * rawDx + rawDy * rawDy)
    local ux, uy = rawDx / rawLen, rawDy / rawLen
    local extA = {a[1] - ux * overshoot, a[2] - uy * overshoot}
    local extB = {b[1] + ux * overshoot, b[2] + uy * overshoot}

    local dx = extB[1] - extA[1]
    local dy = extB[2] - extA[2]
    local edgeLen = rawLen + overshoot * 2
    -- Perpendicular direction for spreading strands
    local px, py = -dy / edgeLen, dx / edgeLen

    local stepLen = 1.5
    local nSteps = math.floor(edgeLen / stepLen)
    local col = {0.18, 0.15, 0.12}

    for si = 1, nStrands do
        -- Offset perpendicular to the edge, gaussian centered on the line
        local spread = gen.gaussian(0, 1.2)
        local ox = px * spread
        local oy = py * spread

        local drift = 0
        for step = 0, nSteps do
            local t = step / nSteps
            -- Position along the extended edge
            local ex = extA[1] + dx * t + ox
            local ey = extA[2] + dy * t + oy

            -- Perpendicular noise drift
            local freq = 0.03
            local amp = 0.8
            local kick = gen.perlin((seedBase + si) * 0.1 + t * freq * edgeLen,
                                    step * freq) * amp
            drift = drift + kick * 0.3

            -- Jitter along edge direction to fill gaps + perpendicular scatter
            local alongJitter = gen.randRange(-stepLen * 0.6, stepLen * 0.6)
            local perpJitter = gen.gaussian(0, 0.6)
            local jx = ex + px * (drift + perpJitter) + (dx / edgeLen) * alongJitter + gen.randRange(-0.2, 0.2)
            local jy = ey + py * (drift + perpJitter) + (dy / edgeLen) * alongJitter + gen.randRange(-0.2, 0.2)

            local alpha = gen.randRange(0.08, 0.22)

            if alpha > 0.01 then
                gen.draw(c, gen.circle({jx, jy}, gen.randRange(0.3, 0.7)), {
                    fill = col,
                    fillOpacity = alpha,
                })
            end
        end
    end
end

-- Draw each edge
for i, edge in ipairs(edges) do
    pencilEdge(edge[1], edge[2], 40, i * 137)
end

return c
