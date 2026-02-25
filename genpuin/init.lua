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

local gen = {}

-- geo
gen.vec2 = geo.vec2
gen.vec2Add = geo.vec2Add
gen.vec2Sub = geo.vec2Sub
gen.vec2Scale = geo.vec2Scale
gen.vec2Len = geo.vec2Len
gen.line = geo.line
gen.polyline = geo.polyline
gen.polygon = geo.polygon
gen.circle = geo.circle
gen.arc = geo.arc
gen.rect = geo.rect
gen.bezier = geo.bezier

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

-- xform
gen.translate = xform.translate
gen.rotate = xform.rotate
gen.rotateAround = xform.rotateAround
gen.scale = xform.scale
gen.scaleAround = xform.scaleAround
gen.reflectX = xform.reflectX
gen.reflectY = xform.reflectY

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

-- util
gen.lerp = util.lerp
gen.mapRange = util.mapRange
gen.clamp = util.clamp
gen.dist = util.dist
gen.angle = util.angle
gen.norm = util.norm

return gen
