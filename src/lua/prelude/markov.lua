local import = ...
local algo = import("core").algo

local M = {}

-- Create a Markov chain from explicit transition weights.
-- transitions: {state = {{next_state, weight}, ...}, ...}
-- Returns a chain table (plain data): {state = {nexts = {...}, weights = {...}}}.
M.chain = algo.markovChain

-- Build a chain by counting transitions in an observed sequence.
-- sequence: array of states (any values usable as table keys).
-- Each state's next states are listed in order of first appearance.
M.fromSequence = algo.markovFromSequence

-- Pick the next state given current state.
-- Returns nil if current state has no transitions.
M.step = algo.markovStep

-- Generate a sequence of n states starting from start.
-- Stops early if a dead end is reached.
M.generate = algo.markovGenerate

return M
