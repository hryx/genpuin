-- colormap.lua — Derive an affine color matrix from {from, to} pairs
--
-- Given pairs like {{from = red, to = yellow}, {from = yellow, to = red}},
-- computes a 3×4 affine matrix M such that:
--   R' = M[1][1]*R + M[1][2]*G + M[1][3]*B + M[1][4]
--   G' = M[2][1]*R + M[2][2]*G + M[2][3]*B + M[2][4]
--   B' = M[3][1]*R + M[3][2]*G + M[3][3]*B + M[3][4]
--
-- Uses the minimum-norm solution (pseudoinverse) when underdetermined.
-- Colors are in [0,1] space.

local M = {}

local abs = math.abs
local floor = math.floor

-- Solve a square linear system Ax = b via Gaussian elimination with
-- partial pivoting. Returns x, or nil if singular.
local function solveLinear(A, b, n)
    local aug = {}
    for i = 1, n do
        aug[i] = {}
        for j = 1, n do aug[i][j] = A[i][j] end
        aug[i][n + 1] = b[i]
    end
    for col = 1, n do
        local best, bestRow = abs(aug[col][col]), col
        for row = col + 1, n do
            local v = abs(aug[row][col])
            if v > best then best, bestRow = v, row end
        end
        if best < 1e-12 then return nil end
        if bestRow ~= col then
            aug[col], aug[bestRow] = aug[bestRow], aug[col]
        end
        for row = col + 1, n do
            local f = aug[row][col] / aug[col][col]
            for j = col, n + 1 do
                aug[row][j] = aug[row][j] - f * aug[col][j]
            end
        end
    end
    local x = {}
    for i = n, 1, -1 do
        local s = aug[i][n + 1]
        for j = i + 1, n do s = s - aug[i][j] * x[j] end
        x[i] = s / aug[i][i]
    end
    return x
end

-- Derive the affine color matrix from color pairs.
-- Each pair is {from = {r,g,b,...}, to = {r,g,b,...}}.
-- Returns a 3x4 matrix (three rows of {a,b,c,d}).
function M.solve(pairs)
    local n = #pairs

    -- For ≤3 pairs, prefer a diagonal matrix (no cross-channel coupling).
    -- Per channel: slope * from_k + offset = to_k.
    -- With 2 pairs this is exactly determined; with 3 it's least-squares.
    if n <= 3 then
        local matrix = {}
        for ch = 1, 3 do
            local sumF, sumT, sumFF, sumFT = 0, 0, 0, 0
            for i, pair in ipairs(pairs) do
                local fi = pair.from[ch]
                local ti = pair.to[ch]
                sumF = sumF + fi
                sumT = sumT + ti
                sumFF = sumFF + fi * fi
                sumFT = sumFT + fi * ti
            end
            local det = n * sumFF - sumF * sumF
            if abs(det) < 1e-12 then
                -- All from values are the same in this channel; use offset only
                matrix[ch] = {0, 0, 0, sumT / n}
                matrix[ch][ch] = 0
            else
                local slope = (n * sumFT - sumF * sumT) / det
                local offset = (sumT - slope * sumF) / n
                local row = {0, 0, 0, offset}
                row[ch] = slope
                matrix[ch] = row
            end
        end
        return matrix
    end

    -- For 4+ pairs, use full affine matrix via pseudoinverse.
    -- Build input matrix A (n × 4): each row is {R, G, B, 1}
    local A = {}
    local targets = {{}, {}, {}}
    for i, pair in ipairs(pairs) do
        local f = pair.from
        local t = pair.to
        A[i] = {f[1], f[2], f[3], 1}
        targets[1][i] = t[1]
        targets[2][i] = t[2]
        targets[3][i] = t[3]
    end

    -- Compute A·A^T (n × n symmetric)
    local AAT = {}
    for i = 1, n do
        AAT[i] = {}
        for j = 1, n do
            local s = 0
            for k = 1, 4 do s = s + A[i][k] * A[j][k] end
            AAT[i][j] = s
        end
    end

    -- For each output channel, solve (A·A^T)·y = target, then x = A^T·y
    local matrix = {}
    for ch = 1, 3 do
        local y = solveLinear(AAT, targets[ch], n)
        if not y then
            error("colormap: singular system (degenerate color pairs)")
        end
        local x = {}
        for k = 1, 4 do
            local s = 0
            for i = 1, n do s = s + A[i][k] * y[i] end
            x[k] = s
        end
        matrix[ch] = x
    end

    return matrix
end

-- Apply the matrix to a color in [0,1] space.
function M.apply(matrix, r, g, b)
    return
        matrix[1][1]*r + matrix[1][2]*g + matrix[1][3]*b + matrix[1][4],
        matrix[2][1]*r + matrix[2][2]*g + matrix[2][3]*b + matrix[2][4],
        matrix[3][1]*r + matrix[3][2]*g + matrix[3][3]*b + matrix[3][4]
end

-- Convert the matrix to the SVG feColorMatrix "values" attribute string.
-- SVG uses a 4x5 row-major matrix (RGBA output x RGBA+offset input).
function M.toSvgValues(matrix)
    local m = matrix
    return string.format(
        "%g %g %g 0 %g  %g %g %g 0 %g  %g %g %g 0 %g  0 0 0 1 0",
        m[1][1], m[1][2], m[1][3], m[1][4],
        m[2][1], m[2][2], m[2][3], m[2][4],
        m[3][1], m[3][2], m[3][3], m[3][4])
end

return M
