//! Rasterize a Scene into a Raster.

const std = @import("std");
const math = @import("math.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Raster = @import("Raster.zig");
const coverage = @import("coverage.zig");
const passes = @import("passes.zig");
const scene = @import("scene.zig");

const Vec2 = scene.Vec2;
const Mask = coverage.Mask;

pub const Options = struct {
    scale: f64 = 1,
    /// Supersampling factor. The scene renders at scale * ss, then box
    /// filters down.
    ss: u32 = 1,
};

pub fn render(gpa: Allocator, s: *const scene.Scene, opts: Options) !Raster {
    assert(opts.ss >= 1);
    const k = opts.scale * @as(f64, @floatFromInt(opts.ss));
    const w: u32 = @intFromFloat(@max(1, @round(s.w * k)));
    const h: u32 = @intFromFloat(@max(1, @round(s.h * k)));
    var raster: Raster = try .init(gpa, w, h, s.bg);
    errdefer raster.deinit(gpa);

    var ctx: Context = .{
        .gpa = gpa,
        .raster = &raster,
        .mask = try .init(gpa, w, h),
        .k = k,
        .ss = opts.ss,
    };
    defer ctx.deinit();

    for (s.items) |*item| switch (item.*) {
        .draw => |*d| try ctx.draw(d),
        .pass => |*p| try passes.apply(gpa, &raster, &p.pass, .{ .scale = k }),
    };

    if (opts.ss == 1) return raster;
    defer raster.deinit(gpa);
    return raster.downsample(gpa, opts.ss);
}

const Context = struct {
    gpa: Allocator,
    raster: *Raster,
    mask: Mask,
    scratch: coverage.FillScratch = .{},
    pts: std.ArrayList(Vec2) = .empty,
    /// Per colorMap matrix, how much of each pixel it has remapped so far,
    /// in 1/65535 steps.
    remapped: std.AutoHashMapUnmanaged(u32, []u16) = .empty,
    k: f64,
    ss: u32,

    fn deinit(self: *Context) void {
        self.mask.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.pts.deinit(self.gpa);
        var it = self.remapped.valueIterator();
        while (it.next()) |v| self.gpa.free(v.*);
        self.remapped.deinit(self.gpa);
    }

    fn tx(self: *const Context, p: Vec2) Vec2 {
        return .{ p[0] * self.k, p[1] * self.k };
    }

    fn draw(self: *Context, d: *const scene.Draw) !void {
        const st = &d.style;
        if (st.fill != .none or d.shape == .field) {
            try self.coverFill(&d.shape);
            try self.composite(st, st.fill, st.opacity * st.fill_opacity, &d.shape);
        }
        if (st.stroke != .none and d.shape != .field) {
            try self.coverStroke(&d.shape, st);
            try self.composite(st, st.stroke, st.opacity * st.stroke_opacity, &d.shape);
        }
    }

    fn coverFill(self: *Context, shape: *const scene.Shape) !void {
        const g = self.gpa;
        const m = &self.mask;
        switch (shape.*) {
            .circle => |c| {
                const p = self.tx(c.c);
                try coverage.fillCircle(g, m, p[0], p[1], c.r * self.k);
            },
            .rect => |r| {
                if (r.rx > 0 or r.ry > 0) {
                    try self.flattenRoundedRect(r.x, r.y, r.w, r.h, r.rx, r.ry);
                    try coverage.fillPath(g, m, &self.scratch, &.{self.pts.items});
                } else {
                    const a = self.tx(.{ r.x, r.y });
                    const b = self.tx(.{ r.x + r.w, r.y + r.h });
                    try coverage.fillRect(g, m, a[0], a[1], b[0], b[1]);
                }
            },
            .field => |f| {
                const a = self.tx(.{ f.x, f.y });
                const b = self.tx(.{ f.x + f.w, f.y + f.h });
                try coverage.fillRect(g, m, a[0], a[1], b[0], b[1]);
            },
            .ellipse => |e| {
                try self.flattenEllipse(e.c, e.rx, e.ry);
                try coverage.fillPath(g, m, &self.scratch, &.{self.pts.items});
            },
            .polygon => |pts| {
                try self.transformInto(pts);
                try coverage.fillPath(g, m, &self.scratch, &.{self.pts.items});
            },
            .arc => |a| {
                self.pts.clearRetainingCapacity();
                try self.pts.append(g, self.tx(a.c));
                try self.appendArc(a.c, a.r, a.start, a.end);
                try coverage.fillPath(g, m, &self.scratch, &.{self.pts.items});
            },
            .compound => |contours| {
                const arena_contours = try g.alloc([]Vec2, contours.len);
                defer g.free(arena_contours);
                var done: usize = 0;
                defer for (arena_contours[0..done]) |c| g.free(c);
                for (contours, 0..) |c, i| {
                    arena_contours[i] = try g.alloc(Vec2, c.len);
                    done += 1;
                    for (c, 0..) |p, j| arena_contours[i][j] = self.tx(p);
                }
                const view: []const []const Vec2 = @ptrCast(arena_contours);
                try coverage.fillPath(g, m, &self.scratch, view);
            },
            .line, .polyline, .bezier, .spline => {},
        }
    }

    fn coverStroke(self: *Context, shape: *const scene.Shape, st: *const scene.Style) !void {
        const g = self.gpa;
        const m = &self.mask;
        const hw = st.stroke_width * self.k / 2;
        switch (shape.*) {
            .circle => |c| {
                if (st.dash == null) {
                    const p = self.tx(c.c);
                    return coverage.strokeRing(g, m, p[0], p[1], c.r * self.k, hw);
                }
                self.pts.clearRetainingCapacity();
                try self.appendArc(c.c, c.r, 0, 2 * std.math.pi);
                return self.strokePts(st, hw, true);
            },
            .line => |l| {
                self.pts.clearRetainingCapacity();
                try self.pts.append(g, self.tx(l[0]));
                try self.pts.append(g, self.tx(l[1]));
                return self.strokePts(st, hw, false);
            },
            .rect => |r| {
                if (r.rx > 0 or r.ry > 0) {
                    try self.flattenRoundedRect(r.x, r.y, r.w, r.h, r.rx, r.ry);
                } else {
                    self.pts.clearRetainingCapacity();
                    for ([_]Vec2{ .{ r.x, r.y }, .{ r.x + r.w, r.y }, .{ r.x + r.w, r.y + r.h }, .{ r.x, r.y + r.h } }) |p| {
                        try self.pts.append(g, self.tx(p));
                    }
                }
                return self.strokePts(st, hw, true);
            },
            .ellipse => |e| {
                try self.flattenEllipse(e.c, e.rx, e.ry);
                return self.strokePts(st, hw, true);
            },
            .polyline => |pts| {
                try self.transformInto(pts);
                return self.strokePts(st, hw, false);
            },
            .polygon => |pts| {
                try self.transformInto(pts);
                return self.strokePts(st, hw, true);
            },
            .arc => |a| {
                self.pts.clearRetainingCapacity();
                try self.appendArc(a.c, a.r, a.start, a.end);
                return self.strokePts(st, hw, false);
            },
            .bezier => |b| {
                self.pts.clearRetainingCapacity();
                try self.appendBezier(b, true);
                return self.strokePts(st, hw, false);
            },
            .spline => |pts| {
                self.pts.clearRetainingCapacity();
                if (pts.len < 2) return;
                for (0..pts.len - 1) |i| {
                    const p0 = pts[if (i == 0) 0 else i - 1];
                    const p1 = pts[i];
                    const p2 = pts[i + 1];
                    const p3 = pts[@min(i + 2, pts.len - 1)];
                    const seg: [4]Vec2 = .{
                        p1,
                        .{ p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6 },
                        .{ p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6 },
                        p2,
                    };
                    try self.appendBezier(seg, i == 0);
                }
                return self.strokePts(st, hw, false);
            },
            .compound => |contours| {
                for (contours) |c| {
                    try self.transformInto(c);
                    try self.strokePts(st, hw, true);
                }
            },
            .field => {},
        }
    }

    fn strokePts(self: *Context, st: *const scene.Style, hw: f64, closed: bool) !void {
        const g = self.gpa;
        if (st.dash) |dash| {
            if (closed and self.pts.items.len > 0) try self.pts.append(g, self.pts.items[0]);
            const scaled: [2]f64 = .{ dash[0] * self.k, dash[1] * self.k };
            return coverage.strokeDashed(g, &self.mask, self.pts.items, hw, st.cap, scaled, st.dash_offset * self.k, closed);
        }
        return coverage.strokePolyline(g, &self.mask, self.pts.items, hw, closed, st.cap);
    }

    fn transformInto(self: *Context, pts: []const Vec2) !void {
        self.pts.clearRetainingCapacity();
        try self.pts.ensureTotalCapacity(self.gpa, pts.len);
        for (pts) |p| self.pts.appendAssumeCapacity(self.tx(p));
    }

    /// Segment count for a curve of `len_px` pixels: about one per 2px.
    fn segments(len_px: f64, min: u32) u32 {
        return std.math.clamp(@as(u32, @intFromFloat(@min(1e6, @ceil(len_px / 2)))), min, 4096);
    }

    fn appendArc(self: *Context, c: Vec2, r: f64, a0: f64, a1: f64) !void {
        const n = segments(@abs(a1 - a0) * r * self.k, 8);
        for (0..n + 1) |i| {
            const t = a0 + (a1 - a0) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
            try self.pts.append(self.gpa, self.tx(.{ c[0] + r * math.cos(t), c[1] + r * math.sin(t) }));
        }
    }

    fn flattenEllipse(self: *Context, c: Vec2, rx: f64, ry: f64) !void {
        self.pts.clearRetainingCapacity();
        const n = segments(2 * std.math.pi * @max(rx, ry) * self.k, 64);
        for (0..n) |i| {
            const t = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
            try self.pts.append(self.gpa, self.tx(.{ c[0] + rx * math.cos(t), c[1] + ry * math.sin(t) }));
        }
    }

    fn appendBezier(self: *Context, b: [4]Vec2, include_first: bool) !void {
        var len: f64 = 0;
        for (0..3) |i| len += std.math.hypot(b[i + 1][0] - b[i][0], b[i + 1][1] - b[i][1]);
        const n = segments(len * self.k, 4);
        const start: u32 = if (include_first) 0 else 1;
        var i = start;
        while (i <= n) : (i += 1) {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
            const u = 1 - t;
            const p: Vec2 = .{
                u * u * u * b[0][0] + 3 * u * u * t * b[1][0] + 3 * u * t * t * b[2][0] + t * t * t * b[3][0],
                u * u * u * b[0][1] + 3 * u * u * t * b[1][1] + 3 * u * t * t * b[2][1] + t * t * t * b[3][1],
            };
            try self.pts.append(self.gpa, self.tx(p));
        }
    }

    fn flattenRoundedRect(self: *Context, x: f64, y: f64, w: f64, h: f64, rx_in: f64, ry_in: f64) !void {
        self.pts.clearRetainingCapacity();
        const rx = @min(if (rx_in > 0) rx_in else ry_in, w / 2);
        const ry = @min(if (ry_in > 0) ry_in else rx_in, h / 2);
        const n = segments(std.math.pi / 2.0 * @max(rx, ry) * self.k, 4);
        const corners = [_]struct { c: Vec2, a: f64 }{
            .{ .c = .{ x + w - rx, y + ry }, .a = -std.math.pi / 2.0 },
            .{ .c = .{ x + w - rx, y + h - ry }, .a = 0 },
            .{ .c = .{ x + rx, y + h - ry }, .a = std.math.pi / 2.0 },
            .{ .c = .{ x + rx, y + ry }, .a = std.math.pi },
        };
        for (corners) |cn| {
            for (0..n + 1) |i| {
                const t = cn.a + std.math.pi / 2.0 * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
                try self.pts.append(self.gpa, self.tx(.{ cn.c[0] + rx * math.cos(t), cn.c[1] + ry * math.sin(t) }));
            }
        }
    }

    fn composite(self: *Context, st: *const scene.Style, paint: scene.Paint, alpha: f32, shape: *const scene.Shape) !void {
        defer self.mask.touched.clearRetainingCapacity();
        const m = &self.mask;
        const r = self.raster;

        if (st.color_map) |cm| return self.remap(&cm);

        var field_range: [2]f32 = .{ 0, 1 };
        if (shape.* == .field) {
            const f = shape.field;
            field_range = f.range orelse f.field.minMax();
        }

        for (m.touched.items) |i| {
            const cov = m.cov[i];
            m.cov[i] = 0;
            const px = i % r.w;
            const py = i / r.w;
            const color = self.paintAt(paint, shape, field_range, px, py);
            const a = alpha * cov * color[3];
            if (a <= 0) continue;
            const d = r.pix[@as(usize, i) * 3 ..][0..3];
            for (0..3) |c| {
                const s = blend(st.blend, color[c], d[c]);
                d[c] = s * a + d[c] * (1 - a);
            }
        }
    }

    /// Mix each covered pixel toward its remapped color by its coverage,
    /// out of what this matrix has not yet remapped there. A pixel two
    /// shapes cover reaches a full remap once, as in SVG, where the run's
    /// mask is the union of its shapes less what earlier runs masked.
    fn remap(self: *Context, cm: *const scene.ColorMap) !void {
        const m = &self.mask;
        const r = self.raster;
        const gop = try self.remapped.getOrPut(self.gpa, cm.key);
        if (!gop.found_existing) {
            errdefer _ = self.remapped.remove(cm.key);
            gop.value_ptr.* = try self.gpa.alloc(u16, @as(usize, r.w) * r.h);
            @memset(gop.value_ptr.*, 0);
        }
        const done = gop.value_ptr.*;
        const full: f32 = std.math.maxInt(u16);
        for (m.touched.items) |i| {
            const cov = m.cov[i];
            m.cov[i] = 0;
            const before = @as(f32, @floatFromInt(done[i])) / full;
            const a = cov * (1 - before);
            if (a <= 0) continue;
            done[i] = @intFromFloat(@round(@min(before + a, 1) * full));
            const d = r.pix[@as(usize, i) * 3 ..][0..3];
            const src = d.*;
            for (0..3) |c| {
                const to = std.math.clamp(cm.m[c][0] * src[0] + cm.m[c][1] * src[1] + cm.m[c][2] * src[2] + cm.m[c][3], 0, 1);
                d[c] = src[c] + (to - src[c]) * a;
            }
        }
    }

    fn paintAt(self: *const Context, paint: scene.Paint, shape: *const scene.Shape, range: [2]f32, px: u32, py: u32) scene.Rgba {
        // Pixel center in scene coordinates.
        const sx = (@as(f64, @floatFromInt(px)) + 0.5) / self.k;
        const sy = (@as(f64, @floatFromInt(py)) + 0.5) / self.k;
        if (shape.* == .field) return fieldColor(&shape.field, range, sx, sy);
        return switch (paint) {
            .none => .{ 0, 0, 0, 0 },
            .solid => |c| c,
            .gradient => |g| gradientColor(g, sx, sy),
        };
    }
};

fn gradientColor(g: *const scene.Gradient, x: f64, y: f64) scene.Rgba {
    const t: f64 = switch (g.geometry) {
        .linear => |l| blk: {
            const dx = l.b[0] - l.a[0];
            const dy = l.b[1] - l.a[1];
            const len2 = dx * dx + dy * dy;
            if (len2 == 0) break :blk 0;
            break :blk ((x - l.a[0]) * dx + (y - l.a[1]) * dy) / len2;
        },
        .radial => |rg| if (rg.r > 0) std.math.hypot(x - rg.c[0], y - rg.c[1]) / rg.r else 0,
    };
    return scene.samplePalette(g.stops, @floatCast(t));
}

/// The color of image `f` at scene point (x, y). `range` is the span of
/// field values that maps onto the palette.
pub fn fieldColor(f: *const scene.FieldImage, range: [2]f32, x: f64, y: f64) scene.Rgba {
    const fw: f64 = @floatFromInt(f.field.w);
    const fh: f64 = @floatFromInt(f.field.h);
    const u = (x - f.x) / f.w * fw;
    const v = (y - f.y) / f.h * fh;
    const raw = if (f.smooth)
        f.field.sample(u, v)
    else
        f.field.at(@intFromFloat(@floor(u)), @intFromFloat(@floor(v)));
    const span = range[1] - range[0];
    var t: f32 = if (span != 0) (raw - range[0]) / span else 0;
    t = std.math.clamp(t, 0, 1);
    t = switch (f.tone) {
        .linear => t,
        .log => |k| @floatCast(math.log(1 + k * t) / math.log(1 + k)),
        .gamma => |gm| @floatCast(math.pow(t, gm)),
    };
    return scene.samplePalette(f.palette, t);
}

fn blend(mode: scene.Blend, s: f32, d: f32) f32 {
    return switch (mode) {
        .normal => s,
        .multiply => s * d,
        .screen => s + d - s * d,
        .overlay => if (d < 0.5) 2 * s * d else 1 - 2 * (1 - s) * (1 - d),
        .darken => @min(s, d),
        .lighten => @max(s, d),
        .difference => @abs(s - d),
        .exclusion => s + d - 2 * s * d,
        .add => @min(1, s + d),
    };
}

test "render: opaque rect fills its pixels" {
    const gpa = std.testing.allocator;
    const items = [_]scene.Item{.{ .draw = .{
        .shape = .{ .rect = .{ .x = 2, .y = 2, .w = 2, .h = 2 } },
        .style = .{ .fill = .{ .solid = .{ 1, 0, 0, 1 } } },
    } }};
    const s: scene.Scene = .{ .w = 6, .h = 6, .bg = .{ 0, 0, 0 }, .items = &items };
    var r = try render(gpa, &s, .{});
    defer r.deinit(gpa);
    try std.testing.expectEqual(Raster.Rgb{ 1, 0, 0 }, r.get(2, 2));
    try std.testing.expectEqual(Raster.Rgb{ 1, 0, 0 }, r.get(3, 3));
    try std.testing.expectEqual(Raster.Rgb{ 0, 0, 0 }, r.get(1, 1));
    try std.testing.expectEqual(Raster.Rgb{ 0, 0, 0 }, r.get(4, 4));
}

test "render: stroke over fill keeps full stroke width" {
    const gpa = std.testing.allocator;
    const items = [_]scene.Item{.{ .draw = .{
        .shape = .{ .rect = .{ .x = 2, .y = 2, .w = 10, .h = 10 } },
        .style = .{ .fill = .{ .solid = .{ 1, 1, 1, 1 } }, .stroke = .{ .solid = .{ 0, 0, 0, 1 } }, .stroke_width = 3 },
    } }};
    const s: scene.Scene = .{ .w = 14, .h = 14, .bg = .{ 0.5, 0.5, 0.5 }, .items = &items };
    var r = try render(gpa, &s, .{});
    defer r.deinit(gpa);
    // One pixel inside the top edge sits under the inner half of the stroke.
    try std.testing.expectEqual(Raster.Rgb{ 0, 0, 0 }, r.get(7, 2));
    try std.testing.expectEqual(Raster.Rgb{ 1, 1, 1 }, r.get(7, 7));
}

test "render: rect over the whole scene covers the corner pixels" {
    const gpa = std.testing.allocator;
    const items = [_]scene.Item{.{ .draw = .{
        .shape = .{ .rect = .{ .x = 0, .y = 0, .w = 5, .h = 4 } },
        .style = .{ .fill = .{ .solid = .{ 1, 1, 1, 1 } } },
    } }};
    const s: scene.Scene = .{ .w = 5, .h = 4, .bg = .{ 0, 0, 0 }, .items = &items };
    var r = try render(gpa, &s, .{ .scale = 2 });
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 10), r.w);
    try std.testing.expectEqual(Raster.Rgb{ 1, 1, 1 }, r.get(0, 0));
    try std.testing.expectEqual(Raster.Rgb{ 1, 1, 1 }, r.get(9, 7));
}

test "render: rects sharing an edge leave no seam" {
    const gpa = std.testing.allocator;
    const white: scene.Style = .{ .fill = .{ .solid = .{ 1, 1, 1, 1 } } };
    const items = [_]scene.Item{
        .{ .draw = .{ .shape = .{ .rect = .{ .x = 0, .y = 0, .w = 3, .h = 4 } }, .style = white } },
        .{ .draw = .{ .shape = .{ .rect = .{ .x = 3, .y = 0, .w = 3, .h = 4 } }, .style = white } },
    };
    const s: scene.Scene = .{ .w = 6, .h = 4, .bg = .{ 0, 0, 0 }, .items = &items };
    var r = try render(gpa, &s, .{});
    defer r.deinit(gpa);
    try std.testing.expectEqual(Raster.Rgb{ 1, 1, 1 }, r.get(2, 1));
    try std.testing.expectEqual(Raster.Rgb{ 1, 1, 1 }, r.get(3, 1));
}

test "render: a colorMap remaps an edge pixel by its coverage, once per matrix" {
    const gpa = std.testing.allocator;
    const invert: scene.ColorMap = .{ .m = .{ .{ -1, 0, 0, 1 }, .{ 0, -1, 0, 1 }, .{ 0, 0, -1, 1 } }, .key = 7 };
    const style: scene.Style = .{ .fill = .{ .solid = .{ 0, 0, 0, 1 } }, .color_map = invert };
    // Covers pixel 0 fully and pixel 1 half, twice over.
    const shape: scene.Shape = .{ .rect = .{ .x = 0, .y = 0, .w = 1.5, .h = 1 } };
    const items = [_]scene.Item{
        .{ .draw = .{ .shape = shape, .style = style } },
        .{ .draw = .{ .shape = shape, .style = style } },
    };
    const s: scene.Scene = .{ .w = 3, .h = 1, .bg = .{ 1, 1, 1 }, .items = &items };
    var r = try render(gpa, &s, .{});
    defer r.deinit(gpa);
    try std.testing.expectEqual(Raster.Rgb{ 0, 0, 0 }, r.get(0, 0));
    // Half remapped by the first draw. The second adds a quarter of a
    // remap of what is there, and the inverse of mid gray is mid gray.
    try std.testing.expectEqual(Raster.Rgb{ 0.5, 0.5, 0.5 }, r.get(1, 0));
    try std.testing.expectEqual(Raster.Rgb{ 1, 1, 1 }, r.get(2, 0));
}
