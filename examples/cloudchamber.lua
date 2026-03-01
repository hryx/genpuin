-- cloudchamber.lua — Particle tracks in a cloud chamber
-- Demonstrates: turtle walk, jitter, compound shape mask, fbm grain

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
local bg = gen.hex("#000000")
gen.background(c, bg)
gen.seed(31)

local cx, cy = W / 2, H / 2
local rimR = 370

-- === Utility: draw a single particle track ===
local function track(startX, startY, heading, steps, stepLen, curvature, wobble, width)
    local pts = {}
    local x, y = startX, startY
    for i = 0, steps do
        pts[#pts + 1] = {x, y}
        x = x + stepLen * math.cos(heading)
        y = y + stepLen * math.sin(heading)
        heading = heading + curvature + gen.randRange(-wobble, wobble)
    end
    local shape = gen.jitter(gen.polyline(pts), 0.4)
    shape.points[1] = {startX, startY}
    gen.draw(c, shape, {
        stroke = gen.hsv(0, 0, 0.6),
        strokeWidth = width,
        strokeLinecap = "round",
        strokeLinejoin = "round",
        opacity = 0.15,
    })
    return pts
end

-- === Utility: burnout splotch at the end of a track ===
local function burnout(pts, radius)
    local ep = pts[#pts]
    radius = radius or 3
    gen.draw(c, gen.circle(ep, radius), {
        fill = gen.hsv(0, 0, 0.85),
        opacity = gen.randRange(0.15, 0.3),
    })
    local nDots = gen.randInt(3, 6)
    for i = 1, nDots do
        local dx = gen.randRange(-radius, radius)
        local dy = gen.randRange(-radius, radius)
        local r = gen.randRange(0.3, radius * 0.5)
        gen.draw(c, gen.circle({ep[1] + dx, ep[2] + dy}, r), {
            fill = gen.hsv(0, 0, 0.95),
            opacity = gen.randRange(0.4, 0.8),
        })
    end
end

-- === Utility: condensation droplets along a track ===
-- spacing: average pixels between dots (lower = denser)
local function droplets(pts, spacing, maxR)
    for i, pt in ipairs(pts) do
        local prob = 0
        if i > 1 then
            local dx = pt[1] - pts[i-1][1]
            local dy = pt[2] - pts[i-1][2]
            local segLen = math.sqrt(dx * dx + dy * dy)
            prob = segLen / spacing
        end
        if gen.rand() < prob then
            local r = gen.randRange(0.3, maxR)
            gen.draw(c, gen.circle({pt[1] + gen.randRange(-1.5, 1.5), pt[2] + gen.randRange(-1.5, 1.5)}, r), {
                fill = gen.hsv(0, 0, 0.95),
                opacity = gen.randRange(0.6, 0.95),
            })
        end
    end
end

-- === Utility: fork a secondary track from a point on a parent track ===
local function fork(parentPts, t, angleDelta, steps, stepLen, curvature, wobble, width)
    local idx = math.max(1, math.floor(t * #parentPts))
    local pt = parentPts[idx]
    local prev = parentPts[math.max(1, idx - 1)]
    local parentHeading = math.atan2(pt[2] - prev[2], pt[1] - prev[1])
    local childHeading = parentHeading + angleDelta
    return track(pt[1], pt[2], childHeading, steps, stepLen, curvature, wobble, width)
end

-- === Utility: emit a cluster of tracks from a single origin ===
local function cluster(originX, originY, nTracks)
    local allPts = {}
    for i = 1, nTracks do
        local heading = gen.randRange(0, 2 * math.pi)
        local energy = gen.randRange(0.3, 1.0)
        local steps = math.floor(gen.randRange(40, 200) * energy)
        local stepLen = gen.randRange(1.0, 2.0)
        local w = gen.randRange(0.2, 0.8) * energy
        local curv = gen.randRange(0.005, 0.04) / energy
        if gen.rand() > 0.5 then curv = -curv end
        local wobble = gen.randRange(0.003, 0.01)
        local pts = track(originX, originY, heading, steps, stepLen, curv, wobble, w)
        droplets(pts, 10, 0.8 * energy + 0.3)
        burnout(pts, 1.5 + energy * 2)
        allPts[#allPts + 1] = pts
    end
    return allPts
end

-- === Layer 1: Film grain — FBM-modulated noise across the chamber ===
-- Drawn first so it sits behind everything.
local grainStep = 3
for gx = 0, W, grainStep do
    for gy = 0, H, grainStep do
        local d = gen.dist({gx, gy}, {cx, cy})
        if d < rimR + 5 then
            local n = gen.fbm(gx * 0.03, gy * 0.03, 4, 2.0, 0.5)
            local brightness = 0.06 + (n + 1) * 0.04
            gen.draw(c, gen.circle({gx + gen.randRange(-1, 1), gy + gen.randRange(-1, 1)}, gen.randRange(0.5, 1.5)), {
                fill = gen.hsv(0, 0, brightness),
                opacity = gen.randRange(0.3, 0.7),
            })
        end
    end
end

-- === Layer 2: Faint circular chamber border ===
local rimPts = {}
local rimN = 200
for i = 0, rimN - 1 do
    local a = (i / rimN) * 2 * math.pi
    rimPts[#rimPts + 1] = {cx + rimR * math.cos(a), cy + rimR * math.sin(a)}
end
local rim = gen.jitter(gen.polygon(rimPts), 1.2)
gen.draw(c, rim, {
    stroke = gen.hsv(0, 0, 0.2),
    strokeWidth = 1.5,
    opacity = 0.3,
    strokeLinecap = "round",
})

-- === Layer 3: Background fog — faint scattered dots ===
for _ = 1, 600 do
    local px = gen.randRange(cx - 360, cx + 360)
    local py = gen.randRange(cy - 360, cy + 360)
    local d = gen.dist({px, py}, {cx, cy})
    if d < 360 then
        local fade = 1 - d / 360
        gen.draw(c, gen.circle({px, py}, gen.randRange(0.2, 0.8)), {
            fill = gen.hsv(0, 0, 0.3),
            opacity = fade * gen.randRange(0.05, 0.15),
        })
    end
end

-- === Layer 4: Major particle tracks ===

-- Track A: long spiraling beta particle from upper-left
local ptsA = track(180, 160, 0.8, 300, 1.8, 0.008, 0.005, 0.7)
droplets(ptsA, 12, 1.2)
burnout(ptsA, 4)

-- Fork from A — decay product curving opposite, tighter
local ptsA1 = fork(ptsA, 0.35, 0.6, 120, 1.5, -0.018, 0.008, 0.4)
droplets(ptsA1, 12, 0.8)
burnout(ptsA1, 3)

-- Fork from A — second decay, short and tight
local ptsA2 = fork(ptsA, 0.35, -0.4, 40, 1.2, 0.025, 0.01, 0.25)
droplets(ptsA2, 12, 0.6)
burnout(ptsA2, 2)

-- Track B: heavy alpha particle — short, thick, nearly straight
local ptsB = track(500, 600, -1.8, 80, 2.0, 0.001, 0.003, 1.2)
droplets(ptsB, 6, 1.5)
burnout(ptsB, 5)

-- Track C: fast electron — long, gentle curve
local ptsC = track(650, 300, 3.5, 250, 1.6, -0.005, 0.003, 0.35)
droplets(ptsC, 12, 0.7)
burnout(ptsC, 2.5)

-- Track D: spiraling inward — tight curl like a low-energy particle
local ptsD = track(350, 550, -0.3, 200, 1.4, 0.025, 0.006, 0.4)
droplets(ptsD, 10, 0.9)
burnout(ptsD, 3)

-- Fork from D — even tighter
local ptsD1 = fork(ptsD, 0.2, 0.9, 60, 1.3, -0.03, 0.008, 0.25)
droplets(ptsD1, 12, 0.6)
burnout(ptsD1, 2)

-- Track E: another alpha — thick straight line from bottom
local ptsE = track(200, 680, -1.2, 60, 2.2, -0.002, 0.004, 1.0)
droplets(ptsE, 6, 1.3)
burnout(ptsE, 5)

-- Track F: grazing particle — very long, subtle curve
local ptsF = track(100, 400, 0.15, 350, 1.5, -0.003, 0.002, 0.3)
droplets(ptsF, 12, 0.6)
burnout(ptsF, 2)

-- === Layer 4b: Dense clusters — multiple tracks from same origin ===

cluster(380, 420, 6)
cluster(530, 250, 4)
cluster(250, 500, 5)

-- === Layer 5: Stray short tracks — cosmic ray debris ===
for _ = 1, 12 do
    local sx = gen.randRange(cx - 330, cx + 330)
    local sy = gen.randRange(cy - 330, cy + 330)
    local d = gen.dist({sx, sy}, {cx, cy})
    if d < 340 then
        local heading = gen.randRange(0, 2 * math.pi)
        local steps = gen.randInt(15, 50)
        local w = gen.randRange(0.15, 0.4)
        local curv = gen.randRange(-0.03, 0.03)
        local pts = track(sx, sy, heading, steps, 1.3, curv, 0.008, w)
        droplets(pts, 12, 0.5)
        burnout(pts, 1.5)
    end
end

-- === Layer 6: Long shallow arcs — high-energy particles grazing through ===
local arcs = {
    {angle = 0.3,  offset = -80, curv = 0.0015,  w = 0.5},
    {angle = 1.8,  offset =  60, curv = -0.001,   w = 0.6},
    {angle = 2.7,  offset = -40, curv = 0.0012,  w = 0.35},
}
for _, arc in ipairs(arcs) do
    local startX = cx + (rimR + 200) * math.cos(arc.angle + math.pi) + arc.offset * math.cos(arc.angle + math.pi / 2)
    local startY = cy + (rimR + 200) * math.sin(arc.angle + math.pi) + arc.offset * math.sin(arc.angle + math.pi / 2)
    local pts = track(startX, startY, arc.angle, 600, 1.8, arc.curv, 0.001, arc.w)
    droplets(pts, 12, 0.5)
end

-- === Mask: overlay with circular hole to clip to chamber ===
local rectContour = {{0, 0}, {W, 0}, {W, H}, {0, H}}
local circleContour = {}
local maskN = 200
for i = 0, maskN - 1 do
    local a = -(i / maskN) * 2 * math.pi
    circleContour[#circleContour + 1] = {cx + rimR * math.cos(a), cy + rimR * math.sin(a)}
end
gen.draw(c, gen.compound({rectContour, circleContour}), {
    fill = bg,
})

return c
