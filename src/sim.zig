//! Simulations that produce Fields or geometry: Gray-Scott
//! reaction-diffusion, physarum agents, diffusion-limited aggregation
//! and differential line growth. Each takes an allocator, options and a
//! seed, and can be stepped in rounds.

pub const ReactionDiffusion = @import("sim/ReactionDiffusion.zig");
pub const Physarum = @import("sim/Physarum.zig");
pub const Dla = @import("sim/Dla.zig");
pub const DifferentialGrowth = @import("sim/DifferentialGrowth.zig");
pub const common = @import("sim/common.zig");
pub const Rect = common.Rect;
pub const Mask = common.Mask;

test {
    _ = ReactionDiffusion;
    _ = Physarum;
    _ = Dla;
    _ = DifferentialGrowth;
    _ = common;
}
