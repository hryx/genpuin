local import = ...
local geo = import("geo")
local color = import("color")
local canvas = import("canvas")
local svg = import("svg")
local Pen = import("pen")
local rand = import("rand")
local xform = import("xform")
local util = import("util")
local noise = import("noise")
local field = import("field")
local pattern = import("pattern")
local fx = import("fx")
local raster = import("raster")
local gradient = import("gradient")
local voronoi = import("voronoi")
local spatial = import("spatial")
local lsystem = import("lsystem")
local automata = import("automata")
local markov = import("markov")

local gen = {}

-- geo
gen.vec2 = geo.vec2
gen.vec2Add = geo.vec2Add
gen.vec2Sub = geo.vec2Sub
gen.vec2Scale = geo.vec2Scale
gen.vec2Len = geo.vec2Len
gen.vec2FromAngle = geo.vec2FromAngle
gen.vec2Dot = geo.vec2Dot
gen.vec2Lerp = geo.vec2Lerp
gen.vec2Rotate = geo.vec2Rotate
gen.line = geo.line
gen.polyline = geo.polyline
gen.polygon = geo.polygon
gen.circle = geo.circle
gen.ellipse = geo.ellipse
gen.arc = geo.arc
gen.rect = geo.rect
gen.bezier = geo.bezier
gen.bezierPoint = geo.bezierPoint
gen.bezierTangent = geo.bezierTangent
gen.spline = geo.spline
gen.compound = geo.compound
gen.catmullRomToBezier = geo.catmullRomToBezier
gen.splineToBeziers = geo.splineToBeziers

-- color
gen.rgb = color.rgb
gen.rgba = color.rgba
gen.hsv = color.hsv
gen.hsl = color.hsl
gen.hex = color.hex
gen.lerpColor = color.lerpColor
gen.darken = color.darken
gen.lighten = color.lighten
gen.withAlpha = color.withAlpha

-- canvas
gen.canvas = canvas.canvas
gen.size = canvas.size
gen.background = canvas.background
gen.draw = canvas.draw
gen.style = canvas.style
gen.layer = canvas.layer

-- svg
gen.exportSvg = svg.exportSvg

-- raster
gen.exportPpm = raster.exportPpm
gen.exportPng = raster.exportPng
gen.field = raster.field
gen.image = raster.image
gen.post = raster.post

-- gradient
gen.linearGradient = gradient.linearGradient
gen.radialGradient = gradient.radialGradient

-- pen
gen.pen = Pen.new

-- rand
gen.seed = rand.seed
gen.mixSeed = rand.mixSeed
gen.rand = rand.rand
gen.randRange = rand.randRange
gen.randInt = rand.randInt
gen.gaussian = rand.gaussian
gen.pick = rand.pick
gen.shuffle = rand.shuffle
gen.weightedPick = rand.weightedPick
gen.randInCircle = rand.randInCircle
gen.randOnCircle = rand.randOnCircle
gen.randInRect = rand.randInRect
gen.poissonDisk = rand.poissonDisk

-- pattern
gen.grid = pattern.grid
gen.radial = pattern.radial
gen.scatter = pattern.scatter
gen.spiral = pattern.spiral
gen.alongPath = pattern.alongPath
gen.subdivideRect = pattern.subdivideRect
gen.kaleidoscope = pattern.kaleidoscope
gen.GOLDEN_ANGLE = pattern.GOLDEN_ANGLE

-- xform
gen.translate = xform.translate
gen.rotate = xform.rotate
gen.rotateAround = xform.rotateAround
gen.scale = xform.scale
gen.scaleAround = xform.scaleAround
gen.reflectX = xform.reflectX
gen.reflectY = xform.reflectY
gen.reflect = xform.reflect

-- noise
gen.noiseSeed = noise.seed
gen.perlin = noise.perlin
gen.fbm = noise.fbm
gen.simplex = noise.simplex
gen.valueNoise = noise.valueNoise
gen.worley = noise.worley
gen.curl = noise.curl
gen.curlFlow = noise.curlFlow
gen.noiseGrid = noise.noiseGrid

-- field
gen.flowField = field.flowField
gen.noiseField = field.noiseField
gen.trace = field.trace

-- path ops
gen.sampleAlong = geo.sampleAlong
gen.subdivide = geo.subdivide
gen.resample = geo.resample

-- fx
gen.jitter = fx.jitter
gen.smooth = fx.smooth
gen.taper = fx.taper
gen.stipple = fx.stipple
gen.dash = fx.dash

-- voronoi
gen.voronoi = voronoi.voronoi
gen.relax = voronoi.relax

-- spatial
gen.pointInRect = spatial.pointInRect
gen.pointInCircle = spatial.pointInCircle
gen.pointInPolygon = spatial.pointInPolygon
gen.nearest = spatial.nearest
gen.withinRadius = spatial.withinRadius
gen.packCircles = spatial.packCircles
gen.separate = spatial.separate

-- lsystem
gen.rewrite = lsystem.rewrite

-- automata
gen.elementary = automata.elementary
gen.evolve = automata.step
gen.life = automata.life

-- markov
gen.markov = markov.chain
gen.markovFrom = markov.fromSequence
gen.markovStep = markov.step
gen.markovGenerate = markov.generate

-- util
gen.lerp = util.lerp
gen.mapRange = util.mapRange
gen.clamp = util.clamp
gen.dist = util.dist
gen.angle = util.angle
gen.norm = util.norm
gen.degrees = util.degrees
gen.radians = util.radians
gen.mod = util.mod

-- extension modules export everything they define
for _, name in ipairs({"texture", "sim", "pathops", "wfc"}) do
    for k, v in pairs(import(name)) do gen[k] = v end
end

return import("strict").api(gen, "gen")
