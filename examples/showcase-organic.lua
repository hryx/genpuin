-- showcase-organic.lua — Noise, flow fields, FX effects
-- Demonstrates: perlin, fbm, noiseField, trace, jitter, smooth,
-- taper, stipple, subdivide, sampleAlong, resample

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#faf3e8"))
gen.seed(42)
gen.noiseSeed(42)

-- === Top-left: Flow field streamlines (noiseField + trace) ===

local f = gen.noiseField(0.005)
for i = 1, 120 do
    local x = gen.randRange(20, W / 2 - 20)
    local y = gen.randRange(20, H / 2 - 20)
    local trail = gen.trace(f, {x, y}, 60, 2)
    local hue = gen.perlin(x * 0.004, y * 0.004) * 0.5 + 0.5
    gen.draw(c, trail, {
        stroke = gen.hsv(hue, 0.5, 0.7),
        strokeWidth = 0.8,
        opacity = 0.6,
        strokeLinecap = "round",
    })
end

-- === Top-right: Stippled polygon ===

local triPts = {
    {W / 2 + 100, H / 2 - 30},
    {W / 2 + 200, H / 2 - 180},
    {W / 2 + 300, H / 2 - 30},
}
local tri = gen.polygon(triPts)
local dots = gen.stipple(tri, 0.06)
for _, d in ipairs(dots) do
    gen.draw(c, gen.circle(d, 1.2), {
        fill = gen.rgba(60 / 255, 40 / 255, 30 / 255, 0.6),
    })
end

-- Subdivided + smoothed organic blob below the triangle
local hexPts = {}
for i = 0, 5 do
    local angle = (i / 6) * 2 * math.pi
    local r = 60 + gen.randRange(-12, 12)
    hexPts[#hexPts + 1] = {
        W / 2 + 200 + r * math.cos(angle),
        130 + r * math.sin(angle),
    }
end
local blob = gen.smooth(gen.subdivide(gen.polygon(hexPts), 3), 3)
gen.draw(c, blob, {
    stroke = gen.hex("#4a6fa5"),
    strokeWidth = 2,
    fill = gen.rgba(74 / 255, 111 / 255, 165 / 255, 0.15),
})

-- === Bottom-left: Jitter + smooth + taper ===

-- Jittered + smoothed wobbly curve
local pts = {}
for i = 0, 24 do
    pts[#pts + 1] = {40 + i * 15, H / 2 + 80 + 60 * math.sin(i * 0.35)}
end
local curve = gen.polyline(pts)
local wobbly = gen.smooth(gen.jitter(curve, 6), 3)
gen.draw(c, wobbly, {
    stroke = gen.hex("#2a5c3f"),
    strokeWidth = 2,
    fill = "none",
    strokeLinecap = "round",
})

-- Tapered brush stroke
local brushPts = {}
for i = 0, 30 do
    local t = i / 30
    brushPts[#brushPts + 1] = {
        40 + t * 350,
        H / 2 + 200 + 30 * math.sin(t * math.pi * 2.5),
    }
end
local brushPath = gen.polyline(brushPts)
local segments = gen.taper(brushPath, 8, 0.5, 40)
for _, seg in ipairs(segments) do
    gen.draw(c, seg.shape, {
        stroke = gen.hex("#8b4513"),
        strokeWidth = seg.width,
        fill = "none",
        strokeLinecap = "round",
    })
end

-- === Bottom-right: sampleAlong + resample + FBM terrain profile ===

-- FBM terrain profile
local terrainPts = {}
for i = 0, 60 do
    local x = W / 2 + 20 + i * 5
    local elevation = gen.fbm(x * 0.008, 3.0, 4, 0.5)
    terrainPts[#terrainPts + 1] = {x, H / 2 + 160 - elevation * 80}
end
local terrain = gen.polyline(terrainPts)

-- Draw the raw terrain in faint gray
gen.draw(c, terrain, {
    stroke = gen.hex("#cccccc"), strokeWidth = 1, fill = "none",
})

-- Resample to fewer, evenly-spaced points
local resampled = gen.resample(terrain, 20)
gen.draw(c, resampled, {
    stroke = gen.hex("#8844aa"), strokeWidth = 2.5, fill = "none",
    strokeLinecap = "round",
})

-- sampleAlong: place dots along the resampled path
local along = gen.sampleAlong(resampled, 20)
for _, pt in ipairs(along) do
    gen.draw(c, gen.circle(pt, 3), {fill = gen.hex("#cc4444")})
end

-- FBM contour fill at bottom
for i = 1, 150 do
    local x = gen.randRange(W / 2 + 20, W - 20)
    local y = gen.randRange(H / 2 + 200, H - 30)
    local n = gen.fbm(x * 0.006, y * 0.006, 3, 0.5)
    local r = 1.5 + n * 2
    local hue = 0.08 + n * 0.12
    gen.draw(c, gen.circle({x, y}, r), {
        fill = gen.hsv(hue, 0.4, 0.6),
        opacity = 0.5,
    })
end

return c
