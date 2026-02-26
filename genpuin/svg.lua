local color = require("genpuin.color")
local geo = require("genpuin.geo")

local M = {}

local function fmt(n)
    return string.format("%.2f", n)
end

local function styleAttrs(s)
    local parts = {}
    if s.fill then
        table.insert(parts, string.format('fill="%s"', color.toSvg(s.fill)))
    else
        table.insert(parts, 'fill="none"')
    end
    if s.stroke then
        table.insert(parts, string.format('stroke="%s"', color.toSvg(s.stroke)))
    end
    if s.strokeWidth then
        table.insert(parts, string.format('stroke-width="%s"', fmt(s.strokeWidth)))
    end
    if s.opacity then
        table.insert(parts, string.format('opacity="%s"', fmt(s.opacity)))
    end
    if s.strokeLinecap then
        table.insert(parts, string.format('stroke-linecap="%s"', s.strokeLinecap))
    end
    if s.fillOpacity then
        table.insert(parts, string.format('fill-opacity="%s"', fmt(s.fillOpacity)))
    end
    if s.strokeOpacity then
        table.insert(parts, string.format('stroke-opacity="%s"', fmt(s.strokeOpacity)))
    end
    if s.strokeDasharray then
        local dashes = {}
        for _, v in ipairs(s.strokeDasharray) do
            dashes[#dashes + 1] = fmt(v)
        end
        table.insert(parts, string.format('stroke-dasharray="%s"', table.concat(dashes, " ")))
    end
    if s.strokeDashoffset then
        table.insert(parts, string.format('stroke-dashoffset="%s"', fmt(s.strokeDashoffset)))
    end
    return table.concat(parts, " ")
end

local function pointsToD(points, closed)
    local segs = {}
    table.insert(segs, string.format("M %s %s", fmt(points[1][1]), fmt(points[1][2])))
    for i = 2, #points do
        table.insert(segs, string.format("L %s %s", fmt(points[i][1]), fmt(points[i][2])))
    end
    if closed then table.insert(segs, "Z") end
    return table.concat(segs, " ")
end

local function renderShape(sh, attrs)
    if sh.type == "ellipse" then
        return string.format('  <ellipse cx="%s" cy="%s" rx="%s" ry="%s" %s/>',
            fmt(sh.center[1]), fmt(sh.center[2]), fmt(sh.rx), fmt(sh.ry), attrs)

    elseif sh.type == "circle" then
        return string.format('  <circle cx="%s" cy="%s" r="%s" %s/>',
            fmt(sh.center[1]), fmt(sh.center[2]), fmt(sh.r), attrs)

    elseif sh.type == "line" then
        return string.format('  <line x1="%s" y1="%s" x2="%s" y2="%s" %s/>',
            fmt(sh.a[1]), fmt(sh.a[2]), fmt(sh.b[1]), fmt(sh.b[2]), attrs)

    elseif sh.type == "rect" then
        local rAttrs = ""
        if sh.rx then rAttrs = rAttrs .. string.format(' rx="%s"', fmt(sh.rx)) end
        if sh.ry then rAttrs = rAttrs .. string.format(' ry="%s"', fmt(sh.ry)) end
        return string.format('  <rect x="%s" y="%s" width="%s" height="%s"%s %s/>',
            fmt(sh.x), fmt(sh.y), fmt(sh.w), fmt(sh.h), rAttrs, attrs)

    elseif sh.type == "polyline" then
        return string.format('  <path d="%s" %s/>', pointsToD(sh.points, false), attrs)

    elseif sh.type == "polygon" then
        return string.format('  <path d="%s" %s/>', pointsToD(sh.points, true), attrs)

    elseif sh.type == "arc" then
        local sa, ea = sh.startAngle, sh.endAngle
        local cx, cy, r = sh.center[1], sh.center[2], sh.r
        local x1 = cx + r * math.cos(sa)
        local y1 = cy + r * math.sin(sa)
        local x2 = cx + r * math.cos(ea)
        local y2 = cy + r * math.sin(ea)
        local diff = ea - sa
        local large = (math.abs(diff) > math.pi) and 1 or 0
        local sweep = (diff > 0) and 1 or 0
        local d = string.format("M %s %s A %s %s 0 %d %d %s %s",
            fmt(x1), fmt(y1), fmt(r), fmt(r), large, sweep, fmt(x2), fmt(y2))
        return string.format('  <path d="%s" %s/>', d, attrs)

    elseif sh.type == "bezier" then
        local d = string.format("M %s %s C %s %s, %s %s, %s %s",
            fmt(sh.p0[1]), fmt(sh.p0[2]),
            fmt(sh.p1[1]), fmt(sh.p1[2]),
            fmt(sh.p2[1]), fmt(sh.p2[2]),
            fmt(sh.p3[1]), fmt(sh.p3[2]))
        return string.format('  <path d="%s" %s/>', d, attrs)

    elseif sh.type == "spline" then
        local segs = geo.splineToBeziers(sh.points)
        if #segs == 0 then return nil end
        local parts = {}
        local b = segs[1]
        table.insert(parts, string.format("M %s %s", fmt(b[1][1]), fmt(b[1][2])))
        for _, b in ipairs(segs) do
            table.insert(parts, string.format("C %s %s, %s %s, %s %s",
                fmt(b[2][1]), fmt(b[2][2]),
                fmt(b[3][1]), fmt(b[3][2]),
                fmt(b[4][1]), fmt(b[4][2])))
        end
        return string.format('  <path d="%s" %s/>', table.concat(parts, " "), attrs)
    end
end

local function renderElements(elements, parts)
    for _, elem in ipairs(elements) do
        local attrs = styleAttrs(elem.style)
        local line = renderShape(elem.shape, attrs)
        if line then table.insert(parts, line) end
    end
end

function M.exportSvg(c, filename)
    local parts = {}
    table.insert(parts, string.format(
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">',
        c.width, c.height, c.width, c.height))

    if c.bg then
        table.insert(parts, string.format(
            '  <rect width="%d" height="%d" fill="%s"/>',
            c.width, c.height, color.toSvg(c.bg)))
    end

    for _, layer in ipairs(c.layers) do
        table.insert(parts, string.format('  <g id="%s">', layer.name))
        renderElements(layer.elements, parts)
        table.insert(parts, '  </g>')
    end

    renderElements(c.elements, parts)

    table.insert(parts, '</svg>')

    local dir = filename:match("(.+)/[^/]+$")
    if dir then os.execute('mkdir -p "' .. dir .. '"') end

    local f, err = io.open(filename, "w")
    if not f then error("cannot write " .. filename .. ": " .. err) end
    f:write(table.concat(parts, "\n"))
    f:write("\n")
    f:close()
end

return M
