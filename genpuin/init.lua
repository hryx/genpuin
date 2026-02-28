local geo = require("genpuin.geo")
local color = require("genpuin.color")
local canvas = require("genpuin.canvas")
local svg = require("genpuin.svg")
local Pen = require("genpuin.pen")
local rand = require("genpuin.rand")
local xform = require("genpuin.xform")
local util = require("genpuin.util")
local noise = require("genpuin.noise")
local field = require("genpuin.field")
local pattern = require("genpuin.pattern")
local fx = require("genpuin.fx")
local ppm = require("genpuin.ppm")
local gradient = require("genpuin.gradient")
local voronoi = require("genpuin.voronoi")
local spatial = require("genpuin.spatial")

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
gen.background = canvas.background
gen.draw = canvas.draw
gen.style = canvas.style
gen.layer = canvas.layer

-- svg
gen.exportSvg = svg.exportSvg

-- ppm
gen.exportPpm = ppm.exportPpm

-- gradient
gen.linearGradient = gradient.linearGradient
gen.radialGradient = gradient.radialGradient

-- pen
gen.pen = Pen.new

-- rand
gen.seed = rand.seed
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
gen.perlin = noise.perlin
gen.fbm = noise.fbm
gen.noiseSeed = noise.seed

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

-- util
gen.lerp = util.lerp
gen.mapRange = util.mapRange
gen.clamp = util.clamp
gen.dist = util.dist
gen.angle = util.angle
gen.norm = util.norm
gen.degrees = util.degrees
gen.radians = util.radians

return gen
