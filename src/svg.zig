//! SVG export of a Scene. render.zig defines the picture and this file
//! transcribes it, so a viewer draws what the PNG at scale 1 shows: the
//! same background, round joins, fill areas, dash pattern, blend and
//! colorMap order. `check` names the first thing SVG cannot show, such as
//! a post pass. `write` takes only scenes that `check` accepts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const assert = std.debug.assert;

const image_io = @import("image_io.zig");
const math = @import("math.zig");
const render = @import("render.zig");
const scene = @import("scene.zig");

const Vec2 = scene.Vec2;
const Shape = scene.Shape;
const Style = scene.Style;

pub const Problem = union(enum) {
    pass: *const scene.Post,
    draw: struct {
        /// One-based count of draws up to this one.
        ordinal: usize,
        shape: std.meta.Tag(Shape),
        why: Why,
    },

    pub const Why = enum { blend_add, stops_unsorted, color_range, opacity_range };

    pub fn format(p: Problem, w: *Writer) Writer.Error!void {
        switch (p) {
            .pass => |post| try w.print("{s}: gen.post.{s} needs pixels and has no vector form", .{ post.where, post.name }),
            .draw => |d| {
                try w.print("draw {d} ({s}): ", .{ d.ordinal, @tagName(d.shape) });
                try w.writeAll(switch (d.why) {
                    .blend_add => "blendMode 'add' has no SVG form",
                    .stops_unsorted => "gradient stop offsets go down, and SVG would reorder them",
                    .color_range => "a color channel lies outside 0 to 1, which SVG clamps and the PNG does not",
                    .opacity_range => "an opacity lies outside 0 to 1, which SVG clamps and the PNG does not",
                });
                try w.writeAll(". Write a PNG instead");
            },
        }
    }
};

/// The first item of `s` that SVG cannot show as the rasterizer draws
/// it, or null when the whole scene can be written.
pub fn check(s: *const scene.Scene) ?Problem {
    var ordinal: usize = 0;
    for (s.items) |*item| switch (item.*) {
        .pass => |*p| return .{ .pass = p },
        .draw => |*d| {
            ordinal += 1;
            if (checkDraw(d)) |why| return .{ .draw = .{ .ordinal = ordinal, .shape = d.shape, .why = why } };
        },
    };
    return null;
}

fn checkDraw(d: *const scene.Draw) ?Problem.Why {
    const st = &d.style;
    // A remap ignores paint, opacity and blend.
    if (st.color_map != null) return null;
    const fill = fills(d);
    const stroke = strokes(d);
    if (!fill and !stroke) return null;
    if (st.blend == .add) return .blend_add;
    if (!unit(st.opacity)) return .opacity_range;
    if (fill and !unit(st.fill_opacity)) return .opacity_range;
    if (stroke and !unit(st.stroke_opacity)) return .opacity_range;
    if (d.shape == .field) {
        for (d.shape.field.palette) |stop| if (!unitColor(stop.color)) return .color_range;
        return null;
    }
    if (fill) if (checkPaint(st.fill)) |why| return why;
    if (stroke) if (checkPaint(st.stroke)) |why| return why;
    return null;
}

fn checkPaint(paint: scene.Paint) ?Problem.Why {
    switch (paint) {
        .none => {},
        .solid => |c| if (!unitColor(c)) return .color_range,
        .gradient => |g| for (g.stops, 0..) |stop, i| {
            if (!unitColor(stop.color)) return .color_range;
            if (i > 0 and !(stop.offset >= g.stops[i - 1].offset)) return .stops_unsorted;
        },
    }
    return null;
}

fn unit(v: f32) bool {
    return v >= 0 and v <= 1;
}

fn unitColor(c: scene.Rgba) bool {
    for (c) |v| if (!unit(v)) return false;
    return true;
}

/// Whether the rasterizer paints a fill for `d`. Open shapes never fill,
/// and a field image always does.
fn fills(d: *const scene.Draw) bool {
    return switch (d.shape) {
        .field => true,
        .line, .polyline, .bezier, .spline => false,
        .circle, .ellipse, .rect, .polygon, .arc, .compound => d.style.fill != .none,
    };
}

fn strokes(d: *const scene.Draw) bool {
    return d.shape != .field and d.style.stroke != .none and d.style.stroke_width > 0;
}

/// How many post passes `s` holds.
pub fn passCount(s: *const scene.Scene) usize {
    var n: usize = 0;
    for (s.items) |item| n += @intFromBool(item == .pass);
    return n;
}

/// `s` with its post passes left out: every draw, in order, in its layer.
pub fn withoutPasses(arena: Allocator, s: *const scene.Scene) !scene.Scene {
    const items = try arena.alloc(scene.Item, s.items.len - passCount(s));
    const layers = try arena.dupe(scene.Layer, s.layers);
    // kept[i] is how many draws come before item i.
    const kept = try arena.alloc(usize, s.items.len + 1);
    var n: usize = 0;
    for (s.items, 0..) |item, i| {
        kept[i] = n;
        if (item == .pass) continue;
        items[n] = item;
        n += 1;
    }
    kept[s.items.len] = n;
    for (layers) |*l| {
        l.item_first = kept[l.item_first];
        l.item_end = kept[l.item_end];
    }
    return .{ .w = s.w, .h = s.h, .bg = s.bg, .items = items, .layers = layers };
}

/// Write `s` as an SVG document. `check(s)` must be null.
pub fn write(gpa: Allocator, out: *Writer, s: *const scene.Scene) !void {
    assert(check(s) == null);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var x: Exporter = .{ .gpa = gpa, .arena = arena_state.allocator(), .out = out, .s = s };
    try x.document();
}

/// Consecutive colorMap draws with one matrix, inside one layer. The
/// rasterizer remaps each pixel at most once per matrix, so a run is one
/// mask over the scene drawn so far.
const Run = struct {
    first: usize,
    end: usize,
    key: u32,
};

const Mode = enum { paint, mask };

const Exporter = struct {
    gpa: Allocator,
    arena: Allocator,
    out: *Writer,
    s: *const scene.Scene,
    gradient_ids: std.AutoHashMapUnmanaged(*const scene.Gradient, u32) = .empty,
    fill_d: Path = .{},
    stroke_d: Path = .{},
    layer_index: usize = 0,
    layer_open: bool = false,
    layer_named: bool = false,

    fn document(x: *Exporter) !void {
        const s = x.s;
        const out = x.out;
        try out.print(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"{f}\" height=\"{f}\" viewBox=\"0 0 {f} {f}\">\n",
            .{ num(s.w), num(s.h), num(s.w), num(s.h) },
        );
        try x.gradientDefs();
        const runs = try x.colorMapRuns();
        // Each run remaps the scene drawn before it, so the scene so far
        // is a group the run can reference. Groups nest, innermost first.
        var j = runs.len;
        while (j > 0) {
            j -= 1;
            try out.print("<g id=\"gp-scene{d}\">\n", .{j});
        }
        try out.print("<rect width=\"{f}\" height=\"{f}\" fill=\"{f}\"/>\n", .{ num(s.w), num(s.h), rgb(s.bg) });

        var i: usize = 0;
        var run_index: usize = 0;
        while (i < s.items.len) {
            try x.syncLayer(i);
            if (run_index < runs.len and runs[run_index].first == i) {
                try x.closeLayer();
                try out.writeAll("</g>\n");
                try x.colorMapRun(runs, run_index);
                i = runs[run_index].end;
                run_index += 1;
                continue;
            }
            const d = &s.items[i].draw;
            assert(d.style.color_map == null);
            try x.draw(d, .paint);
            i += 1;
        }
        assert(run_index == runs.len);
        try x.closeLayer();
        try out.writeAll("</svg>\n");
    }

    /// Close the layer group that ended before item `i` and open the one
    /// holding it. A layer split by a colorMap run reopens without its id.
    fn syncLayer(x: *Exporter, i: usize) !void {
        const layers = x.s.layers;
        while (x.layer_index < layers.len and i >= layers[x.layer_index].item_end) {
            try x.closeLayer();
            x.layer_named = false;
            x.layer_index += 1;
        }
        if (x.layer_index >= layers.len) return;
        const layer = layers[x.layer_index];
        if (i < layer.item_first or x.layer_open or layer.name.len == 0) return;
        if (x.layer_named) {
            try x.out.writeAll("<g>\n");
        } else {
            try x.out.print("<g id=\"{f}\">\n", .{xmlText(layer.name)});
            x.layer_named = true;
        }
        x.layer_open = true;
    }

    fn closeLayer(x: *Exporter) !void {
        if (!x.layer_open) return;
        try x.out.writeAll("</g>\n");
        x.layer_open = false;
    }

    fn colorMapRuns(x: *Exporter) ![]const Run {
        var runs: std.ArrayList(Run) = .empty;
        var layer: usize = 0;
        var prev_layer: usize = 0;
        for (x.s.items, 0..) |*item, i| {
            const layers = x.s.layers;
            while (layer < layers.len and i >= layers[layer].item_end) layer += 1;
            defer prev_layer = layer;
            const cm = item.draw.style.color_map orelse continue;
            if (runs.items.len > 0) {
                const last = &runs.items[runs.items.len - 1];
                if (last.end == i and last.key == cm.key and prev_layer == layer) {
                    last.end = i + 1;
                    continue;
                }
            }
            try runs.append(x.arena, .{ .first = i, .end = i + 1, .key = cm.key });
        }
        return runs.items;
    }

    fn colorMapRun(x: *Exporter, runs: []const Run, j: usize) !void {
        const out = x.out;
        const s = x.s;
        const run = runs[j];
        try out.print("<defs>\n<g id=\"gp-cms{d}\">\n", .{j});
        for (s.items[run.first..run.end]) |*item| try x.draw(&item.draw, .mask);
        try out.print(
            "</g>\n<mask id=\"gp-cmm{d}\" maskUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"{f}\" height=\"{f}\">\n<rect width=\"{f}\" height=\"{f}\" fill=\"black\"/>\n<use xlink:href=\"#gp-cms{d}\" color=\"white\"/>\n",
            .{ j, num(s.w), num(s.h), num(s.w), num(s.h), j },
        );
        // A pixel an earlier run with this matrix remapped stays as it is.
        for (runs[0..j], 0..) |earlier, k| {
            if (earlier.key == run.key) try out.print("<use xlink:href=\"#gp-cms{d}\" color=\"black\"/>\n", .{k});
        }
        const m = s.items[run.first].draw.style.color_map.?.m;
        try out.print(
            "</mask>\n<filter id=\"gp-cmf{d}\" filterUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"{f}\" height=\"{f}\" color-interpolation-filters=\"sRGB\"><feColorMatrix type=\"matrix\" values=\"",
            .{ j, num(s.w), num(s.h) },
        );
        for (m) |row| try out.print("{d} {d} {d} 0 {d} ", .{ row[0], row[1], row[2], row[3] });
        try out.print(
            "0 0 0 1 0\"/></filter>\n</defs>\n<g filter=\"url(#gp-cmf{d})\" mask=\"url(#gp-cmm{d})\"><use xlink:href=\"#gp-scene{d}\"/></g>\n",
            .{ j, j, j },
        );
    }

    fn gradientDefs(x: *Exporter) !void {
        var any = false;
        for (x.s.items) |*item| {
            const d = &item.draw;
            if (d.style.color_map != null) continue;
            const used = [2]?scene.Paint{
                if (fills(d)) d.style.fill else null,
                if (strokes(d)) d.style.stroke else null,
            };
            for (used) |paint| {
                const g = switch (paint orelse continue) {
                    .gradient => |g| g,
                    .none, .solid => continue,
                };
                if (degenerate(g)) continue;
                const gop = try x.gradient_ids.getOrPut(x.arena, g);
                if (gop.found_existing) continue;
                gop.value_ptr.* = x.gradient_ids.count() - 1;
                if (!any) try x.out.writeAll("<defs>\n");
                any = true;
                try x.gradient(g, gop.value_ptr.*);
            }
        }
        if (any) try x.out.writeAll("</defs>\n");
    }

    /// The rasterizer samples the stops at t clamped to 0..1, so the
    /// gradient is written as that function on 0..1: its ends, then every
    /// stop strictly between them.
    fn gradient(x: *Exporter, g: *const scene.Gradient, id: u32) !void {
        const out = x.out;
        switch (g.geometry) {
            .linear => |l| try out.print(
                "<linearGradient id=\"gp-g{d}\" gradientUnits=\"userSpaceOnUse\" x1=\"{f}\" y1=\"{f}\" x2=\"{f}\" y2=\"{f}\">\n",
                .{ id, num(l.a[0]), num(l.a[1]), num(l.b[0]), num(l.b[1]) },
            ),
            .radial => |r| try out.print(
                "<radialGradient id=\"gp-g{d}\" gradientUnits=\"userSpaceOnUse\" cx=\"{f}\" cy=\"{f}\" r=\"{f}\">\n",
                .{ id, num(r.c[0]), num(r.c[1]), num(r.r) },
            ),
        }
        try writeStop(out, 0, scene.samplePalette(g.stops, 0));
        for (g.stops) |st| if (st.offset > 0 and st.offset < 1) try writeStop(out, st.offset, st.color);
        try writeStop(out, 1, scene.samplePalette(g.stops, 1));
        try out.writeAll(switch (g.geometry) {
            .linear => "</linearGradient>\n",
            .radial => "</radialGradient>\n",
        });
    }

    fn draw(x: *Exporter, d: *const scene.Draw, mode: Mode) !void {
        if (d.shape == .field) return x.fieldImage(d, mode);
        const st = &d.style;
        x.fill_d.clear();
        x.stroke_d.clear();
        if (fills(d)) try x.fill_d.fillOf(x.arena, d.shape);
        var extra: ?Extra = null;
        if (strokes(d)) extra = try x.stroke_d.strokeOf(x.arena, d.shape, st);

        const fill = x.fill_d.bytes.items;
        const stroke = x.stroke_d.bytes.items;
        const together = fill.len > 0 and std.mem.eql(u8, fill, stroke) and st.blend == .normal;
        if (together) {
            try x.out.print("<path d=\"{s}\"", .{fill});
            try x.fillAttrs(st, st.fill, mode);
            try x.strokeAttrs(st, mode);
            return x.endElement(st, mode);
        }
        if (fill.len > 0) {
            try x.out.print("<path d=\"{s}\"", .{fill});
            try x.fillAttrs(st, st.fill, mode);
            try x.endElement(st, mode);
        }
        if (stroke.len > 0) {
            try x.out.print("<path d=\"{s}\" fill=\"none\"", .{stroke});
            try x.strokeAttrs(st, mode);
            try x.endElement(st, mode);
        }
        if (extra) |e| try x.extraElement(e, st, mode);
    }

    /// A stroke the rasterizer draws as a filled disc or square, written
    /// as a fill in the stroke's paint.
    fn extraElement(x: *Exporter, e: Extra, st: *const Style, mode: Mode) !void {
        x.fill_d.clear();
        switch (e) {
            .disc => |disc| try x.fill_d.ellipse(x.arena, disc.c, disc.r, disc.r),
            .square => |sq| try x.fill_d.rectangle(x.arena, sq.c[0] - sq.hw, sq.c[1] - sq.hw, 2 * sq.hw, 2 * sq.hw),
        }
        try x.out.print("<path d=\"{s}\"", .{x.fill_d.bytes.items});
        switch (mode) {
            .mask => try x.out.writeAll(" fill=\"currentColor\""),
            .paint => try x.paintAttrs("fill", st.stroke, st.opacity * st.stroke_opacity),
        }
        try x.endElement(st, mode);
    }

    fn fillAttrs(x: *Exporter, st: *const Style, paint: scene.Paint, mode: Mode) !void {
        switch (mode) {
            .mask => try x.out.writeAll(" fill=\"currentColor\""),
            .paint => try x.paintAttrs("fill", paint, st.opacity * st.fill_opacity),
        }
    }

    fn strokeAttrs(x: *Exporter, st: *const Style, mode: Mode) !void {
        const out = x.out;
        switch (mode) {
            .mask => try out.writeAll(" stroke=\"currentColor\""),
            .paint => try x.paintAttrs("stroke", st.stroke, st.opacity * st.stroke_opacity),
        }
        try out.print(" stroke-width=\"{f}\" stroke-linejoin=\"round\"", .{num(st.stroke_width)});
        switch (st.cap) {
            .butt => {},
            .round, .square => try out.print(" stroke-linecap=\"{s}\"", .{@tagName(st.cap)}),
        }
        // Mirrors render.zig: dashes shorter than 1e-3 and negative gaps
        // are clamped there.
        if (st.dash) |dash| {
            try out.print(" stroke-dasharray=\"{f} {f}\"", .{ num(@max(dash[0], 1e-3)), num(@max(dash[1], 0)) });
            if (st.dash_offset != 0) try out.print(" stroke-dashoffset=\"{f}\"", .{num(st.dash_offset)});
        }
    }

    fn paintAttrs(x: *Exporter, comptime attr: []const u8, paint: scene.Paint, alpha: f32) !void {
        const out = x.out;
        var a = alpha;
        switch (paint) {
            .none => return out.writeAll(" " ++ attr ++ "=\"none\""),
            .solid => |c| {
                try out.print(" " ++ attr ++ "=\"{f}\"", .{rgb(c[0..3].*)});
                a *= c[3];
            },
            .gradient => |g| if (degenerate(g)) {
                const c = scene.samplePalette(g.stops, 0);
                try out.print(" " ++ attr ++ "=\"{f}\"", .{rgb(c[0..3].*)});
                a *= c[3];
            } else {
                try out.print(" " ++ attr ++ "=\"url(#gp-g{d})\"", .{x.gradient_ids.get(g).?});
            },
        }
        if (a < 1) try out.print(" " ++ attr ++ "-opacity=\"{f}\"", .{frac(a)});
    }

    fn endElement(x: *Exporter, st: *const Style, mode: Mode) !void {
        if (mode == .paint and st.blend != .normal) {
            try x.out.print(" style=\"mix-blend-mode:{s}\"", .{@tagName(st.blend)});
        }
        try x.out.writeAll("/>\n");
    }

    /// The image is the rasterizer's own pixels for the field at scale 1:
    /// one PNG pixel per canvas pixel under the rectangle, colored at the
    /// pixel center, with edge coverage in alpha.
    fn fieldImage(x: *Exporter, d: *const scene.Draw, mode: Mode) !void {
        const f = &d.shape.field;
        if (mode == .mask) {
            x.fill_d.clear();
            try x.fill_d.rectangle(x.arena, f.x, f.y, f.w, f.h);
            return x.out.print("<path d=\"{s}\" fill=\"currentColor\"/>\n", .{x.fill_d.bytes.items});
        }
        const canvas_w: f64 = @max(1, @round(x.s.w));
        const canvas_h: f64 = @max(1, @round(x.s.h));
        const left = @min(f.x, f.x + f.w);
        const right = @max(f.x, f.x + f.w);
        const top = @min(f.y, f.y + f.h);
        const bottom = @max(f.y, f.y + f.h);
        const x0 = std.math.clamp(@floor(left), 0, canvas_w);
        const x1 = std.math.clamp(@ceil(right), 0, canvas_w);
        const y0 = std.math.clamp(@floor(top), 0, canvas_h);
        const y1 = std.math.clamp(@ceil(bottom), 0, canvas_h);
        if (!(x1 > x0 and y1 > y0)) return;
        const w: u32 = @intFromFloat(x1 - x0);
        const h: u32 = @intFromFloat(y1 - y0);

        const pix = try x.gpa.alloc([4]u8, @as(usize, w) * h);
        defer x.gpa.free(pix);
        const range = f.range orelse f.field.minMax();
        for (0..h) |row| for (0..w) |col| {
            const cx = x0 + @as(f64, @floatFromInt(col)) + 0.5;
            const cy = y0 + @as(f64, @floatFromInt(row)) + 0.5;
            const cov = overlap(cx, left, right) * overlap(cy, top, bottom);
            const p = &pix[row * w + col];
            if (cov <= 0) {
                p.* = .{ 0, 0, 0, 0 };
                continue;
            }
            const c = render.fieldColor(f, range, cx, cy);
            p.* = .{ to8(c[0]), to8(c[1]), to8(c[2]), to8(cov * c[3]) };
        };
        const png = try image_io.encodePngRgba(x.gpa, w, h, pix);
        defer x.gpa.free(png);

        const out = x.out;
        try out.print(
            "<image x=\"{f}\" y=\"{f}\" width=\"{d}\" height=\"{d}\" preserveAspectRatio=\"none\" image-rendering=\"optimizeSpeed\"",
            .{ num(x0), num(y0), w, h },
        );
        const alpha = d.style.opacity * d.style.fill_opacity;
        if (alpha < 1) try out.print(" opacity=\"{f}\"", .{frac(alpha)});
        if (d.style.blend != .normal) try out.print(" style=\"mix-blend-mode:{s}\"", .{@tagName(d.style.blend)});
        try out.writeAll(" xlink:href=\"data:image/png;base64,");
        try std.base64.standard.Encoder.encodeWriter(out, png);
        try out.writeAll("\"/>\n");
    }
};

fn writeStop(out: *Writer, offset: f32, c: scene.Rgba) !void {
    try out.print("<stop offset=\"{f}\" stop-color=\"{f}\"", .{ frac(offset), rgb(c[0..3].*) });
    if (c[3] < 1) try out.print(" stop-opacity=\"{f}\"", .{frac(c[3])});
    try out.writeAll("/>\n");
}

/// The rasterizer paints these with the first stop's color everywhere.
fn degenerate(g: *const scene.Gradient) bool {
    return switch (g.geometry) {
        .linear => |l| l.a[0] == l.b[0] and l.a[1] == l.b[1],
        .radial => |r| !(r.r > 0),
    };
}

/// Overlap of the pixel footprint [v - 0.5, v + 0.5] with [lo, hi], as in
/// coverage.zig.
fn overlap(v: f64, lo: f64, hi: f64) f32 {
    const o = @min(v + 0.5, hi) - @max(v - 0.5, lo);
    return @floatCast(std.math.clamp(o, 0, 1));
}

fn to8(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

/// A stroke the rasterizer draws as a shape of its own: a dot where all
/// of a stroke's points coincide, or the disc a circle of radius r <= 0
/// strokes.
const Extra = union(enum) {
    disc: struct { c: Vec2, r: f64 },
    square: struct { c: Vec2, hw: f64 },
};

/// SVG path data built up for one element.
const Path = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn clear(p: *Path) void {
        p.bytes.clearRetainingCapacity();
    }

    fn cmd(p: *Path, arena: Allocator, c: u8, v: Vec2) !void {
        try p.bytes.print(arena, "{c}{f} {f}", .{ c, num(v[0]), num(v[1]) });
    }

    fn close(p: *Path, arena: Allocator) !void {
        try p.bytes.append(arena, 'Z');
    }

    /// Elliptic arc from angle a0, where the path already is, to a1, in
    /// pieces of at most a quarter turn. Radii may be negative, as the
    /// rasterizer's flattening allows.
    fn arcTo(p: *Path, arena: Allocator, c: Vec2, rx: f64, ry: f64, a0: f64, a1: f64) !void {
        if (a1 == a0) return;
        const pieces: u32 = @intFromFloat(std.math.clamp(@ceil(@abs(a1 - a0) / (std.math.pi / 2.0)), 1, 1 << 16));
        const sweep: u8 = if ((a1 > a0) != (rx * ry < 0)) '1' else '0';
        for (1..pieces + 1) |i| {
            const t = a0 + (a1 - a0) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(pieces));
            const e = ellipsePoint(c, rx, ry, t);
            try p.bytes.print(arena, "A{f} {f} 0 0 {c} {f} {f}", .{ num(@abs(rx)), num(@abs(ry)), sweep, num(e[0]), num(e[1]) });
        }
    }

    /// Starts at angle 0 and turns toward +y, where render.zig starts, so
    /// dashes line up.
    fn ellipse(p: *Path, arena: Allocator, c: Vec2, rx: f64, ry: f64) !void {
        try p.cmd(arena, 'M', ellipsePoint(c, rx, ry, 0));
        try p.arcTo(arena, c, rx, ry, 0, 2 * std.math.pi);
        try p.close(arena);
    }

    fn rectangle(p: *Path, arena: Allocator, x: f64, y: f64, w: f64, h: f64) !void {
        try p.poly(arena, &.{ .{ x, y }, .{ x + w, y }, .{ x + w, y + h }, .{ x, y + h } }, true);
    }

    /// The rasterizer's rounded rectangle: radii clamped to half the
    /// sides, starting at the top edge's right end and turning clockwise.
    fn roundedRect(p: *Path, arena: Allocator, x: f64, y: f64, w: f64, h: f64, rx_in: f64, ry_in: f64) !void {
        const rx = @min(if (rx_in > 0) rx_in else ry_in, w / 2);
        const ry = @min(if (ry_in > 0) ry_in else rx_in, h / 2);
        const corners = [_]struct { c: Vec2, a: f64 }{
            .{ .c = .{ x + w - rx, y + ry }, .a = -std.math.pi / 2.0 },
            .{ .c = .{ x + w - rx, y + h - ry }, .a = 0 },
            .{ .c = .{ x + rx, y + h - ry }, .a = std.math.pi / 2.0 },
            .{ .c = .{ x + rx, y + ry }, .a = std.math.pi },
        };
        for (corners, 0..) |cn, i| {
            try p.cmd(arena, if (i == 0) 'M' else 'L', ellipsePoint(cn.c, rx, ry, cn.a));
            try p.arcTo(arena, cn.c, rx, ry, cn.a, cn.a + std.math.pi / 2.0);
        }
        try p.close(arena);
    }

    fn poly(p: *Path, arena: Allocator, pts: []const Vec2, closed: bool) !void {
        for (pts, 0..) |v, i| try p.cmd(arena, if (i == 0) 'M' else 'L', v);
        if (closed) try p.close(arena);
    }

    fn fillOf(p: *Path, arena: Allocator, shape: Shape) !void {
        switch (shape) {
            .circle => |c| if (c.r > 0) try p.ellipse(arena, c.c, c.r, c.r),
            .ellipse => |e| try p.ellipse(arena, e.c, e.rx, e.ry),
            .rect => |r| if (r.rx > 0 or r.ry > 0)
                try p.roundedRect(arena, r.x, r.y, r.w, r.h, r.rx, r.ry)
            else
                try p.rectangle(arena, r.x, r.y, r.w, r.h),
            .polygon => |pts| if (pts.len > 0) try p.poly(arena, pts, true),
            .arc => |a| {
                try p.cmd(arena, 'M', a.c);
                try p.cmd(arena, 'L', ellipsePoint(a.c, a.r, a.r, a.start));
                try p.arcTo(arena, a.c, a.r, a.r, a.start, a.end);
                try p.close(arena);
            },
            .compound => |contours| for (contours) |c| if (c.len > 0) try p.poly(arena, c, true),
            .line, .polyline, .bezier, .spline, .field => unreachable, // fills() is false for these
        }
    }

    /// Stroke geometry as render.zig strokes it. Returns the shape the
    /// stroke becomes instead when all its points coincide.
    fn strokeOf(p: *Path, arena: Allocator, shape: Shape, st: *const Style) !?Extra {
        const hw = st.stroke_width / 2;
        const dashed = st.dash != null;
        switch (shape) {
            .circle => |c| {
                if (c.r > 0) {
                    try p.ellipse(arena, c.c, c.r, c.r);
                } else if (!dashed) {
                    // strokeRing covers |dist - r| < hw, a disc of radius r + hw.
                    if (c.r + hw > 0) return .{ .disc = .{ .c = c.c, .r = c.r + hw } };
                } else if (c.r < 0) {
                    try p.ellipse(arena, c.c, c.r, c.r);
                }
                return null;
            },
            .line => |l| return p.openStroke(arena, &l, 2, st),
            .polyline => |pts| return p.openStroke(arena, pts, pts.len, st),
            .polygon => |pts| return p.closedStroke(arena, pts, pts.len, st),
            .rect => |r| {
                if (r.w == 0 and r.h == 0) return closedDot(.{ r.x, r.y }, 4, st);
                if (r.rx > 0 or r.ry > 0) {
                    try p.roundedRect(arena, r.x, r.y, r.w, r.h, r.rx, r.ry);
                } else {
                    try p.rectangle(arena, r.x, r.y, r.w, r.h);
                }
                return null;
            },
            .ellipse => |e| {
                if (e.rx == 0 and e.ry == 0) return closedDot(e.c, 64, st);
                try p.ellipse(arena, e.c, e.rx, e.ry);
                return null;
            },
            .arc => |a| {
                const start = ellipsePoint(a.c, a.r, a.r, a.start);
                if (a.r == 0 or a.start == a.end) return openDot(start, 9, st);
                try p.cmd(arena, 'M', start);
                try p.arcTo(arena, a.c, a.r, a.r, a.start, a.end);
                return null;
            },
            .bezier => |b| {
                if (allSame(&b)) return openDot(b[0], 5, st);
                try p.cmd(arena, 'M', b[0]);
                try p.bytes.print(arena, "C{f} {f} {f} {f} {f} {f}", .{
                    num(b[1][0]), num(b[1][1]), num(b[2][0]), num(b[2][1]), num(b[3][0]), num(b[3][1]),
                });
                return null;
            },
            .spline => |pts| {
                if (pts.len < 2) return null;
                if (allSame(pts)) return openDot(pts[0], 5, st);
                try p.cmd(arena, 'M', pts[0]);
                for (0..pts.len - 1) |i| {
                    const p0 = pts[if (i == 0) 0 else i - 1];
                    const p1 = pts[i];
                    const p2 = pts[i + 1];
                    const p3 = pts[@min(i + 2, pts.len - 1)];
                    try p.bytes.print(arena, "C{f} {f} {f} {f} {f} {f}", .{
                        num(p1[0] + (p2[0] - p0[0]) / 6), num(p1[1] + (p2[1] - p0[1]) / 6),
                        num(p2[0] - (p3[0] - p1[0]) / 6), num(p2[1] - (p3[1] - p1[1]) / 6),
                        num(p2[0]),                       num(p2[1]),
                    });
                }
                return null;
            },
            .compound => |contours| {
                for (contours) |c| {
                    if (c.len == 0) continue;
                    if (!allSame(c)) {
                        try p.poly(arena, c, true);
                        continue;
                    }
                    if (closedDot(c[0], c.len, st) == null) continue;
                    // A tiny circle stroked at this width is the dot, kept in
                    // this path so the contours composite once together.
                    const e = 1e-3;
                    try p.ellipse(arena, c[0], e, e);
                }
                return null;
            },
            .field => unreachable, // strokes() is false for fields
        }
    }

    fn openStroke(p: *Path, arena: Allocator, pts: []const Vec2, len: usize, st: *const Style) !?Extra {
        if (len == 0) return null;
        if (allSame(pts)) return openDot(pts[0], len, st);
        try p.poly(arena, pts, false);
        return null;
    }

    fn closedStroke(p: *Path, arena: Allocator, pts: []const Vec2, len: usize, st: *const Style) !?Extra {
        if (len == 0) return null;
        if (allSame(pts)) return closedDot(pts[0], len, st);
        try p.poly(arena, pts, true);
        return null;
    }
};

/// An open stroke of `count` coincident points. strokePolyline gives one
/// point a dot only with round caps. A single segment uses the style's
/// caps at both ends, and longer runs have a round join on every segment.
/// A dash pattern over zero length draws nothing.
fn openDot(c: Vec2, count: usize, st: *const Style) ?Extra {
    const hw = st.stroke_width / 2;
    if (st.dash != null) return null;
    if (count >= 3 or st.cap == .round) return .{ .disc = .{ .c = c, .r = hw } };
    if (count == 2 and st.cap == .square) return .{ .square = .{ .c = c, .hw = hw } };
    return null;
}

/// A closed stroke of `count` coincident points. Every closed segment
/// has round joins at both ends.
fn closedDot(c: Vec2, count: usize, st: *const Style) ?Extra {
    if (st.dash != null) return null;
    if (count >= 2 or st.cap == .round) return .{ .disc = .{ .c = c, .r = st.stroke_width / 2 } };
    return null;
}

fn allSame(pts: []const Vec2) bool {
    for (pts[1..]) |v| if (v[0] != pts[0][0] or v[1] != pts[0][1]) return false;
    return true;
}

fn ellipsePoint(c: Vec2, rx: f64, ry: f64, t: f64) Vec2 {
    return .{ c[0] + rx * math.cos(t), c[1] + ry * math.sin(t) };
}

/// A coordinate rounded to 1/1000 of a unit.
const Num = struct {
    v: f64,
    scale: f64,

    pub fn format(n: Num, w: *Writer) Writer.Error!void {
        const r = @round(n.v * n.scale) / n.scale;
        try w.print("{d}", .{if (r == 0) 0 else r});
    }
};

fn num(v: f64) Num {
    return .{ .v = v, .scale = 1000 };
}

fn frac(v: f32) Num {
    return .{ .v = v, .scale = 10000 };
}

const Rgb = struct {
    c: [3]f32,

    pub fn format(r: Rgb, w: *Writer) Writer.Error!void {
        try w.print("rgb({d},{d},{d})", .{ to8(r.c[0]), to8(r.c[1]), to8(r.c[2]) });
    }
};

fn rgb(c: [3]f32) Rgb {
    return .{ .c = c };
}

const XmlText = struct {
    s: []const u8,

    pub fn format(t: XmlText, w: *Writer) Writer.Error!void {
        for (t.s) |ch| switch (ch) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            else => try w.writeByte(ch),
        };
    }
};

fn xmlText(s: []const u8) XmlText {
    return .{ .s = s };
}

fn testDoc(gpa: Allocator, s: *const scene.Scene) ![]u8 {
    var doc: Writer.Allocating = .init(gpa);
    errdefer doc.deinit();
    try write(gpa, &doc.writer, s);
    return doc.toOwnedSlice();
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("missing: {s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

fn testProblem(s: *const scene.Scene) ![]const u8 {
    const p = check(s) orelse return error.TestExpectedProblem;
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    var w: Writer = .fixed(&S.buf);
    try w.print("{f}", .{p});
    return w.buffered();
}

const red: scene.Paint = .{ .solid = .{ 1, 0, 0, 1 } };

test "svg: a post pass is refused at the line that added it" {
    const items = [_]scene.Item{
        .{ .draw = .{ .shape = .{ .circle = .{ .c = .{ 5, 5 }, .r = 2 } }, .style = .{ .fill = red } } },
        .{ .pass = .{ .pass = .invert, .name = "invert", .where = "art.lua:7" } },
    };
    const s: scene.Scene = .{ .w = 10, .h = 10, .bg = .{ 0, 0, 0 }, .items = &items };
    try std.testing.expectEqualStrings("art.lua:7: gen.post.invert needs pixels and has no vector form", try testProblem(&s));
}

test "svg: blend add, falling stops and out of range values are refused" {
    const stops = [_]scene.Stop{ .{ .offset = 0.6, .color = .{ 0, 0, 0, 1 } }, .{ .offset = 0.2, .color = .{ 1, 1, 1, 1 } } };
    const g: scene.Gradient = .{ .geometry = .{ .radial = .{ .c = .{ 5, 5 }, .r = 4 } }, .stops = &stops };
    const circle: Shape = .{ .circle = .{ .c = .{ 5, 5 }, .r = 2 } };
    const cases = [_]struct { style: Style, want: []const u8 }{
        .{ .style = .{ .fill = red, .blend = .add }, .want = "draw 1 (circle): blendMode 'add' has no SVG form. Write a PNG instead" },
        .{ .style = .{ .fill = .{ .gradient = &g } }, .want = "draw 1 (circle): gradient stop offsets go down, and SVG would reorder them. Write a PNG instead" },
        .{ .style = .{ .fill = .{ .solid = .{ 1.5, 0, 0, 1 } } }, .want = "draw 1 (circle): a color channel lies outside 0 to 1, which SVG clamps and the PNG does not. Write a PNG instead" },
        .{ .style = .{ .stroke = red, .stroke_opacity = 2 }, .want = "draw 1 (circle): an opacity lies outside 0 to 1, which SVG clamps and the PNG does not. Write a PNG instead" },
    };
    for (cases) |c| {
        const items = [_]scene.Item{.{ .draw = .{ .shape = circle, .style = c.style } }};
        const s: scene.Scene = .{ .w = 10, .h = 10, .bg = .{ 0, 0, 0 }, .items = &items };
        try std.testing.expectEqualStrings(c.want, try testProblem(&s));
    }
}

test "svg: values the rasterizer never paints are not checked" {
    const items = [_]scene.Item{
        // An open shape has no fill, and a colorMap ignores its paint.
        .{ .draw = .{ .shape = .{ .line = .{ .{ 0, 0 }, .{ 5, 5 } } }, .style = .{ .fill = .{ .solid = .{ 9, 0, 0, 1 } }, .stroke = red } } },
        .{ .draw = .{ .shape = .{ .rect = .{ .x = 0, .y = 0, .w = 3, .h = 3 } }, .style = .{ .fill = red, .blend = .add, .color_map = .{ .m = @splat(@splat(0)), .key = 0 } } } },
    };
    const s: scene.Scene = .{ .w = 10, .h = 10, .bg = .{ 0, 0, 0 }, .items = &items };
    try std.testing.expectEqual(@as(?Problem, null), check(&s));
}

test "svg: background, round joins, alpha as fill-opacity, no fill on open shapes" {
    const gpa = std.testing.allocator;
    const items = [_]scene.Item{
        .{ .draw = .{ .shape = .{ .rect = .{ .x = 1, .y = 1, .w = 4, .h = 4 } }, .style = .{
            .fill = .{ .solid = .{ 0, 0, 1, 0.5 } },
            .stroke = red,
            .opacity = 0.5,
            .stroke_width = 2,
        } } },
        .{ .draw = .{ .shape = .{ .polyline = &.{ .{ 0, 0 }, .{ 5, 0 }, .{ 5, 5 } } }, .style = .{ .fill = red, .stroke = red } } },
    };
    const s: scene.Scene = .{ .w = 10, .h = 10, .bg = .{ 0, 0, 0 }, .items = &items };
    const doc = try testDoc(gpa, &s);
    defer gpa.free(doc);
    try expectContains(doc, "<rect width=\"10\" height=\"10\" fill=\"rgb(0,0,0)\"/>");
    try expectContains(doc, "<path d=\"M1 1L5 1L5 5L1 5Z\" fill=\"rgb(0,0,255)\" fill-opacity=\"0.25\" stroke=\"rgb(255,0,0)\" stroke-opacity=\"0.5\" stroke-width=\"2\" stroke-linejoin=\"round\"/>");
    try expectContains(doc, "<path d=\"M0 0L5 0L5 5\" fill=\"none\" stroke=\"rgb(255,0,0)\" stroke-width=\"1\" stroke-linejoin=\"round\"/>");
    try std.testing.expect(std.mem.indexOf(u8, doc, " opacity=") == null);
}

test "svg: an arc fills as a pie and strokes open, and blends split fill from stroke" {
    const gpa = std.testing.allocator;
    const items = [_]scene.Item{.{ .draw = .{
        .shape = .{ .arc = .{ .c = .{ 10, 10 }, .r = 5, .start = 0, .end = std.math.pi } },
        .style = .{ .fill = red, .stroke = red, .blend = .multiply },
    } }};
    const s: scene.Scene = .{ .w = 20, .h = 20, .bg = .{ 1, 1, 1 }, .items = &items };
    const doc = try testDoc(gpa, &s);
    defer gpa.free(doc);
    try expectContains(doc, "<path d=\"M10 10L15 10A5 5 0 0 1 10 15A5 5 0 0 1 5 10Z\" fill=\"rgb(255,0,0)\" style=\"mix-blend-mode:multiply\"/>");
    try expectContains(doc, "<path d=\"M15 10A5 5 0 0 1 10 15A5 5 0 0 1 5 10\" fill=\"none\" stroke=\"rgb(255,0,0)\"");
}

test "svg: a gradient is written as the rasterizer samples it on 0 to 1" {
    const gpa = std.testing.allocator;
    const stops = [_]scene.Stop{ .{ .offset = -1, .color = .{ 0, 0, 0, 1 } }, .{ .offset = 0.5, .color = .{ 1, 0, 0, 0.5 } }, .{ .offset = 3, .color = .{ 1, 1, 1, 1 } } };
    const g: scene.Gradient = .{ .geometry = .{ .linear = .{ .a = .{ 0, 0 }, .b = .{ 10, 0 } } }, .stops = &stops };
    const flat: scene.Gradient = .{ .geometry = .{ .radial = .{ .c = .{ 0, 0 }, .r = 0 } }, .stops = &stops };
    const items = [_]scene.Item{
        .{ .draw = .{ .shape = .{ .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 } }, .style = .{ .fill = .{ .gradient = &g } } } },
        .{ .draw = .{ .shape = .{ .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 } }, .style = .{ .fill = .{ .gradient = &g } } } },
        .{ .draw = .{ .shape = .{ .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 } }, .style = .{ .fill = .{ .gradient = &flat } } } },
    };
    const s: scene.Scene = .{ .w = 10, .h = 10, .bg = .{ 0, 0, 0 }, .items = &items };
    const doc = try testDoc(gpa, &s);
    defer gpa.free(doc);
    try expectContains(doc,
        \\<stop offset="0" stop-color="rgb(170,0,0)" stop-opacity="0.6667"/>
        \\<stop offset="0.5" stop-color="rgb(255,0,0)" stop-opacity="0.5"/>
        \\<stop offset="1" stop-color="rgb(255,51,51)" stop-opacity="0.6"/>
    );
    try std.testing.expectEqual(1, std.mem.count(u8, doc, "<linearGradient"));
    // A zero radius paints the first sample everywhere, as render.zig does.
    try expectContains(doc, "fill=\"rgb(170,0,0)\" fill-opacity=\"0.6667\"/>");
}

test "svg: a colorMap remaps the scene drawn before it, once per matrix" {
    const gpa = std.testing.allocator;
    const cm: scene.ColorMap = .{ .m = .{ .{ -1, 0, 0, 1 }, .{ 0, -1, 0, 1 }, .{ 0, 0, -1, 1 } }, .key = 0 };
    const square: Shape = .{ .rect = .{ .x = 0, .y = 0, .w = 4, .h = 4 } };
    const items = [_]scene.Item{
        .{ .draw = .{ .shape = square, .style = .{ .fill = red } } },
        .{ .draw = .{ .shape = square, .style = .{ .fill = red, .color_map = cm } } },
        .{ .draw = .{ .shape = square, .style = .{ .fill = red } } },
        .{ .draw = .{ .shape = square, .style = .{ .fill = red, .color_map = cm } } },
    };
    const s: scene.Scene = .{ .w = 10, .h = 10, .bg = .{ 0, 0, 0 }, .items = &items };
    const doc = try testDoc(gpa, &s);
    defer gpa.free(doc);
    const open1 = std.mem.indexOf(u8, doc, "<g id=\"gp-scene1\">").?;
    const open0 = std.mem.indexOf(u8, doc, "<g id=\"gp-scene0\">").?;
    const use0 = std.mem.indexOf(u8, doc, "<use xlink:href=\"#gp-scene0\"/>").?;
    const use1 = std.mem.indexOf(u8, doc, "<use xlink:href=\"#gp-scene1\"/>").?;
    try std.testing.expect(open1 < open0);
    try std.testing.expect(open0 < use0);
    try std.testing.expect(use0 < use1);
    // The second run leaves alone what the first remapped.
    try expectContains(doc, "<use xlink:href=\"#gp-cms0\" color=\"black\"/>");
    try expectContains(doc, "values=\"-1 0 0 0 1 0 -1 0 0 1 0 0 -1 0 1 0 0 0 1 0\"");
}

test "svg: dots the rasterizer draws for coincident points" {
    const gpa = std.testing.allocator;
    const items = [_]scene.Item{
        .{ .draw = .{ .shape = .{ .line = .{ .{ 3, 3 }, .{ 3, 3 } } }, .style = .{ .stroke = red, .stroke_width = 2, .cap = .square } } },
        .{ .draw = .{ .shape = .{ .circle = .{ .c = .{ 8, 8 }, .r = 0 } }, .style = .{ .stroke = red, .stroke_width = 2 } } },
        .{ .draw = .{ .shape = .{ .line = .{ .{ 5, 5 }, .{ 5, 5 } } }, .style = .{ .stroke = red, .stroke_width = 2 } } },
    };
    const s: scene.Scene = .{ .w = 10, .h = 10, .bg = .{ 0, 0, 0 }, .items = &items };
    const doc = try testDoc(gpa, &s);
    defer gpa.free(doc);
    try expectContains(doc, "<path d=\"M2 2L4 2L4 4L2 4Z\" fill=\"rgb(255,0,0)\"/>");
    try expectContains(doc, "<path d=\"M9 8A1 1 0 0 1 8 9A1 1 0 0 1 7 8A1 1 0 0 1 8 7A1 1 0 0 1 9 8Z\" fill=\"rgb(255,0,0)\"/>");
    // A butt-capped zero-length line draws nothing.
    try std.testing.expectEqual(2, std.mem.count(u8, doc, "<path"));
}

test "svg: leaving passes out keeps every draw in its layer" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const dot: scene.Item = .{ .draw = .{ .shape = .{ .circle = .{ .c = .{ 5, 5 }, .r = 2 } }, .style = .{ .fill = red } } };
    const pass: scene.Item = .{ .pass = .{ .pass = .invert, .name = "invert", .where = "a.lua:2" } };
    const items = [_]scene.Item{ dot, pass, dot, pass, dot };
    const layers = [_]scene.Layer{ .{ .name = "a", .item_first = 0, .item_end = 2 }, .{ .name = "b", .item_first = 2, .item_end = 5 } };
    const s: scene.Scene = .{ .w = 10, .h = 10, .bg = .{ 0, 0, 0 }, .items = &items, .layers = &layers };
    try std.testing.expectEqual(2, passCount(&s));
    const v = try withoutPasses(arena_state.allocator(), &s);
    try std.testing.expectEqual(3, v.items.len);
    try std.testing.expectEqual(null, check(&v));
    try std.testing.expectEqual(1, v.layers[0].item_end);
    try std.testing.expectEqual(1, v.layers[1].item_first);
    try std.testing.expectEqual(3, v.layers[1].item_end);
}
