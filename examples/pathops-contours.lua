-- pathops-contours.lua: an archipelago in contour lines.
-- Islands are a smooth union of distance blobs, roughened with fbm noise
-- in a Field, and marching squares traces the height as plotter lines.

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#efe9dc"))
gen.seed(11)
gen.noiseSeed(11)

-- Islands: soft blobs and a ridge, blended with a wide smooth union.
local blobs = gen.sdCircle({300, 340}, 120)
for _ = 1, 9 do
    local p = {gen.randRange(140, 660), gen.randRange(140, 660)}
    blobs = gen.sdSmoothUnion(blobs, gen.sdCircle(p, gen.randRange(30, 90)), 90)
end
blobs = gen.sdSmoothUnion(blobs, gen.sdSegment({420, 560}, {640, 420}, 40), 80)

local cols, rows = 200, 200
local rect = {0, 0, W, H}
local height = gen.sdfField(blobs, {rect = rect, cols = cols, rows = rows})
height:map(function(v) return -v / 140 end)

local noise = gen.field(cols, rows)
noise:fill(function(x, y) return gen.fbm(x * 0.03, y * 0.03, 5, 2.0, 0.5) end)
height:combine("add", noise:map(function(v) return v * 0.45 end))

-- Water lines below sea level, land lines above, every fifth one heavier.
local ink = gen.hex("#22313f")
local sea = gen.hex("#4a7a96")
local levels = {}
for i = -12, 20 do levels[#levels + 1] = i * 0.06 end
for _, line in ipairs(gen.contours(height, levels, {rect = rect, simplify = 0.3})) do
    local k = math.floor(line.level / 0.06 + 0.5)
    local major = k % 5 == 0
    local style
    if line.level < 0 then
        style = {stroke = sea, strokeWidth = 0.7, strokeOpacity = 0.7}
    else
        style = {stroke = ink, strokeWidth = major and 1.6 or 0.8}
    end
    if k == 0 then style = {stroke = ink, strokeWidth = 2.2} end
    gen.draw(c, line, style)
end

-- A dashed survey grid masked to the water, kept off the land.
local coast = {}
for _, l in ipairs(gen.contours(height, 0, {rect = rect})) do
    if l.closed then coast[#coast + 1] = l end
end
local land = gen.offset(gen.clip(coast, nil, "union"), 6)
local grid = {}
for x = 100, 700, 100 do grid[#grid + 1] = gen.line({x, 40}, {x, 760}) end
for y = 100, 700, 100 do grid[#grid + 1] = gen.line({40, y}, {760, y}) end
for _, l in ipairs(gen.clipLines(grid, land, {outside = true})) do
    gen.draw(c, l, {stroke = sea, strokeWidth = 0.9, strokeDasharray = {6, 5}})
end

return c
