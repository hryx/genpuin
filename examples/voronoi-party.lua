-- voronoi-spiral.lua — Pen traces Voronoi edges in a clockwise spiral

local gen = require("genpuin")

local W, H = 600, 600
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#0f0f1a"))
gen.seed(19)

-- Generate and relax Voronoi sites in an expanded region
-- so that border edges fall outside the visible canvas.
local margin = 80
local vBounds = {-margin, -margin, W + 2 * margin, H + 2 * margin}
local sites = {}
for i = 1, 400 do
    sites[i] = {-margin + gen.rand() * (W + 2 * margin),
                -margin + gen.rand() * (H + 2 * margin)}
end
local relaxed = gen.relax(sites, vBounds, 6)
local cells = gen.voronoi(relaxed, vBounds)

-- === Extract edge graph from Voronoi cells ===

local EPS = 0.5
local verts = {}  -- array of {x, y}
local vertMap = {} -- spatial lookup

-- Find or create a vertex index for a point
local function getVertIdx(x, y)
    -- Check existing verts within epsilon
    for i, v in ipairs(verts) do
        if math.abs(v[1] - x) < EPS and math.abs(v[2] - y) < EPS then
            return i
        end
    end
    verts[#verts + 1] = {x, y}
    return #verts
end

-- Adjacency: adj[i] = {j1, j2, ...} (neighbor vertex indices)
local adj = {}
-- Edge set for dedup: edgeSet["i,j"] = true (i < j)
local edgeSet = {}

local function edgeKey(a, b)
    if a > b then a, b = b, a end
    return a .. "," .. b
end

-- Extract edges from each cell polygon
for _, v in ipairs(cells) do
    local pts = v.cell.points
    local n = #pts
    for i = 1, n do
        local j = (i % n) + 1
        local ai = getVertIdx(pts[i][1], pts[i][2])
        local bi = getVertIdx(pts[j][1], pts[j][2])
        if ai ~= bi then
            local key = edgeKey(ai, bi)
            if not edgeSet[key] then
                edgeSet[key] = true
                if not adj[ai] then adj[ai] = {} end
                if not adj[bi] then adj[bi] = {} end
                adj[ai][#adj[ai] + 1] = bi
                adj[bi][#adj[bi] + 1] = ai
            end
        end
    end
end

-- === Collapse short edges to enforce minimum edge length ===

local MIN_EDGE = 8  -- minimum edge length in pixels

-- merge[i] = j means vertex i has been merged into vertex j
local merge = {}
local function root(i)
    while merge[i] do i = merge[i] end
    return i
end

-- Find all edges shorter than MIN_EDGE and merge them
local collapsed = true
while collapsed do
    collapsed = false
    for key, _ in pairs(edgeSet) do
        local sep = key:find(",")
        local ai = root(tonumber(key:sub(1, sep - 1)))
        local bi = root(tonumber(key:sub(sep + 1)))
        if ai ~= bi then
            local dx = verts[ai][1] - verts[bi][1]
            local dy = verts[ai][2] - verts[bi][2]
            if dx * dx + dy * dy < MIN_EDGE * MIN_EDGE then
                -- Merge bi into ai: move ai to midpoint
                verts[ai] = {(verts[ai][1] + verts[bi][1]) * 0.5,
                             (verts[ai][2] + verts[bi][2]) * 0.5}
                merge[bi] = ai
                collapsed = true
            end
        end
    end
end

-- Rebuild adjacency and edge set with merged vertices
local newAdj = {}
local newEdgeSet = {}
for key, _ in pairs(edgeSet) do
    local sep = key:find(",")
    local ai = root(tonumber(key:sub(1, sep - 1)))
    local bi = root(tonumber(key:sub(sep + 1)))
    if ai ~= bi then
        local nk = edgeKey(ai, bi)
        if not newEdgeSet[nk] then
            newEdgeSet[nk] = true
            if not newAdj[ai] then newAdj[ai] = {} end
            if not newAdj[bi] then newAdj[bi] = {} end
            newAdj[ai][#newAdj[ai] + 1] = bi
            newAdj[bi][#newAdj[bi] + 1] = ai
        end
    end
end
adj = newAdj
edgeSet = newEdgeSet

-- Track which vertices are on-canvas (tracers should prefer these)
local onCanvas = {}
for i, v in ipairs(verts) do
    if not merge[i] and v[1] >= 0 and v[1] <= W and v[2] >= 0 and v[2] <= H then
        onCanvas[i] = true
    end
end

-- === Clockwise spiral traversal ===

local PI2 = 2 * math.pi

-- Track visited edges and vertices
local visitedEdge = {}
local visitedVert = {}

-- Smallest signed angle difference (wraps to -pi..pi)
local function angleDiff(a, b)
    local d = (b - a) % PI2
    if d > math.pi then d = d - PI2 end
    return d
end

-- Check if a vertex can start a trace (on-canvas, unmerged, has at least 2 reachable unvisited verts).
local function canTrace(idx)
    if merge[idx] or visitedVert[idx] or not adj[idx] or not onCanvas[idx] then return false end
    local count = 0
    for _, ni in ipairs(adj[idx]) do
        if not visitedVert[ni] then
            count = count + 1
            if count >= 2 then return true end
        end
    end
    return false
end

-- Trace a single path from startIdx using right-hand rule.
-- Returns the path as an array of vertex indices.
local function traceFrom(startIdx)
    local path = {startIdx}
    local curr = startIdx
    visitedVert[curr] = true

    -- Initial heading: pretend we arrived from opposite the first unvisited neighbor
    local initNeighbor = nil
    for _, ni in ipairs(adj[curr]) do
        if not visitedVert[ni] then initNeighbor = ni; break end
    end
    if not initNeighbor then return path end
    local incomingAngle = math.atan(verts[curr][2] - verts[initNeighbor][2],
                                    verts[curr][1] - verts[initNeighbor][1])

    while true do
        local neighbors = adj[curr]
        if not neighbors then break end

        local vx, vy = verts[curr][1], verts[curr][2]
        local reverseAngle = incomingAngle + math.pi

        local candidates = {}
        for _, ni in ipairs(neighbors) do
            local key = edgeKey(curr, ni)
            if not visitedEdge[key] then
                local edgeAngle = math.atan(verts[ni][2] - vy, verts[ni][1] - vx)
                local delta = (edgeAngle - reverseAngle) % PI2
                if delta < 1e-10 then delta = PI2 end
                candidates[#candidates + 1] = {idx = ni, delta = delta}
            end
        end
        table.sort(candidates, function(a, b) return a.delta < b.delta end)

        local viable = {}
        for _, cand in ipairs(candidates) do
            if not visitedVert[cand.idx] then
                viable[#viable + 1] = cand
            end
        end

        if #viable == 0 then break end

        local bestNext
        if #viable >= 2 and gen.rand() < 0.1 then
            bestNext = viable[2].idx
        else
            bestNext = viable[1].idx
        end

        visitedEdge[edgeKey(curr, bestNext)] = true
        visitedVert[bestNext] = true
        incomingAngle = math.atan(verts[bestNext][2] - vy, verts[bestNext][1] - vx)
        curr = bestNext
        path[#path + 1] = curr
    end

    return path
end

-- Launch tracers until all vertices are covered.
-- First tracer starts near center; subsequent ones start at unvisited verts.
local traces = {}

-- First trace: start near center
local cx, cy = W / 2, H / 2
local startIdx = nil
local bestDist = math.huge
for i, v in ipairs(verts) do
    local d = gen.dist(v, {cx, cy})
    if d < bestDist and canTrace(i) then
        bestDist = d
        startIdx = i
    end
end
if startIdx then
    traces[#traces + 1] = traceFrom(startIdx)
end

-- Subsequent traces: find unvisited verts that can sustain a path
while true do
    local nextStart = nil
    for i = 1, #verts do
        if canTrace(i) then
            nextStart = i
            break
        end
    end
    if not nextStart then break end
    traces[#traces + 1] = traceFrom(nextStart)
end

-- === Draw all traces ===

-- Color palette: each tracer gets a distinct hue pair
local palettes = {
    {gen.hex("#00ffcc"), gen.hex("#ff0066")},
    {gen.hex("#ffaa00"), gen.hex("#6600ff")},
    {gen.hex("#88ff44"), gen.hex("#ff4444")},
    {gen.hex("#44aaff"), gen.hex("#ff44aa")},
    {gen.hex("#ff6644"), gen.hex("#4466ff")},
    {gen.hex("#aabb00"), gen.hex("#0088ff")},
}

for ti, path in ipairs(traces) do
    local pal = palettes[(ti - 1) % #palettes + 1]
    local totalEdges = #path - 1
    if totalEdges >= 2 then
        -- Subdivide each edge into small segments for smooth color gradient
        local subdivs = 6
        local totalSegs = totalEdges * subdivs
        for i = 1, totalEdges do
            local a = verts[path[i]]
            local b = verts[path[i + 1]]
            for s = 0, subdivs - 1 do
                local segIdx = (i - 1) * subdivs + s
                local t = segIdx / math.max(totalSegs - 1, 1)
                local ft = t * t * t
                local clr = gen.lerpColor(pal[1], pal[2], ft)
                local w = 1.8 - ft * 1.0

                local s0 = s / subdivs
                local s1 = (s + 1) / subdivs
                local p0 = {a[1] + (b[1] - a[1]) * s0, a[2] + (b[2] - a[2]) * s0}
                local p1 = {a[1] + (b[1] - a[1]) * s1, a[2] + (b[2] - a[2]) * s1}

                gen.draw(c, gen.line(p0, p1), {
                    stroke = gen.withAlpha(clr, 0.85),
                    strokeWidth = w,
                    strokeLinecap = "round",
                })
            end
        end

        -- Dot at start
        gen.draw(c, gen.circle(verts[path[1]], 3), {fill = pal[1]})
        -- Dot at end
        gen.draw(c, gen.circle(verts[path[#path]], 2), {fill = pal[2]})
    end
end

return c
