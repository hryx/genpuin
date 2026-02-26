local geo = require("genpuin.geo")
local colormap = require("genpuin.colormap")

local M = {}

local floor = math.floor
local sqrt = math.sqrt
local abs = math.abs
local cos = math.cos
local sin = math.sin
local pi = math.pi

-- ============================================================
-- Pixel Buffer
-- ============================================================

local function clamp255(v)
    if v < 0 then return 0 elseif v > 255 then return 255 else return v end
end

local function newBuffer(w, h, r, g, b)
    local data = {}
    for i = 1, w * h do
        data[i] = {r, g, b}
    end
    return {data = data, w = w, h = h}
end

local function setPixel(buf, x, y, r, g, b, a)
    if x < 0 or x >= buf.w or y < 0 or y >= buf.h then return end
    local idx = y * buf.w + x + 1
    if buf.colorMatrix then
        local dst = buf.data[idx]
        local dr, dg, db = dst[1]/255, dst[2]/255, dst[3]/255
        local m = buf.colorMatrix
        buf.data[idx] = {
            clamp255(floor((m[1][1]*dr + m[1][2]*dg + m[1][3]*db + m[1][4]) * 255 + 0.5)),
            clamp255(floor((m[2][1]*dr + m[2][2]*dg + m[2][3]*db + m[2][4]) * 255 + 0.5)),
            clamp255(floor((m[3][1]*dr + m[3][2]*dg + m[3][3]*db + m[3][4]) * 255 + 0.5)),
        }
        return
    end
    if a >= 1.0 then
        buf.data[idx] = {r, g, b}
    else
        local dst = buf.data[idx]
        local inv = 1.0 - a
        buf.data[idx] = {
            clamp255(floor(r * a + dst[1] * inv + 0.5)),
            clamp255(floor(g * a + dst[2] * inv + 0.5)),
            clamp255(floor(b * a + dst[3] * inv + 0.5)),
        }
    end
end

-- ============================================================
-- Rasterization Primitives
-- ============================================================

local function bresenhamLine(buf, x0, y0, x1, y1, r, g, b, a)
    x0, y0 = floor(x0 + 0.5), floor(y0 + 0.5)
    x1, y1 = floor(x1 + 0.5), floor(y1 + 0.5)
    local dx = abs(x1 - x0)
    local dy = -abs(y1 - y0)
    local sx = x0 < x1 and 1 or -1
    local sy = y0 < y1 and 1 or -1
    local err = dx + dy
    while true do
        setPixel(buf, x0, y0, r, g, b, a)
        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * err
        if e2 >= dy then err = err + dy; x0 = x0 + sx end
        if e2 <= dx then err = err + dx; y0 = y0 + sy end
    end
end

local function fillEllipse(buf, cx, cy, rx, ry, r, g, b, a)
    cx, cy = floor(cx + 0.5), floor(cy + 0.5)
    local iry = floor(ry + 0.5)
    for dy = -iry, iry do
        local ratio = dy / ry
        local halfW = floor(rx * sqrt(1 - ratio * ratio) + 0.5)
        for dx = -halfW, halfW do
            setPixel(buf, cx + dx, cy + dy, r, g, b, a)
        end
    end
end

local function flattenEllipse(cx, cy, rx, ry, n)
    n = n or 64
    local pts = {}
    for i = 0, n do
        local angle = (i / n) * 2 * pi
        pts[i + 1] = {cx + rx * cos(angle), cy + ry * sin(angle)}
    end
    return pts
end

local function fillCircle(buf, cx, cy, radius, r, g, b, a)
    cx, cy = floor(cx + 0.5), floor(cy + 0.5)
    local rad = floor(radius + 0.5)
    for dy = -rad, rad do
        local halfW = floor(sqrt(rad * rad - dy * dy) + 0.5)
        for dx = -halfW, halfW do
            setPixel(buf, cx + dx, cy + dy, r, g, b, a)
        end
    end
end

local function midpointCircle(buf, cx, cy, radius, r, g, b, a)
    cx, cy = floor(cx + 0.5), floor(cy + 0.5)
    local rad = floor(radius + 0.5)
    local x, y = rad, 0
    local d = 1 - rad
    while x >= y do
        setPixel(buf, cx + x, cy + y, r, g, b, a)
        setPixel(buf, cx - x, cy + y, r, g, b, a)
        setPixel(buf, cx + x, cy - y, r, g, b, a)
        setPixel(buf, cx - x, cy - y, r, g, b, a)
        setPixel(buf, cx + y, cy + x, r, g, b, a)
        setPixel(buf, cx - y, cy + x, r, g, b, a)
        setPixel(buf, cx + y, cy - x, r, g, b, a)
        setPixel(buf, cx - y, cy - x, r, g, b, a)
        y = y + 1
        if d <= 0 then
            d = d + 2 * y + 1
        else
            x = x - 1
            d = d + 2 * (y - x) + 1
        end
    end
end

local function fillRect(buf, x, y, w, h, r, g, b, a)
    local x0 = floor(x + 0.5)
    local y0 = floor(y + 0.5)
    local x1 = floor(x + w + 0.5) - 1
    local y1 = floor(y + h + 0.5) - 1
    for py = y0, y1 do
        for px = x0, x1 do
            setPixel(buf, px, py, r, g, b, a)
        end
    end
end

local function scanlineFillPolygon(buf, pts, r, g, b, a)
    if #pts < 3 then return end
    local minY, maxY = math.huge, -math.huge
    for _, p in ipairs(pts) do
        if p[2] < minY then minY = p[2] end
        if p[2] > maxY then maxY = p[2] end
    end
    minY = floor(minY + 0.5)
    maxY = floor(maxY + 0.5)
    local n = #pts
    for y = minY, maxY do
        local xs = {}
        local j = n
        for i = 1, n do
            local yi, yj = pts[i][2], pts[j][2]
            if (yi <= y and yj > y) or (yj <= y and yi > y) then
                local xi, xj = pts[i][1], pts[j][1]
                local xInt = xi + (y - yi) / (yj - yi) * (xj - xi)
                xs[#xs + 1] = xInt
            end
            j = i
        end
        table.sort(xs)
        for i = 1, #xs - 1, 2 do
            local x0 = floor(xs[i] + 0.5)
            local x1 = floor(xs[i + 1] + 0.5)
            for px = x0, x1 do
                setPixel(buf, px, y, r, g, b, a)
            end
        end
    end
end

local function thickLine(buf, x0, y0, x1, y1, r, g, b, a, width, cap)
    if width <= 1 then
        return bresenhamLine(buf, x0, y0, x1, y1, r, g, b, a)
    end
    local dx, dy = x1 - x0, y1 - y0
    local len = sqrt(dx * dx + dy * dy)
    if len == 0 then
        fillCircle(buf, x0, y0, width / 2, r, g, b, a)
        return
    end
    local nx, ny = -dy / len * width / 2, dx / len * width / 2
    scanlineFillPolygon(buf, {
        {x0 + nx, y0 + ny},
        {x1 + nx, y1 + ny},
        {x1 - nx, y1 - ny},
        {x0 - nx, y0 - ny},
    }, r, g, b, a)
    if cap == "round" then
        fillCircle(buf, x0, y0, width / 2, r, g, b, a)
        fillCircle(buf, x1, y1, width / 2, r, g, b, a)
    end
end

local function strokePolyline(buf, pts, r, g, b, a, width, closed, cap)
    if #pts < 2 then return end
    for i = 1, #pts - 1 do
        thickLine(buf, pts[i][1], pts[i][2], pts[i + 1][1], pts[i + 1][2],
                  r, g, b, a, width, cap)
    end
    if closed then
        thickLine(buf, pts[#pts][1], pts[#pts][2], pts[1][1], pts[1][2],
                  r, g, b, a, width, cap)
    end
end

local function strokeRect(buf, x, y, w, h, r, g, b, a, width, cap)
    local x0, y0 = x, y
    local x1, y1 = x + w, y + h
    thickLine(buf, x0, y0, x1, y0, r, g, b, a, width, cap)
    thickLine(buf, x1, y0, x1, y1, r, g, b, a, width, cap)
    thickLine(buf, x1, y1, x0, y1, r, g, b, a, width, cap)
    thickLine(buf, x0, y1, x0, y0, r, g, b, a, width, cap)
end

-- ============================================================
-- Curve Flattening
-- ============================================================

local function flattenBezier(p0, p1, p2, p3, n)
    n = n or 32
    local pts = {}
    for i = 0, n do
        local t = i / n
        local u = 1 - t
        pts[i + 1] = {
            u*u*u*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t*t*t*p3[1],
            u*u*u*p0[2] + 3*u*u*t*p1[2] + 3*u*t*t*p2[2] + t*t*t*p3[2],
        }
    end
    return pts
end

local function flattenArc(cx, cy, r, startAngle, endAngle, n)
    n = n or 32
    local pts = {}
    for i = 0, n do
        local t = i / n
        local angle = startAngle + (endAngle - startAngle) * t
        pts[i + 1] = {cx + r * cos(angle), cy + r * sin(angle)}
    end
    return pts
end

-- ============================================================
-- Color Resolution
-- ============================================================

local function resolveColor(clr, style, isFill)
    if not clr or clr == "none" then return nil end
    if type(clr) == "string" then return nil end
    local r = clamp255(floor(clr[1] * 255 + 0.5))
    local g = clamp255(floor(clr[2] * 255 + 0.5))
    local b = clamp255(floor(clr[3] * 255 + 0.5))
    local a = (clr[4] or 1) * (style.opacity or 1)
    if isFill then
        a = a * (style.fillOpacity or 1)
    else
        a = a * (style.strokeOpacity or 1)
    end
    return r, g, b, a
end

-- ============================================================
-- Scale Helper
-- ============================================================

local function scalePoints(pts, s)
    if s == 1 then return pts end
    local out = {}
    for i, p in ipairs(pts) do
        out[i] = {p[1] * s, p[2] * s}
    end
    return out
end

local function flattenRoundedRect(x, y, w, h, rx, ry, arcSegs)
    arcSegs = arcSegs or 8
    local pts = {}
    -- top edge (left to right)
    pts[#pts + 1] = {x + rx, y}
    pts[#pts + 1] = {x + w - rx, y}
    -- top-right corner
    for i = 1, arcSegs do
        local a = -pi / 2 + (pi / 2) * (i / arcSegs)
        pts[#pts + 1] = {x + w - rx + rx * cos(a), y + ry + ry * sin(a)}
    end
    -- right edge
    pts[#pts + 1] = {x + w, y + ry}
    pts[#pts + 1] = {x + w, y + h - ry}
    -- bottom-right corner
    for i = 1, arcSegs do
        local a = 0 + (pi / 2) * (i / arcSegs)
        pts[#pts + 1] = {x + w - rx + rx * cos(a), y + h - ry + ry * sin(a)}
    end
    -- bottom edge (right to left)
    pts[#pts + 1] = {x + w - rx, y + h}
    pts[#pts + 1] = {x + rx, y + h}
    -- bottom-left corner
    for i = 1, arcSegs do
        local a = pi / 2 + (pi / 2) * (i / arcSegs)
        pts[#pts + 1] = {x + rx + rx * cos(a), y + h - ry + ry * sin(a)}
    end
    -- left edge
    pts[#pts + 1] = {x, y + h - ry}
    pts[#pts + 1] = {x, y + ry}
    -- top-left corner
    for i = 1, arcSegs do
        local a = pi + (pi / 2) * (i / arcSegs)
        pts[#pts + 1] = {x + rx + rx * cos(a), y + ry + ry * sin(a)}
    end
    return pts
end

-- ============================================================
-- Shape Dispatch
-- ============================================================

local function rasterizeShape(buf, sh, style, s)
    local fr, fg, fb, fa = resolveColor(style.fill, style, true)
    local sr, sg, sb, sa = resolveColor(style.stroke, style, false)
    local sw = ((style.strokeWidth or 1) * s)
    local cap = style.strokeLinecap

    if sh.type == "ellipse" then
        local cx, cy = sh.center[1] * s, sh.center[2] * s
        local rx, ry = sh.rx * s, sh.ry * s
        if fr then fillEllipse(buf, cx, cy, rx, ry, fr, fg, fb, fa) end
        if sr then
            local pts = flattenEllipse(cx, cy, rx, ry, 64)
            strokePolyline(buf, pts, sr, sg, sb, sa, sw, true, cap)
        end

    elseif sh.type == "circle" then
        local cx, cy, r = sh.center[1] * s, sh.center[2] * s, sh.r * s
        if fr then fillCircle(buf, cx, cy, r, fr, fg, fb, fa) end
        if sr then
            if sw <= 1 then
                midpointCircle(buf, cx, cy, r, sr, sg, sb, sa)
            else
                local pts = flattenArc(cx, cy, r, 0, 2 * pi, 64)
                strokePolyline(buf, pts, sr, sg, sb, sa, sw, true, cap)
            end
        end

    elseif sh.type == "line" then
        if sr then
            thickLine(buf, sh.a[1]*s, sh.a[2]*s, sh.b[1]*s, sh.b[2]*s,
                      sr, sg, sb, sa, sw, cap)
        end

    elseif sh.type == "rect" then
        local x, y, w, h = sh.x*s, sh.y*s, sh.w*s, sh.h*s
        if sh.rx then
            local rx, ry = sh.rx * s, (sh.ry or sh.rx) * s
            local pts = flattenRoundedRect(x, y, w, h, rx, ry)
            if fr then scanlineFillPolygon(buf, pts, fr, fg, fb, fa) end
            if sr then strokePolyline(buf, pts, sr, sg, sb, sa, sw, true, cap) end
        else
            if fr then fillRect(buf, x, y, w, h, fr, fg, fb, fa) end
            if sr then strokeRect(buf, x, y, w, h, sr, sg, sb, sa, sw, cap) end
        end

    elseif sh.type == "polyline" then
        local pts = scalePoints(sh.points, s)
        if sr then strokePolyline(buf, pts, sr, sg, sb, sa, sw, false, cap) end

    elseif sh.type == "polygon" then
        local pts = scalePoints(sh.points, s)
        if fr then scanlineFillPolygon(buf, pts, fr, fg, fb, fa) end
        if sr then strokePolyline(buf, pts, sr, sg, sb, sa, sw, true, cap) end

    elseif sh.type == "bezier" then
        local pts = flattenBezier(
            {sh.p0[1]*s, sh.p0[2]*s}, {sh.p1[1]*s, sh.p1[2]*s},
            {sh.p2[1]*s, sh.p2[2]*s}, {sh.p3[1]*s, sh.p3[2]*s})
        if sr then strokePolyline(buf, pts, sr, sg, sb, sa, sw, false, cap) end

    elseif sh.type == "arc" then
        local cx, cy, r = sh.center[1]*s, sh.center[2]*s, sh.r*s
        local pts = flattenArc(cx, cy, r, sh.startAngle, sh.endAngle)
        if fr then
            local fillPts = {{cx, cy}}
            for _, p in ipairs(pts) do fillPts[#fillPts + 1] = p end
            scanlineFillPolygon(buf, fillPts, fr, fg, fb, fa)
        end
        if sr then strokePolyline(buf, pts, sr, sg, sb, sa, sw, false, cap) end

    elseif sh.type == "spline" then
        local segs = geo.splineToBeziers(sh.points)
        local allPts = {}
        for _, b in ipairs(segs) do
            local bpts = flattenBezier(
                {b[1][1]*s, b[1][2]*s}, {b[2][1]*s, b[2][2]*s},
                {b[3][1]*s, b[3][2]*s}, {b[4][1]*s, b[4][2]*s})
            -- skip first point of subsequent segments to avoid duplicates
            local start = #allPts == 0 and 1 or 2
            for i = start, #bpts do
                allPts[#allPts + 1] = bpts[i]
            end
        end
        if sr and #allPts >= 2 then
            strokePolyline(buf, allPts, sr, sg, sb, sa, sw, false, cap)
        end
    end
end

-- ============================================================
-- Export
-- ============================================================

function M.exportPpm(c, filename, scale)
    scale = scale or 1
    local w = c.width * scale
    local h = c.height * scale

    local bgR, bgG, bgB = 0, 0, 0
    if c.bg then
        bgR = floor(c.bg[1] * 255 + 0.5)
        bgG = floor(c.bg[2] * 255 + 0.5)
        bgB = floor(c.bg[3] * 255 + 0.5)
    end
    local buf = newBuffer(w, h, bgR, bgG, bgB)

    local function rasterizeElement(elem)
        if elem.style.colorMap then
            buf.colorMatrix = colormap.solve(elem.style.colorMap)
        end
        rasterizeShape(buf, elem.shape, elem.style, scale)
        buf.colorMatrix = nil
    end

    for _, layer in ipairs(c.layers) do
        for _, elem in ipairs(layer.elements) do
            rasterizeElement(elem)
        end
    end
    for _, elem in ipairs(c.elements) do
        rasterizeElement(elem)
    end

    local dir = filename:match("(.+)/[^/]+$")
    if dir then os.execute('mkdir -p "' .. dir .. '"') end

    local f, err = io.open(filename, "wb")
    if not f then error("cannot write " .. filename .. ": " .. err) end

    f:write(string.format("P6\n%d %d\n255\n", w, h))

    local chunks = {}
    local bytes = {}
    local CHUNK = 4096
    for i = 1, w * h do
        local px = buf.data[i]
        bytes[#bytes + 1] = string.char(px[1], px[2], px[3])
        if #bytes >= CHUNK then
            chunks[#chunks + 1] = table.concat(bytes)
            bytes = {}
        end
    end
    if #bytes > 0 then
        chunks[#chunks + 1] = table.concat(bytes)
    end
    f:write(table.concat(chunks))
    f:close()
end

return M
