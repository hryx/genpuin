//! Seeded, stateless coherent noise. Simplex, Perlin, value and Worley
//! bases, fBm, ridged and turbulence sums, domain warping, curl, and a
//! bulk grid sampler that fills a Field.
//!
//! Every basis is written over `@Vector(n, f32)` so the grid sampler
//! evaluates eight cells per call. Lattice gradients come from an integer
//! hash of the cell and the seed, so there are no permutation tables and
//! no global state.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Field = @import("Field.zig");

pub const filter = @import("noise/filter.zig");
pub const flow = @import("noise/flow.zig");

pub const Basis = enum { simplex, perlin, value, worley, worley_edge };
pub const Metric = enum { euclidean, manhattan, chebyshev };
pub const Fractal = enum { fbm, ridged, turbulence };

/// How one noise value is made. `octaves` must be at least 1.
pub const Options = struct {
    basis: Basis = .simplex,
    /// Worley distance and how far feature points stray from cell centers (0..1).
    metric: Metric = .euclidean,
    jitter: f32 = 1,
    fractal: Fractal = .fbm,
    octaves: u32 = 1,
    lacunarity: f32 = 2,
    gain: f32 = 0.5,
    /// Domain warp: the sample point moves by `warp` times a simplex fBm
    /// read at `warp_scale` times the point. With `warp_depth` 2 or more
    /// the warp noise is itself warped by the pass before it, after Inigo
    /// Quilez, "Domain Warping" (2002).
    warp: f32 = 0,
    warp_scale: f32 = 1,
    /// Octaves of the warp noise. Null uses `octaves`.
    warp_octaves: ?u32 = null,
    warp_depth: u32 = 1,
    seed: u32 = 0,
};

/// Where grid cells land in noise space. Cell centers are mapped into the
/// scene rect, then multiplied by `scale` and shifted by `offset`.
pub const Mapping = struct {
    /// Scene rect {x, y, w, h}. Null means one scene unit per cell.
    rect: ?[4]f64 = null,
    scale: f32 = 1,
    offset: [2]f32 = .{ 0, 0 },
    /// A third coordinate switches the basis to its 3D form. Worley stays 2D.
    z: ?f32 = null,
};

pub fn simplex2(seed: u32, x: f32, y: f32) f32 {
    return simplex2V(1, seed, @splat(x), @splat(y))[0];
}

pub fn simplex3(seed: u32, x: f32, y: f32, z: f32) f32 {
    return simplex3V(1, seed, @splat(x), @splat(y), @splat(z))[0];
}

pub fn perlin2(seed: u32, x: f32, y: f32) f32 {
    return perlin2V(1, seed, @splat(x), @splat(y))[0];
}

pub fn perlin3(seed: u32, x: f32, y: f32, z: f32) f32 {
    return perlin3V(1, seed, @splat(x), @splat(y), @splat(z))[0];
}

pub fn value2(seed: u32, x: f32, y: f32) f32 {
    return value2V(1, seed, @splat(x), @splat(y))[0];
}

pub fn value3(seed: u32, x: f32, y: f32, z: f32) f32 {
    return value3V(1, seed, @splat(x), @splat(y), @splat(z))[0];
}

/// Distances to the nearest and second nearest feature point, F1 and F2.
pub fn worley2(seed: u32, x: f32, y: f32, metric: Metric, jitter: f32) [2]f32 {
    const r = switch (metric) {
        inline else => |m| worley2V(1, m, seed, @splat(x), @splat(y), jitter),
    };
    return .{ r[0][0], r[1][0] };
}

/// One value of the noise described by `o`, with fractal sum and warp.
pub fn sample(o: *const Options, x: f32, y: f32, z: ?f32) f32 {
    assert(o.octaves >= 1);
    const zv: ?Vf(1) = if (z) |v| @splat(v) else null;
    return sampleV(1, o, @splat(x), @splat(y), zv)[0];
}

/// Curl of the noise as a stream function: (dN/dy, -dN/dx). The result
/// is divergence free, so particles that follow it do not bunch up.
/// Derivatives are central differences in noise space.
pub fn curl(o: *const Options, x: f32, y: f32, z: ?f32) [2]f32 {
    assert(o.octaves >= 1);
    const e: f32 = curl_eps;
    const xs: Vf(4) = .{ x + e, x - e, x, x };
    const ys: Vf(4) = .{ y, y, y + e, y - e };
    const zv: ?Vf(4) = if (z) |v| @splat(v) else null;
    const n = sampleV(4, o, xs, ys, zv);
    const inv: f32 = 1.0 / (2.0 * e);
    return .{ (n[2] - n[3]) * inv, -(n[0] - n[1]) * inv };
}

const curl_eps: f32 = 1e-3;

/// Fill a w x h Field with noise sampled at each cell center.
pub fn grid(gpa: Allocator, w: u32, h: u32, o: *const Options, m: Mapping) !Field {
    assert(o.octaves >= 1);
    var f: Field = try .init(gpa, w, h, 0);
    errdefer f.deinit(gpa);
    fillGrid(&f, o, m);
    return f;
}

/// Overwrite every cell of `f` with noise. Allocation free.
pub fn fillGrid(f: *Field, o: *const Options, m: Mapping) void {
    const rect: [4]f64 = m.rect orelse .{ 0, 0, @floatFromInt(f.w), @floatFromInt(f.h) };
    const cw = rect[2] / @as(f64, @floatFromInt(f.w));
    const ch = rect[3] / @as(f64, @floatFromInt(f.h));
    const scale: f64 = m.scale;
    // Noise x of column i is ax + bx * i.
    const ax: f32 = @floatCast((rect[0] + 0.5 * cw) * scale + m.offset[0]);
    const bx: f32 = @floatCast(cw * scale);
    const zv: ?Vf(lanes) = if (m.z) |v| @splat(v) else null;
    const step: Vf(lanes) = @splat(bx * lanes);
    const first: Vf(lanes) = @as(Vf(lanes), @splat(ax)) + std.simd.iota(f32, lanes) * @as(Vf(lanes), @splat(bx));
    var buf: [lanes]f32 = undefined;
    for (0..f.h) |row| {
        const ny: f64 = (rect[1] + (@as(f64, @floatFromInt(row)) + 0.5) * ch) * scale + m.offset[1];
        const yv: Vf(lanes) = @splat(@floatCast(ny));
        const out = f.data[row * f.w ..][0..f.w];
        var xv = first;
        var i: usize = 0;
        while (i + lanes <= out.len) : (i += lanes) {
            out[i..][0..lanes].* = sampleV(lanes, o, xv, yv, zv);
            xv += step;
        }
        if (i < out.len) {
            buf = sampleV(lanes, o, xv, yv, zv);
            @memcpy(out[i..], buf[0 .. out.len - i]);
        }
    }
}

const lanes = 8;

fn Vf(comptime n: comptime_int) type {
    return @Vector(n, f32);
}

fn Vu(comptime n: comptime_int) type {
    return @Vector(n, u32);
}

fn Vi(comptime n: comptime_int) type {
    return @Vector(n, i32);
}

fn sampleV(comptime n: comptime_int, o: *const Options, x_in: Vf(n), y_in: Vf(n), z: ?Vf(n)) Vf(n) {
    var x = x_in;
    var y = y_in;
    if (o.warp != 0) {
        var wo: Options = .{
            .octaves = o.warp_octaves orelse o.octaves,
            .lacunarity = o.lacunarity,
            .gain = o.gain,
        };
        const ws: Vf(n) = @splat(o.warp_scale);
        const s: Vf(n) = @splat(o.warp);
        var dx: Vf(n) = @splat(0);
        var dy: Vf(n) = @splat(0);
        for (0..o.warp_depth) |depth| {
            const k: u32 = @intCast(depth);
            const wx = (x + s * dx) * ws;
            const wy = (y + s * dy) * ws;
            wo.seed = (o.seed ^ 0x5bd1e995) +% k *% 0x68e31da4;
            dx = fractalV(n, &wo, wx, wy, z);
            wo.seed = (o.seed ^ 0x1b873593) +% k *% 0x68e31da4;
            dy = fractalV(n, &wo, wx, wy, z);
        }
        x += s * dx;
        y += s * dy;
    }
    return fractalV(n, o, x, y, z);
}

/// fBm sums octaves. Turbulence sums their absolute values. Ridged is
/// Musgrave's ridged multifractal (Texturing and Modeling, 3rd ed., ch.
/// 16): each octave is (1 - |n|)^2 weighted by the octave before it.
fn fractalV(comptime n: comptime_int, o: *const Options, x: Vf(n), y: Vf(n), z: ?Vf(n)) Vf(n) {
    const zero: Vf(n) = @splat(0);
    const one: Vf(n) = @splat(1);
    var sum = zero;
    var weight = one;
    var amp: f32 = 1;
    var norm: f32 = 0;
    var freq: f32 = 1;
    for (0..o.octaves) |k| {
        const seed = o.seed +% @as(u32, @intCast(k)) *% 0x9e3779b9;
        const fv: Vf(n) = @splat(freq);
        const zf: ?Vf(n) = if (z) |v| v * fv else null;
        const v = baseV(n, o, seed, x * fv, y * fv, zf);
        const a: Vf(n) = @splat(amp);
        switch (o.fractal) {
            .fbm => sum += v * a,
            .turbulence => sum += @abs(v) * a,
            .ridged => {
                var r = one - @abs(v);
                r = r * r * weight;
                weight = std.math.clamp(r * @as(Vf(n), @splat(2)), zero, one);
                sum += r * a;
            },
        }
        norm += amp;
        amp *= o.gain;
        freq *= o.lacunarity;
    }
    return sum / @as(Vf(n), @splat(norm));
}

fn baseV(comptime n: comptime_int, o: *const Options, seed: u32, x: Vf(n), y: Vf(n), z: ?Vf(n)) Vf(n) {
    return switch (o.basis) {
        .simplex => if (z) |zv| simplex3V(n, seed, x, y, zv) else simplex2V(n, seed, x, y),
        .perlin => if (z) |zv| perlin3V(n, seed, x, y, zv) else perlin2V(n, seed, x, y),
        .value => if (z) |zv| value3V(n, seed, x, y, zv) else value2V(n, seed, x, y),
        .worley, .worley_edge => blk: {
            const r = switch (o.metric) {
                inline else => |m| worley2V(n, m, seed, x, y, o.jitter),
            };
            break :blk if (o.basis == .worley) r[0] else r[1] - r[0];
        },
    };
}

fn shr(comptime n: comptime_int, v: Vu(n), comptime k: u5) Vu(n) {
    return v >> @as(@Vector(n, u5), @splat(k));
}

fn su(comptime n: comptime_int, v: u32) Vu(n) {
    return @splat(v);
}

/// Lattice hash: the coordinates and seed are folded with odd multipliers,
/// then mixed by Chris Wellons' lowbias32 finalizer.
fn hash(comptime n: comptime_int, seed: u32, ix: Vi(n), iy: Vi(n), iz: Vi(n)) Vu(n) {
    const ux: Vu(n) = @bitCast(ix);
    const uy: Vu(n) = @bitCast(iy);
    const uz: Vu(n) = @bitCast(iz);
    var h = (ux *% su(n, 0x8da6b343)) ^ (uy *% su(n, 0xd8163841)) ^ (uz *% su(n, 0xcb1ab31f)) ^ su(n, seed);
    h ^= shr(n, h, 16);
    h *%= su(n, 0x7feb352d);
    h ^= shr(n, h, 15);
    h *%= su(n, 0x846ca68b);
    h ^= shr(n, h, 16);
    return h;
}

fn bit(comptime n: comptime_int, h: Vu(n), mask: u32) @Vector(n, bool) {
    return (h & su(n, mask)) != su(n, 0);
}

/// Eight gradients (+-1, +-2) and (+-2, +-1), the 2D gradient set from
/// Gustavson's SimplexNoise1234.
fn grad2(comptime n: comptime_int, h: Vu(n), x: Vf(n), y: Vf(n)) Vf(n) {
    const low = (h & su(n, 7)) < su(n, 4);
    const u = @select(f32, low, x, y);
    const v = @select(f32, low, y, x) * @as(Vf(n), @splat(2));
    return @select(f32, bit(n, h, 1), -u, u) + @select(f32, bit(n, h, 2), -v, v);
}

/// The twelve cube-edge gradients of Perlin's improved noise (2002),
/// selected from four hash bits.
fn grad3(comptime n: comptime_int, h_in: Vu(n), x: Vf(n), y: Vf(n), z: Vf(n)) Vf(n) {
    const h = h_in & su(n, 15);
    const u = @select(f32, h < su(n, 8), x, y);
    const xz = @select(f32, (h == su(n, 12)) | (h == su(n, 14)), x, z);
    const v = @select(f32, h < su(n, 4), y, xz);
    return @select(f32, bit(n, h, 1), -u, u) + @select(f32, bit(n, h, 2), -v, v);
}

fn toInt(comptime n: comptime_int, v: Vf(n)) Vi(n) {
    return @intFromFloat(v);
}

fn sf(comptime n: comptime_int, v: f32) Vf(n) {
    return @splat(v);
}

/// 2D simplex noise after Stefan Gustavson, "Simplex noise demystified"
/// (2005). Output is scaled to about -1..1.
fn simplex2V(comptime n: comptime_int, seed: u32, x: Vf(n), y: Vf(n)) Vf(n) {
    const f2: f32 = 0.5 * (std.math.sqrt(3.0) - 1.0);
    const g2: f32 = (3.0 - std.math.sqrt(3.0)) / 6.0;
    const s = (x + y) * sf(n, f2);
    const i = @floor(x + s);
    const j = @floor(y + s);
    const t = (i + j) * sf(n, g2);
    const x0 = x - (i - t);
    const y0 = y - (j - t);
    const upper = x0 > y0;
    const a_i = @select(f32, upper, sf(n, 1), sf(n, 0));
    const a_j = sf(n, 1) - a_i;
    const x1 = x0 - a_i + sf(n, g2);
    const y1 = y0 - a_j + sf(n, g2);
    const x2 = x0 - sf(n, 1 - 2 * g2);
    const y2 = y0 - sf(n, 1 - 2 * g2);
    const ii = toInt(n, i);
    const jj = toInt(n, j);
    const zero: Vi(n) = @splat(0);
    const h0 = hash(n, seed, ii, jj, zero);
    const h1 = hash(n, seed, ii + toInt(n, a_i), jj + toInt(n, a_j), zero);
    const h2 = hash(n, seed, ii + @as(Vi(n), @splat(1)), jj + @as(Vi(n), @splat(1)), zero);
    const sum = corner2(n, h0, x0, y0) + corner2(n, h1, x1, y1) + corner2(n, h2, x2, y2);
    return sum * sf(n, simplex2_scale);
}

const simplex2_scale: f32 = 45.0;

fn corner2(comptime n: comptime_int, h: Vu(n), x: Vf(n), y: Vf(n)) Vf(n) {
    const t = @max(sf(n, 0.5) - x * x - y * y, sf(n, 0));
    const t2 = t * t;
    return t2 * t2 * grad2(n, h, x, y);
}

/// 3D simplex noise after Gustavson (2005). The kernel radius is 0.5,
/// not the paper's 0.6, because 0.6 leaves a visible seam at simplex
/// boundaries. The simplex is picked without branches, the way
/// Gustavson and McEwan's GLSL port does it.
fn simplex3V(comptime n: comptime_int, seed: u32, x: Vf(n), y: Vf(n), z: Vf(n)) Vf(n) {
    const f3: f32 = 1.0 / 3.0;
    const g3: f32 = 1.0 / 6.0;
    const s = (x + y + z) * sf(n, f3);
    const i = @floor(x + s);
    const j = @floor(y + s);
    const k = @floor(z + s);
    const t = (i + j + k) * sf(n, g3);
    const x0 = x - (i - t);
    const y0 = y - (j - t);
    const z0 = z - (k - t);
    const one = sf(n, 1);
    const zero = sf(n, 0);
    const gx = @select(f32, x0 >= y0, one, zero);
    const gy = @select(f32, y0 >= z0, one, zero);
    const gz = @select(f32, z0 > x0, one, zero);
    const a_i = @min(gx, one - gz);
    const a_j = @min(gy, one - gx);
    const a_k = @min(gz, one - gy);
    const b_i = @max(gx, one - gz);
    const b_j = @max(gy, one - gx);
    const b_k = @max(gz, one - gy);
    const ii = toInt(n, i);
    const jj = toInt(n, j);
    const kk = toInt(n, k);
    const v1: Vi(n) = @splat(1);
    const h0 = hash(n, seed, ii, jj, kk);
    const h1 = hash(n, seed, ii + toInt(n, a_i), jj + toInt(n, a_j), kk + toInt(n, a_k));
    const h2 = hash(n, seed, ii + toInt(n, b_i), jj + toInt(n, b_j), kk + toInt(n, b_k));
    const h3 = hash(n, seed, ii + v1, jj + v1, kk + v1);
    const g = sf(n, g3);
    var sum = corner3(n, h0, x0, y0, z0);
    sum += corner3(n, h1, x0 - a_i + g, y0 - a_j + g, z0 - a_k + g);
    sum += corner3(n, h2, x0 - b_i + g * sf(n, 2), y0 - b_j + g * sf(n, 2), z0 - b_k + g * sf(n, 2));
    sum += corner3(n, h3, x0 - sf(n, 1 - 3 * g3), y0 - sf(n, 1 - 3 * g3), z0 - sf(n, 1 - 3 * g3));
    return sum * sf(n, simplex3_scale);
}

const simplex3_scale: f32 = 76.5;

fn corner3(comptime n: comptime_int, h: Vu(n), x: Vf(n), y: Vf(n), z: Vf(n)) Vf(n) {
    const t = @max(sf(n, 0.5) - x * x - y * y - z * z, sf(n, 0));
    const t2 = t * t;
    return t2 * t2 * grad3(n, h, x, y, z);
}

/// Quintic fade 6t^5 - 15t^4 + 10t^3 from Perlin's improved noise.
fn fade(comptime n: comptime_int, t: Vf(n)) Vf(n) {
    return t * t * t * (t * (t * sf(n, 6) - sf(n, 15)) + sf(n, 10));
}

fn lerp(comptime n: comptime_int, a: Vf(n), b: Vf(n), t: Vf(n)) Vf(n) {
    return a + (b - a) * t;
}

/// Ken Perlin, "Improving Noise" (SIGGRAPH 2002), with hashed gradients
/// in place of the permutation table.
fn perlin2V(comptime n: comptime_int, seed: u32, x: Vf(n), y: Vf(n)) Vf(n) {
    const fx = @floor(x);
    const fy = @floor(y);
    const ix = toInt(n, fx);
    const iy = toInt(n, fy);
    const tx = x - fx;
    const ty = y - fy;
    const one = sf(n, 1);
    const v1: Vi(n) = @splat(1);
    const z: Vi(n) = @splat(0);
    const a = grad2(n, hash(n, seed, ix, iy, z), tx, ty);
    const b = grad2(n, hash(n, seed, ix + v1, iy, z), tx - one, ty);
    const c = grad2(n, hash(n, seed, ix, iy + v1, z), tx, ty - one);
    const d = grad2(n, hash(n, seed, ix + v1, iy + v1, z), tx - one, ty - one);
    const u = fade(n, tx);
    const v = fade(n, ty);
    return lerp(n, lerp(n, a, b, u), lerp(n, c, d, u), v) * sf(n, perlin2_scale);
}

const perlin2_scale: f32 = 0.66;

fn perlin3V(comptime n: comptime_int, seed: u32, x: Vf(n), y: Vf(n), z: Vf(n)) Vf(n) {
    const fx = @floor(x);
    const fy = @floor(y);
    const fz = @floor(z);
    const ix = toInt(n, fx);
    const iy = toInt(n, fy);
    const iz = toInt(n, fz);
    const tx = x - fx;
    const ty = y - fy;
    const tz = z - fz;
    const one = sf(n, 1);
    const v1: Vi(n) = @splat(1);
    const c000 = grad3(n, hash(n, seed, ix, iy, iz), tx, ty, tz);
    const c100 = grad3(n, hash(n, seed, ix + v1, iy, iz), tx - one, ty, tz);
    const c010 = grad3(n, hash(n, seed, ix, iy + v1, iz), tx, ty - one, tz);
    const c110 = grad3(n, hash(n, seed, ix + v1, iy + v1, iz), tx - one, ty - one, tz);
    const c001 = grad3(n, hash(n, seed, ix, iy, iz + v1), tx, ty, tz - one);
    const c101 = grad3(n, hash(n, seed, ix + v1, iy, iz + v1), tx - one, ty, tz - one);
    const c011 = grad3(n, hash(n, seed, ix, iy + v1, iz + v1), tx, ty - one, tz - one);
    const c111 = grad3(n, hash(n, seed, ix + v1, iy + v1, iz + v1), tx - one, ty - one, tz - one);
    const u = fade(n, tx);
    const v = fade(n, ty);
    const w = fade(n, tz);
    const lo = lerp(n, lerp(n, c000, c100, u), lerp(n, c010, c110, u), v);
    const hi = lerp(n, lerp(n, c001, c101, u), lerp(n, c011, c111, u), v);
    return lerp(n, lo, hi, w);
}

/// A hash mapped onto -1..1.
fn unitSigned(comptime n: comptime_int, h: Vu(n)) Vf(n) {
    const top: Vf(n) = @floatFromInt(shr(n, h, 8));
    return top * sf(n, 2.0 / 16777216.0) - sf(n, 1);
}

fn value2V(comptime n: comptime_int, seed: u32, x: Vf(n), y: Vf(n)) Vf(n) {
    const fx = @floor(x);
    const fy = @floor(y);
    const ix = toInt(n, fx);
    const iy = toInt(n, fy);
    const v1: Vi(n) = @splat(1);
    const z: Vi(n) = @splat(0);
    const a = unitSigned(n, hash(n, seed, ix, iy, z));
    const b = unitSigned(n, hash(n, seed, ix + v1, iy, z));
    const c = unitSigned(n, hash(n, seed, ix, iy + v1, z));
    const d = unitSigned(n, hash(n, seed, ix + v1, iy + v1, z));
    const u = fade(n, x - fx);
    const v = fade(n, y - fy);
    return lerp(n, lerp(n, a, b, u), lerp(n, c, d, u), v);
}

fn value3V(comptime n: comptime_int, seed: u32, x: Vf(n), y: Vf(n), z: Vf(n)) Vf(n) {
    const fx = @floor(x);
    const fy = @floor(y);
    const fz = @floor(z);
    const ix = toInt(n, fx);
    const iy = toInt(n, fy);
    const iz = toInt(n, fz);
    const v1: Vi(n) = @splat(1);
    const c000 = unitSigned(n, hash(n, seed, ix, iy, iz));
    const c100 = unitSigned(n, hash(n, seed, ix + v1, iy, iz));
    const c010 = unitSigned(n, hash(n, seed, ix, iy + v1, iz));
    const c110 = unitSigned(n, hash(n, seed, ix + v1, iy + v1, iz));
    const c001 = unitSigned(n, hash(n, seed, ix, iy, iz + v1));
    const c101 = unitSigned(n, hash(n, seed, ix + v1, iy, iz + v1));
    const c011 = unitSigned(n, hash(n, seed, ix, iy + v1, iz + v1));
    const c111 = unitSigned(n, hash(n, seed, ix + v1, iy + v1, iz + v1));
    const u = fade(n, x - fx);
    const v = fade(n, y - fy);
    const w = fade(n, z - fz);
    const lo = lerp(n, lerp(n, c000, c100, u), lerp(n, c010, c110, u), v);
    const hi = lerp(n, lerp(n, c001, c101, u), lerp(n, c011, c111, u), v);
    return lerp(n, lo, hi, w);
}

/// Steven Worley, "A Cellular Texture Basis Function" (SIGGRAPH 1996),
/// with one feature point per unit cell and a 3x3 cell search. With
/// jitter near 1 an F2 point two cells away is occasionally missed.
fn worley2V(comptime n: comptime_int, comptime metric: Metric, seed: u32, x: Vf(n), y: Vf(n), jitter: f32) [2]Vf(n) {
    const fx = @floor(x);
    const fy = @floor(y);
    const ix = toInt(n, fx);
    const iy = toInt(n, fy);
    const tx = x - fx;
    const ty = y - fy;
    const inf = sf(n, std.math.inf(f32));
    var f1 = inf;
    var f2 = inf;
    const zero: Vi(n) = @splat(0);
    const j = sf(n, jitter / 65536.0);
    const center = sf(n, 0.5 - 0.5 * jitter);
    inline for (.{ -1, 0, 1 }) |dy| {
        inline for (.{ -1, 0, 1 }) |dx| {
            const h = hash(n, seed, ix + @as(Vi(n), @splat(dx)), iy + @as(Vi(n), @splat(dy)), zero);
            const hx: Vf(n) = @floatFromInt(h & su(n, 0xffff));
            const hy: Vf(n) = @floatFromInt(shr(n, h, 16));
            const px = sf(n, dx) + center + hx * j - tx;
            const py = sf(n, dy) + center + hy * j - ty;
            const d = switch (metric) {
                .euclidean => px * px + py * py,
                .manhattan => @abs(px) + @abs(py),
                .chebyshev => @max(@abs(px), @abs(py)),
            };
            f2 = @select(f32, d < f1, f1, @min(f2, d));
            f1 = @min(f1, d);
        }
    }
    if (metric == .euclidean) {
        f1 = @sqrt(f1);
        f2 = @sqrt(f2);
    }
    return .{ f1, f2 };
}

test "noise: same seed and point give the same value" {
    try std.testing.expectEqual(simplex2(7, 1.25, -3.5), simplex2(7, 1.25, -3.5));
    try std.testing.expect(simplex2(7, 1.25, -3.5) != simplex2(8, 1.25, -3.5));
}

test "noise: lattice points of gradient noise are zero" {
    try std.testing.expectEqual(@as(f32, 0), perlin2(3, 4, -2));
    try std.testing.expectEqual(@as(f32, 0), perlin3(3, 4, -2, 9));
    try std.testing.expectEqual(@as(f32, 0), simplex2(3, 0, 0));
}

test "noise: bases stay within -1..1 and use most of it" {
    const Case = struct { name: []const u8, f: *const fn (u32, f32, f32, f32) f32 };
    const cases = [_]Case{
        .{ .name = "simplex2", .f = struct {
            fn f(s: u32, x: f32, y: f32, _: f32) f32 {
                return simplex2(s, x, y);
            }
        }.f },
        .{ .name = "simplex3", .f = simplex3 },
        .{ .name = "perlin2", .f = struct {
            fn f(s: u32, x: f32, y: f32, _: f32) f32 {
                return perlin2(s, x, y);
            }
        }.f },
        .{ .name = "perlin3", .f = perlin3 },
        .{ .name = "value3", .f = value3 },
    };
    for (cases) |c| {
        var lo: f32 = 0;
        var hi: f32 = 0;
        for (0..200) |i| for (0..200) |j| {
            const x = @as(f32, @floatFromInt(i)) * 0.173;
            const y = @as(f32, @floatFromInt(j)) * 0.131;
            const v = c.f(11, x, y, x * 0.37 - y * 0.21);
            lo = @min(lo, v);
            hi = @max(hi, v);
        };
        errdefer std.debug.print("{s}: {d}..{d}\n", .{ c.name, lo, hi });
        try std.testing.expect(lo >= -1.0 and hi <= 1.0);
        try std.testing.expect(lo < -0.6 and hi > 0.6);
    }
}

test "noise: worley F1 at a feature point is zero and F2 exceeds F1" {
    const r = worley2(5, 0.3, 0.7, .euclidean, 0);
    // Zero jitter puts every feature point at a cell center.
    try std.testing.expectApproxEqAbs(@as(f32, std.math.hypot(0.2, 0.2)), r[0], 1e-6);
    try std.testing.expect(r[1] > r[0]);
    const c = worley2(5, 0.5, 0.5, .chebyshev, 0);
    try std.testing.expectEqual(@as(f32, 0), c[0]);
    try std.testing.expectEqual(@as(f32, 1), c[1]);
    const m = worley2(5, 0.25, 0.5, .manhattan, 0);
    try std.testing.expectEqual(@as(f32, 0.25), m[0]);
}

test "noise: grid matches the scalar sampler" {
    const gpa = std.testing.allocator;
    const o: Options = .{ .octaves = 3, .fractal = .ridged, .warp = 0.5 };
    const m: Mapping = .{ .scale = 0.1, .offset = .{ 3, 4 } };
    var f = try grid(gpa, 11, 3, &o, m);
    defer f.deinit(gpa);
    for (0..3) |y| for (0..11) |x| {
        const nx = (@as(f32, @floatFromInt(x)) + 0.5) * 0.1 + 3;
        const ny = (@as(f32, @floatFromInt(y)) + 0.5) * 0.1 + 4;
        try std.testing.expectApproxEqAbs(sample(&o, nx, ny, null), f.get(@intCast(x), @intCast(y)), 1e-5);
    };
}

test "noise: scene rect maps grids of any resolution onto the same noise" {
    const gpa = std.testing.allocator;
    const o: Options = .{};
    const m: Mapping = .{ .rect = .{ 0, 0, 100, 100 }, .scale = 0.03 };
    var small = try grid(gpa, 10, 10, &o, m);
    defer small.deinit(gpa);
    var big = try grid(gpa, 20, 20, &o, m);
    defer big.deinit(gpa);
    // Cell (2, 3) of the small grid is centered at scene (25, 35).
    try std.testing.expectApproxEqAbs(sample(&o, 25 * 0.03, 35 * 0.03, null), small.get(2, 3), 1e-5);
    try std.testing.expectApproxEqAbs(sample(&o, 22.5 * 0.03, 32.5 * 0.03, null), big.get(4, 6), 1e-5);
}

test "noise: curl is divergence free" {
    const o: Options = .{ .octaves = 2 };
    const h: f32 = 0.01;
    for ([_][2]f32{ .{ 1.3, 2.1 }, .{ -4.2, 0.7 }, .{ 9.9, -3.3 } }) |p| {
        const dvx = (curl(&o, p[0] + h, p[1], null)[0] - curl(&o, p[0] - h, p[1], null)[0]) / (2 * h);
        const dvy = (curl(&o, p[0], p[1] + h, null)[1] - curl(&o, p[0], p[1] - h, null)[1]) / (2 * h);
        // Each term is order one. Their sum cancels up to difference error.
        try std.testing.expect(@abs(dvx) + @abs(dvy) > 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 0), dvx + dvy, 0.02 * (@abs(dvx) + @abs(dvy)));
    }
}

test "noise: turbulence and ridged are non-negative" {
    for ([_]Fractal{ .turbulence, .ridged }) |fr| {
        const o: Options = .{ .fractal = fr, .octaves = 4 };
        for (0..100) |i| {
            const t = @as(f32, @floatFromInt(i)) * 0.37;
            try std.testing.expect(sample(&o, t, t * 0.5, null) >= 0);
        }
    }
}

test {
    _ = filter;
    _ = flow;
}
