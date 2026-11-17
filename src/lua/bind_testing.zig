//! The `testing` global, which only the test runner (src/test_runner.zig)
//! installs next to `gen`. Test scripts reach genpuin's math and render
//! other scripts through it, without a shell.
//!
//! bits(x) and num(hex) convert between a number and its IEEE bit pattern
//! as 16 hex digits. call(name, x, y) runs one src/math.zig function from
//! Zig. render(script, path, {scale, ss, depth}) runs a script in a fresh
//! state as the CLI would and writes the canvas it returns to path.

const std = @import("std");

const zlua = @import("zlua");
const math = @import("genpuin").math;

const core = @import("core.zig");
const host_mod = @import("host.zig");
const util = @import("util.zig");
const Lua = util.Lua;

pub const Config = struct {
    /// The runner's own path, for arg[-1] in rendered scripts.
    exe: []const u8,
    /// Prelude directory for rendered scripts, as GENPUIN_LUA_DIR.
    lua_dir: ?[]const u8 = null,
};

const functions = [_]zlua.FnReg{
    .{ .name = "bits", .func = zlua.wrap(bits) },
    .{ .name = "num", .func = zlua.wrap(num) },
    .{ .name = "call", .func = zlua.wrap(call) },
    .{ .name = "render", .func = zlua.wrap(render) },
};

const config_key = "genpuin.testing";
const exit_key = "genpuin.testing.exit";

/// Set the global `testing` and replace os.exit, which would end the
/// runner, with one that records its code and raises an error.
/// `config` must outlive the state.
pub fn install(lua: *Lua, config: *const Config) void {
    lua.pushLightUserdata(config);
    lua.setField(zlua.registry_index, config_key);

    lua.newTable();
    util.setFuncs(lua, &functions);
    lua.setGlobal("testing");

    _ = lua.getGlobal("os");
    lua.pushFunction(zlua.wrap(exit));
    lua.setField(-2, "exit");
    lua.pop(1);
}

/// The code of the first os.exit the script called, or null if none.
pub fn exitCode(lua: *Lua) ?i32 {
    defer lua.pop(1);
    if (lua.getField(zlua.registry_index, exit_key) != .number) return null;
    const code = lua.toInteger(-1) catch return 1;
    return std.math.cast(i32, code) orelse 1;
}

/// os.exit(code?) with Lua's meaning of the code: true or none is 0,
/// false is 1.
fn exit(lua: *Lua) i32 {
    const code: zlua.Integer = switch (lua.typeOf(1)) {
        .none, .nil => 0,
        .boolean => if (lua.toBoolean(1)) 0 else 1,
        else => lua.checkInteger(1),
    };
    if (lua.getField(zlua.registry_index, exit_key) == .nil) {
        lua.pushInteger(code);
        lua.setField(zlua.registry_index, exit_key);
    }
    lua.pop(1);
    lua.raiseErrorStr("os.exit(%d)", .{@as(c_int, @intCast(std.math.clamp(code, std.math.minInt(c_int), std.math.maxInt(c_int))))});
}

/// The src/math.zig function called `name`, applied to x, or to x and y
/// when it takes two. Null for an unknown name.
pub fn byName(name: []const u8, x: f64, y: f64) ?f64 {
    inline for (unary) |e| if (std.mem.eql(u8, name, e[0])) return e[1](x);
    inline for (binary) |e| if (std.mem.eql(u8, name, e[0])) return e[1](x, y);
    return null;
}

const unary = .{
    .{ "sin", math.sin },     .{ "cos", math.cos },   .{ "tan", math.tan },
    .{ "asin", math.asin },   .{ "acos", math.acos }, .{ "atan", math.atan },
    .{ "sinh", math.sinh },   .{ "cosh", math.cosh }, .{ "tanh", math.tanh },
    .{ "exp", math.exp },     .{ "log", math.log },   .{ "log2", math.log2 },
    .{ "log10", math.log10 },
};

const binary = .{
    .{ "atan2", math.atan2 },     .{ "pow", math.pow }, .{ "fmod", math.fmod },
    .{ "logBase", math.logBase }, .{ "mod", math.mod }, .{ "luajitMod", math.luajitMod },
};

/// bits(x) -> the IEEE bits of x as 16 lowercase hex digits.
fn bits(lua: *Lua) i32 {
    const x: u64 = @bitCast(lua.checkNumber(1));
    var buf: [16]u8 = undefined;
    _ = lua.pushString(std.fmt.bufPrint(&buf, "{x:0>16}", .{x}) catch unreachable); // 16 digits always fit
    return 1;
}

/// num(hex) -> the number with those IEEE bits.
fn num(lua: *Lua) i32 {
    const hex = lua.checkString(1);
    const x = std.fmt.parseInt(u64, hex, 16) catch lua.argError(1, "expected 16 hex digits");
    lua.pushNumber(@bitCast(x));
    return 1;
}

/// call(name, x, y?) -> math.name(x) or math.name(x, y), computed in Zig.
fn call(lua: *Lua) i32 {
    const name = lua.checkString(1);
    const x = lua.checkNumber(2);
    const y = lua.optNumber(3) orelse 0;
    lua.pushNumber(byName(name, x, y) orelse lua.argError(1, "unknown math function"));
    return 1;
}

/// render(script, path, opts?) runs script in a fresh state and writes
/// the canvas it returns to path. Raises the script's error, if any.
fn render(lua: *Lua) i32 {
    const script = lua.checkString(1);
    const path = lua.checkString(2);
    const opts = core.readRenderOptions(lua, 3);
    _ = lua.getField(zlua.registry_index, config_key);
    const config: *const Config = @ptrCast(@alignCast(lua.toPointer(-1) orelse
        lua.raiseErrorStr("testing config missing", .{})));
    lua.pop(1);
    renderScript(lua, config, script, path, opts) catch |err| switch (err) {
        error.ScriptFailed, error.CanvasFailed => lua.raiseError(),
        error.NoCanvas => lua.raiseErrorStr("%s returned no canvas", .{script.ptr}),
        else => lua.raiseErrorStr("rendering %s failed: %s", .{ script.ptr, @errorName(err).ptr }),
    };
    return 0;
}

/// On error.ScriptFailed and error.CanvasFailed the error message is on
/// top of `lua`'s stack.
fn renderScript(lua: *Lua, config: *const Config, script: [:0]const u8, path: []const u8, opts: core.RenderOptions) !void {
    const outer = util.getHost(lua);
    var host: util.Host = .{ .gpa = outer.gpa, .io = outer.io };
    const inner = try host_mod.create(&host, .{
        .script_dir = std.fs.path.dirname(script) orelse ".",
        .lua_dir = config.lua_dir,
        .argv = &.{ config.exe, script },
    });
    defer inner.deinit();

    host_mod.runScript(inner, script) catch {
        _ = lua.pushString(inner.toString(-1) catch "script failed");
        return error.ScriptFailed;
    };
    if (!host_mod.isCanvas(inner, -1)) return error.NoCanvas;
    host_mod.exportCanvas(inner, path, opts) catch |err| {
        if (err == error.CanvasFailed) _ = lua.pushString(inner.toString(-1) catch "canvas is malformed");
        return err;
    };
}
