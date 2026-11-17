//! Contact sheets: a grid of variation renders, each labelled with its
//! --vary number so a favourite can be re-rendered on its own.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Raster = @import("Raster.zig");

pub const Tile = struct {
    raster: ?Raster,
    label: i64,
};

pub const Options = struct {
    gap: u32 = 12,
    bg: Raster.Rgb = .{ 0.08, 0.08, 0.08 },
    ink: Raster.Rgb = .{ 0.92, 0.92, 0.92 },
    /// Size of one font pixel.
    font_px: u32 = 3,
};

/// Lay tiles out row by row. All tiles are drawn at the first tile's size,
/// missing ones (failed renders) as a red square.
pub fn compose(gpa: Allocator, tiles: []const Tile, opts: Options) !Raster {
    assert(tiles.len > 0);
    var tw: u32 = 0;
    var th: u32 = 0;
    for (tiles) |t| if (t.raster) |r| {
        tw = r.w;
        th = r.h;
        break;
    };
    if (tw == 0) {
        tw = 256;
        th = 256;
    }
    const cols: u32 = @intFromFloat(@ceil(@sqrt(@as(f64, @floatFromInt(tiles.len)))));
    const rows: u32 = @intCast((tiles.len + cols - 1) / cols);
    const label_h = 5 * opts.font_px + opts.gap / 2;
    const cell_w = tw + opts.gap;
    const cell_h = th + label_h + opts.gap;
    var out: Raster = try .init(gpa, cols * cell_w + opts.gap, rows * cell_h + opts.gap, opts.bg);
    errdefer out.deinit(gpa);

    for (tiles, 0..) |t, i| {
        const col: u32 = @intCast(i % cols);
        const row: u32 = @intCast(i / cols);
        const x = opts.gap + col * cell_w;
        const y = opts.gap + row * cell_h;
        if (t.raster) |r| {
            out.blit(&r, x, y);
        } else {
            for (0..th) |yy| for (0..tw) |xx| out.set(@intCast(x + xx), @intCast(y + yy), .{ 0.5, 0.05, 0.05 });
        }
        drawNumber(&out, t.label, x, y + th + opts.gap / 3, opts);
    }
    return out;
}

// 3x5 glyphs, one u15 per glyph, rows top to bottom, msb first.
const glyphs = [_]u15{
    0b111_101_101_101_111, // 0
    0b010_110_010_010_111, // 1
    0b111_001_111_100_111, // 2
    0b111_001_111_001_111, // 3
    0b101_101_111_001_001, // 4
    0b111_100_111_001_111, // 5
    0b111_100_111_101_111, // 6
    0b111_001_010_010_010, // 7
    0b111_101_111_101_111, // 8
    0b111_101_111_001_111, // 9
};
const minus: u15 = 0b000_000_111_000_000;

fn drawNumber(out: *Raster, n: i64, x: u32, y: u32, opts: Options) void {
    var buf: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable; // 24 bytes holds any i64
    var cx = x;
    for (text) |ch| {
        const g = if (ch == '-') minus else glyphs[ch - '0'];
        for (0..5) |gy| for (0..3) |gx| {
            const bit: u4 = @intCast(14 - (gy * 3 + gx));
            if ((g >> bit) & 1 == 0) continue;
            for (0..opts.font_px) |py| for (0..opts.font_px) |px| {
                const tx = cx + @as(u32, @intCast(gx)) * opts.font_px + @as(u32, @intCast(px));
                const ty = y + @as(u32, @intCast(gy)) * opts.font_px + @as(u32, @intCast(py));
                if (tx < out.w and ty < out.h) out.set(tx, ty, opts.ink);
            };
        };
        cx += 4 * opts.font_px;
    }
}

test "sheet: grid fits all tiles" {
    const gpa = std.testing.allocator;
    var a: Raster = try .init(gpa, 10, 10, .{ 1, 1, 1 });
    defer a.deinit(gpa);
    const tiles = [_]Tile{ .{ .raster = a, .label = 1 }, .{ .raster = null, .label = 2 }, .{ .raster = a, .label = 30 } };
    var s = try compose(gpa, &tiles, .{});
    defer s.deinit(gpa);
    // Two columns, two rows.
    try std.testing.expectEqual(@as(u32, 2 * (10 + 12) + 12), s.w);
    try std.testing.expectEqual(Raster.Rgb{ 1, 1, 1 }, s.get(12, 12));
}
