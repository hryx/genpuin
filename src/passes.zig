//! Raster post passes. A pass sits in the display list between draws and
//! rewrites the pixels drawn so far. Distances in pass options are scene
//! units, scaled to pixels through Context.scale at apply time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Raster = @import("Raster.zig");
const blur = @import("passes/blur.zig");
const common = @import("passes/common.zig");
const dither = @import("passes/dither.zig");
const glitch = @import("passes/glitch.zig");
const sort = @import("passes/sort.zig");
const tone = @import("passes/tone.zig");

pub const Frame = common.Frame;
pub const PixelSort = sort.PixelSort;
pub const SortKey = sort.Key;
pub const ChannelShift = glitch.ChannelShift;
pub const Displace = glitch.Displace;
pub const Tear = glitch.Tear;
pub const BlockRepeat = glitch.BlockRepeat;
pub const BlockMode = glitch.BlockMode;
pub const Axis = glitch.Axis;
pub const Dither = dither.Dither;
pub const DitherMethod = dither.Method;
pub const Blur = blur.Blur;
pub const Bloom = blur.Bloom;
pub const Grain = tone.Grain;
pub const Levels = tone.Levels;
pub const Scanlines = tone.Scanlines;

pub const Pass = union(enum) {
    invert,
    pixel_sort: PixelSort,
    channel_shift: ChannelShift,
    displace: Displace,
    tear: Tear,
    block_repeat: BlockRepeat,
    dither: Dither,
    /// Dither with method none.
    posterize: Dither,
    blur: Blur,
    bloom: Bloom,
    grain: Grain,
    levels: Levels,
    scanlines: Scanlines,
    /// Run `inner` on a rectangle only. Never nests.
    region: Region,
};

pub const Region = struct {
    /// Scene units: x, y, w, h.
    rect: [4]f64,
    inner: *const Pass,
};

pub const Context = struct {
    /// Pixels per scene unit, so pass distances can be given in scene units.
    scale: f64,
};

pub fn apply(gpa: Allocator, r: *Raster, pass: *const Pass, ctx: Context) !void {
    switch (pass.*) {
        .region => |*reg| try applyRegion(gpa, r, reg, ctx.scale),
        else => try run(gpa, r, pass, .whole(r, ctx.scale)),
    }
}

fn applyRegion(gpa: Allocator, r: *Raster, reg: *const Region, scale: f64) !void {
    assert(reg.inner.* != .region);
    const x0 = pixelEdge(reg.rect[0], scale, r.w);
    const y0 = pixelEdge(reg.rect[1], scale, r.h);
    const x1 = pixelEdge(reg.rect[0] + reg.rect[2], scale, r.w);
    const y1 = pixelEdge(reg.rect[1] + reg.rect[3], scale, r.h);
    if (x1 <= x0 or y1 <= y0) return;

    var sub: Raster = try .init(gpa, x1 - x0, y1 - y0, .{ 0, 0, 0 });
    defer sub.deinit(gpa);
    const row_len = @as(usize, sub.w) * 3;
    for (0..sub.h) |y| {
        @memcpy(sub.pix[y * row_len ..][0..row_len], r.pix[r.index(x0, y0 + @as(u32, @intCast(y)))..][0..row_len]);
    }
    try run(gpa, &sub, reg.inner, .{ .scale = scale, .x0 = x0, .y0 = y0, .full_w = r.w, .full_h = r.h });
    for (0..sub.h) |y| {
        @memcpy(r.pix[r.index(x0, y0 + @as(u32, @intCast(y)))..][0..row_len], sub.pix[y * row_len ..][0..row_len]);
    }
}

fn pixelEdge(v: f64, scale: f64, limit: u32) u32 {
    return @intFromFloat(std.math.clamp(@round(v * scale), 0, @as(f64, @floatFromInt(limit))));
}

fn run(gpa: Allocator, r: *Raster, pass: *const Pass, frame: Frame) !void {
    switch (pass.*) {
        .invert => for (r.pix) |*v| {
            v.* = 1 - v.*;
        },
        .pixel_sort => |*p| try sort.apply(gpa, r, p, frame),
        .channel_shift => |*p| try glitch.channelShift(gpa, r, p, frame),
        .displace => |*p| try glitch.displace(gpa, r, p, frame),
        .tear => |*p| try glitch.tear(gpa, r, p, frame),
        .block_repeat => |*p| try glitch.blockRepeat(gpa, r, p, frame),
        .dither, .posterize => |*p| try dither.apply(gpa, r, p, frame),
        .blur => |*p| try blur.blur(gpa, r, p, frame),
        .bloom => |*p| try blur.bloom(gpa, r, p, frame),
        .grain => |*p| tone.grain(r, p, frame),
        .levels => |*p| tone.levels(r, p),
        .scanlines => |*p| tone.scanlines(r, p, frame),
        .region => unreachable, // apply unwraps the only region
    }
}

test {
    _ = blur;
    _ = common;
    _ = dither;
    _ = glitch;
    _ = sort;
    _ = tone;
}

test "passes: invert flips every channel" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 1, 1, .{ 0, 0.25, 1 });
    defer r.deinit(gpa);
    try apply(gpa, &r, &.invert, .{ .scale = 1 });
    try std.testing.expectEqual(Raster.Rgb{ 1, 0.75, 0 }, r.get(0, 0));
}

test "passes: region limits a pass to its rectangle, in scene units" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 4, 4, .{ 0, 0, 0 });
    defer r.deinit(gpa);
    const inner: Pass = .invert;
    // Scene rect 1, 0, 1, 1 at scale 2 is pixels x 2..3, y 0..1.
    try apply(gpa, &r, &.{ .region = .{ .rect = .{ 1, 0, 1, 1 }, .inner = &inner } }, .{ .scale = 2 });
    for (0..4) |y| for (0..4) |x| {
        const inside = x >= 2 and y < 2;
        const want: f32 = if (inside) 1 else 0;
        try std.testing.expectEqual(want, r.get(@intCast(x), @intCast(y))[0]);
    };
}

test "passes: region keeps absolute phase for scanlines" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 1, 4, .{ 1, 1, 1 });
    defer r.deinit(gpa);
    const inner: Pass = .{ .scanlines = .{ .period = 2, .width = 1, .strength = 1 } };
    try apply(gpa, &r, &.{ .region = .{ .rect = .{ 0, 1, 1, 3 }, .inner = &inner } }, .{ .scale = 1 });
    try std.testing.expectEqual(@as(f32, 1), r.get(0, 0)[0]);
    try std.testing.expectEqual(@as(f32, 1), r.get(0, 1)[0]);
    try std.testing.expectEqual(@as(f32, 0), r.get(0, 2)[0]);
    try std.testing.expectEqual(@as(f32, 1), r.get(0, 3)[0]);
}
