-- penrose.lua — Penrose P3 rhombus tiling in a circle

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#f0d020"))

local psi = (math.sqrt(5) - 1) / 2     -- ≈ 0.618
local psi2 = 1 - psi                    -- ≈ 0.382
local cx, cy = W / 2, H / 2
local initR = 380
local clipR = 350
local nSub = 7

-- Type 0 = BtileL: obtuse Robinson triangle (108° at B, base 36° at A,C)
-- Type 1 = BtileS: acute Robinson triangle (36° at B, base 72° at A,C)

local thickFill = gen.hex("#2060a0")    -- blue (thick rhombus)
local thinFill = gen.hex("#d04838")     -- red (thin rhombus)

-- Initial star: 10 BtileS with 36° apex B at center, A and C on perimeter
-- (Matches Preshing's "wheel" configuration: 10 × 36° = 360°)
local tris = {}
for i = 0, 9 do
    local a_angle = (2 * i - 1) * math.pi / 10
    local c_angle = (2 * i + 1) * math.pi / 10
    local ax, ay = cx + initR * math.cos(a_angle), cy + initR * math.sin(a_angle)
    local cpx, cpy = cx + initR * math.cos(c_angle), cy + initR * math.sin(c_angle)
    if i % 2 == 0 then
        tris[#tris + 1] = {t = 1, a = {cpx, cpy}, b = {cx, cy}, c = {ax, ay}}
    else
        tris[#tris + 1] = {t = 1, a = {ax, ay}, b = {cx, cy}, c = {cpx, cpy}}
    end
end

-- P3 Robinson triangle subdivision
for iter = 1, nSub do
    local nxt = {}
    for _, tri in ipairs(tris) do
        local A, B, C = tri.a, tri.b, tri.c
        if tri.t == 0 then  -- BtileL → 3 children
            local D = {psi2 * A[1] + psi * C[1], psi2 * A[2] + psi * C[2]}
            local E = {psi2 * A[1] + psi * B[1], psi2 * A[2] + psi * B[2]}
            nxt[#nxt + 1] = {t = 0, a = D, b = E, c = A}
            nxt[#nxt + 1] = {t = 1, a = E, b = D, c = B}
            nxt[#nxt + 1] = {t = 0, a = C, b = D, c = B}
        else  -- BtileS → 2 children
            local D = {psi * A[1] + psi2 * B[1], psi * A[2] + psi2 * B[2]}
            nxt[#nxt + 1] = {t = 1, a = D, b = C, c = A}
            nxt[#nxt + 1] = {t = 0, a = C, b = D, c = B}
        end
    end
    tris = nxt
end

-- Pair mirror-image triangles into rhombi.
-- Two triangles of the same type sharing the same base midpoint (A+C)/2
-- form one rhombus: B1 → A → B2 → C (the two apex vertices + shared base).
local eps = 0.01
local function key(x, y)
    return string.format("%.2f,%.2f", x, y)
end

-- Group triangles by (type, base midpoint)
local buckets = {}
for _, tri in ipairs(tris) do
    local mx = (tri.a[1] + tri.c[1]) / 2
    local my = (tri.a[2] + tri.c[2]) / 2
    local k = tri.t .. ":" .. key(mx, my)
    if not buckets[k] then
        buckets[k] = {tri}
    else
        buckets[k][#buckets[k] + 1] = tri
    end
end

-- Shrink each shape toward its centroid to reveal background gaps
local shrink = 0.92

local function shrinkPoly(pts)
    local mx, my = 0, 0
    for _, p in ipairs(pts) do mx = mx + p[1]; my = my + p[2] end
    mx, my = mx / #pts, my / #pts
    local out = {}
    for _, p in ipairs(pts) do
        out[#out + 1] = {mx + (p[1] - mx) * shrink, my + (p[2] - my) * shrink}
    end
    return out, mx, my
end

-- Draw rhombi
for _, pair in pairs(buckets) do
    if #pair == 2 then
        local t1, t2 = pair[1], pair[2]
        local rhombus = {t1.b, t1.a, t2.b, t1.c}
        local shrunk, rmx, rmy = shrinkPoly(rhombus)
        local d = math.sqrt((rmx - cx) ^ 2 + (rmy - cy) ^ 2)
        if d <= clipR then
            local fillCol = t1.t == 0 and thickFill or thinFill
            gen.draw(c, gen.polygon(shrunk), {
                fill = fillCol, stroke = "none",
            })
        end
    elseif #pair == 1 then
        local tri = pair[1]
        local pts = {tri.a, tri.b, tri.c}
        local shrunk, tmx, tmy = shrinkPoly(pts)
        local d = math.sqrt((tmx - cx) ^ 2 + (tmy - cy) ^ 2)
        if d <= clipR then
            local fillCol = tri.t == 0 and thickFill or thinFill
            gen.draw(c, gen.polygon(shrunk), {
                fill = fillCol, stroke = "none",
            })
        end
    end
end

return c
