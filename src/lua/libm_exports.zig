//! Makes the embedded Lua's math library, its `^` operator and the calls
//! LuaJIT's compiled traces make run the same maths as src/libm.zig.
//!
//! Both VMs reach the maths by C symbol: lmathlib.c and lj_vmmath.c call
//! it from C, LuaJIT's interpreter with `bl extern sin` and its JIT
//! through the addresses in lj_ir_callinfo. All of those are resolved by
//! the static linker.
//!
//! sin, cos, tan, exp, log, log2, log10 and fmod come from compiler-rt,
//! which Zig links into every executable as one object in an archive.
//! Its definitions are weak, and the linker only loads the object when an
//! undefined symbol that no earlier input defines points into it. A call
//! to sin alone does not: the platform libm answers it first. The anchor
//! below references a symbol only compiler-rt has, so the object is
//! always loaded, and a definition in a loaded object takes precedence
//! over any shared library's. The functions compiler-rt lacks are
//! exported here from std.math. src/tools/libm_guard.zig checks the
//! linked binary.

const libm = @import("genpuin").libm;

/// compiler-rt's f80 sine, which no libc defines.
const anchor = @extern(*const anyopaque, .{ .name = "__sinx" });

export const genpuin_compiler_rt_anchor: *const anyopaque = anchor;

/// What compiler-rt does not define, as C name and libm function.
const unary = .{
    .{ "asin", libm.asin }, .{ "acos", libm.acos }, .{ "atan", libm.atan },
    .{ "sinh", libm.sinh }, .{ "cosh", libm.cosh }, .{ "tanh", libm.tanh },
};

const binary = .{
    .{ "atan2", libm.atan2 }, .{ "pow", libm.pow },
};

fn Unary(comptime f: fn (f64) f64) type {
    return struct {
        fn c(x: f64) callconv(.c) f64 {
            return f(x);
        }
    };
}

fn Binary(comptime f: fn (f64, f64) f64) type {
    return struct {
        fn c(x: f64, y: f64) callconv(.c) f64 {
            return f(x, y);
        }
    };
}

comptime {
    for (unary) |e| @export(&Unary(e[1]).c, .{ .name = e[0] });
    for (binary) |e| @export(&Binary(e[1]).c, .{ .name = e[0] });
}
