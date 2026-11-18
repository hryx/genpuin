local import = ...
local algo = import("core").algo
local canvas = import("canvas")
local geo = import("geo")
local xform = import("xform")

local Pen = {}
Pen.__index = Pen

-- Create a new pen. It draws onto the canvas.
function Pen.new(...)
    if select("#", ...) > 0 then
        canvas.rejectCanvasArg("gen.pen", nil, true, "gen.pen()")
    end
    return setmetatable({
        x = 0, y = 0,
        _heading = 0,
        _color = {1, 1, 1, 1},
        _width = 1,
        _opacity = nil,
        _dash = nil,
        _blendMode = nil,
        _points = {},
        _hasArcs = false,
    }, Pen)
end

-- Move the pen to a position without drawing.
function Pen:moveTo(pos)
    self.x, self.y = pos[1], pos[2]
    self._points = {pos}
    self._hasArcs = false
    return self
end

-- Move forward by dist in the current heading direction.
function Pen:forward(dist)
    self.x = self.x + dist * math.cos(self._heading)
    self.y = self.y + dist * math.sin(self._heading)
    table.insert(self._points, {self.x, self.y})
    return self
end

-- Move to a position, extending the current path.
function Pen:forwardTo(pos)
    self.x, self.y = pos[1], pos[2]
    table.insert(self._points, {self.x, self.y})
    return self
end

-- Turn the heading by angle radians.
function Pen:turn(angle)
    self._heading = self._heading + angle
    return self
end

-- Get or set the heading angle. With no argument, returns the current heading.
function Pen:heading(angle)
    if angle then
        self._heading = angle
        return self
    end
    return self._heading
end

-- Copy points into a plain {x,y} array (strips arc metadata)
local function copyPoints(points)
    local pts = {}
    for i, pt in ipairs(points) do
        pts[i] = {pt[1], pt[2]}
    end
    return pts
end

-- Points with each arc replaced by arcResolution samples (default 16).
local function flattenPoints(points, arcResolution)
    return algo.penFlatten(points, arcResolution or 16)
end

-- Draw the accumulated path and reset. Returns the polyline shape.
function Pen:stroke()
    if #self._points < 2 then
        self._points = {{self.x, self.y}}
        self._hasArcs = false
        return nil
    end
    local shape
    if self._hasArcs then
        shape = geo.polyline(flattenPoints(self._points))
    else
        shape = geo.polyline(copyPoints(self._points))
    end
    local style = {
        stroke = self._color,
        strokeWidth = self._width,
        strokeLinecap = "round",
    }
    if self._opacity then style.opacity = self._opacity end
    if self._dash then style.strokeDasharray = self._dash end
    if self._blendMode then style.blendMode = self._blendMode end
    canvas.add(shape, style)
    self._points = {{self.x, self.y}}
    self._hasArcs = false
    return shape
end

-- Discard the current path without drawing.
function Pen:lift()
    self._points = {{self.x, self.y}}
    self._hasArcs = false
    return self
end

-- Return the current path as a polyline shape without drawing.
function Pen:toShape()
    if #self._points < 2 then return nil end
    return geo.polyline(copyPoints(self._points))
end

-- Return the path as a polyline, flattening any arcs.
function Pen:toPolyline(arcResolution)
    if #self._points < 2 then return nil end
    if not self._hasArcs then
        return geo.polyline(copyPoints(self._points))
    end
    return geo.polyline(flattenPoints(self._points, arcResolution))
end

-- Draw a shape at the pen's current position.
function Pen:stamp(shape, style)
    local placed = xform.translate(shape, self.x, self.y)
    if not style then
        style = {
            stroke = self._color,
            strokeWidth = self._width,
            strokeLinecap = "round",
        }
        if self._opacity then style.opacity = self._opacity end
    end
    canvas.add(placed, style)
    return self
end

-- Return individual line segments of the current path.
-- Each segment has shape, index, and t (normalized position).
function Pen:segments()
    local segs = {}
    local n = #self._points
    if n < 2 then return segs end
    local denom = math.max(n - 2, 1)
    for i = 2, n do
        local a, b = self._points[i-1], self._points[i]
        segs[#segs + 1] = {
            shape = geo.line({a[1], a[2]}, {b[1], b[2]}),
            index = i - 1,
            t = (i - 2) / denom,
        }
    end
    return segs
end

-- Extend the path with a circular arc of the given angle and radius.
function Pen:arcTo(angle, radius)
    local sign = angle >= 0 and 1 or -1
    local perpAngle = self._heading + sign * math.pi / 2
    local cx = self.x + radius * math.cos(perpAngle)
    local cy = self.y + radius * math.sin(perpAngle)
    local dx, dy = self.x - cx, self.y - cy
    local startAngle = math.atan2(dy, dx)
    local cosA, sinA = math.cos(angle), math.sin(angle)
    self.x = cx + dx * cosA - dy * sinA
    self.y = cy + dx * sinA + dy * cosA
    self._heading = self._heading + angle
    self._hasArcs = true
    -- An arc's end point carries the arc for flattening.
    table.insert(self._points, {
        self.x, self.y, cx, cy, radius,
        startAngle, math.atan2(self.y - cy, self.x - cx),
    })
    return self
end

-- Set a pen property. Flushes the current path if it has points.
-- Keys: "color", "width", "opacity", "dash", "blendMode".
function Pen:set(key, value)
    if key == "color" then
        if #self._points > 1 then self:stroke() end
        self._color = value
    elseif key == "width" then
        if #self._points > 1 then self:stroke() end
        self._width = value
    elseif key == "opacity" then
        if #self._points > 1 then self:stroke() end
        self._opacity = value
    elseif key == "dash" then
        if #self._points > 1 then self:stroke() end
        self._dash = value
    elseif key == "blendMode" then
        if #self._points > 1 then self:stroke() end
        self._blendMode = value
    end
    return self
end

-- Return the pen's current position as {x, y}.
function Pen:pos()
    return {self.x, self.y}
end

return Pen
