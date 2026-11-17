local import = ...
local algo = import("core").algo

local M = {}

-- Rewrite axiom string using production rules for n iterations.
-- rules: {char = "replacement"} for deterministic
--        {char = {{"replacement1", weight}, {"replacement2", weight}, ...}} for stochastic
-- Characters without rules are preserved unchanged. Stochastic rules draw
-- from gen.rand once per occurrence, left to right.
M.rewrite = algo.rewrite

return M
