local canvas = require("genpuin.canvas")

local Pen = {}
Pen.__index = Pen

function Pen.new(c)
    return setmetatable({
        _canvas = c,
        x = 0, y = 0,
        _heading = 0,
        _color = {1, 1, 1, 1},
        _width = 1,
        _opacity = nil,
        _points = {},
    }, Pen)
end

function Pen:moveTo(pos)
    self.x, self.y = pos[1], pos[2]
    self._points = {pos}
    return self
end

function Pen:forward(dist)
    self.x = self.x + dist * math.cos(self._heading)
    self.y = self.y + dist * math.sin(self._heading)
    table.insert(self._points, {self.x, self.y})
    return self
end

function Pen:forwardTo(pos)
    self.x, self.y = pos[1], pos[2]
    table.insert(self._points, {self.x, self.y})
    return self
end

function Pen:turn(angle)
    self._heading = self._heading + angle
    return self
end

function Pen:heading(angle)
    if angle then
        self._heading = angle
        return self
    end
    return self._heading
end

function Pen:stroke()
    if #self._points > 1 then
        local segs = {}
        table.insert(segs, string.format("M %.2f %.2f",
            self._points[1][1], self._points[1][2]))
        for i = 2, #self._points do
            table.insert(segs, string.format("L %.2f %.2f",
                self._points[i][1], self._points[i][2]))
        end
        local style = {
            stroke = self._color,
            strokeWidth = self._width,
            strokeLinecap = "round",
        }
        if self._opacity then style.opacity = self._opacity end
        canvas.draw(self._canvas,
            {type = "path", d = table.concat(segs, " ")},
            style)
    end
    self._points = {{self.x, self.y}}
    return self
end

function Pen:lift()
    self._points = {{self.x, self.y}}
    return self
end

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
    end
    return self
end

function Pen:pos()
    return {self.x, self.y}
end

return Pen
