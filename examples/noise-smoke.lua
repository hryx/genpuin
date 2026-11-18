-- Incense smoke rising and coming apart in curl noise eddies.
-- Shows gen.curl and gen.taper.

gen.seed(4)
gen.noiseSeed(4)
local W, H = 800, 800
gen.canvas(W, H)
gen.background(gen.hex("#1f2b2e"))

local baseX, baseY = 400, 720
local function step(x, y, z)
    local rise = gen.clamp((baseY - y) / 420, 0, 1)
    local cx, cy = gen.curl(x, y, {scale = 0.003, octaves = 2, z = z})
    local len = math.sqrt(cx * cx + cy * cy) + 1e-9
    local swirl = 0.15 + 1.6 * rise * rise
    local dx = cx / len * swirl
    local dy = cy / len * swirl - 1
    return dx, dy
end

local warm, cool = gen.hex("#f1e6d2"), gen.hex("#a9c4cf")
for i = 1, 260 do
    local x, y = baseX + gen.gaussian(0, 1.5), baseY
    local pts = {{x, y}}
    local n = gen.randInt(300, 700)
    for _ = 1, n do
        local dx, dy = step(x, y, i * 0.004)
        if dx * dx + dy * dy < 0.1 then break end
        x, y = x + dx * 1.5, y + dy * 1.5
        pts[#pts + 1] = {x, y}
    end
    local segs = gen.taper(gen.polyline(pts), 1.6, 0.1)
    for k, seg in ipairs(segs) do
        local tint = gen.lerpColor(warm, cool, k / #segs)
        gen.draw(seg.shape, {stroke = tint, strokeWidth = seg.width, strokeOpacity = 0.12})
    end
end
gen.draw(gen.line({baseX, baseY}, {baseX - 30, 800}), {stroke = gen.hex("#6b4a3a"), strokeWidth = 4})
gen.draw(gen.circle({baseX, baseY}, 2.5), {fill = gen.hex("#e0703a")})
gen.post.grain({amount = 0.04})
