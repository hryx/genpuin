//! The algorithm toolbox behind the gen.* Lua API: random streams,
//! noise, Voronoi, spatial queries, path operations, automata, L-system
//! rewriting and color maps. Ported from the original Lua library with
//! its arithmetic kept as is, so seeded scripts render the same.

pub const rand = @import("algo/rand.zig");
pub const perlin = @import("algo/perlin.zig");
pub const voronoi = @import("algo/voronoi.zig");
pub const spatial = @import("algo/spatial.zig");
pub const path = @import("algo/path.zig");
pub const pattern = @import("algo/pattern.zig");
pub const automata = @import("algo/automata.zig");
pub const lsystem = @import("algo/lsystem.zig");
pub const colormap = @import("algo/colormap.zig");

pub const Rng = rand.Rng;
pub const Perlin = perlin.Perlin;
pub const Bounds = rand.Bounds;

test {
    _ = rand;
    _ = perlin;
    _ = voronoi;
    _ = spatial;
    _ = path;
    _ = pattern;
    _ = automata;
    _ = lsystem;
    _ = colormap;
}
