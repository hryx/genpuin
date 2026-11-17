//! Build-time check that the executable defines none of the libm
//! functions itself. LuaJIT and Lua call sin, pow, fmod and friends from
//! libc, and a definition pulled in from compiler-rt (by f128 maths, a
//! non-native @mulAdd and the like) takes their place at link time and
//! shifts script maths in the last bit. Reads the Mach-O or ELF symbol
//! table with std, no host tools.

const std = @import("std");
const macho = std.macho;
const elf = std.elf;

const libm = [_][]const u8{
    "acos",   "asin",  "atan", "atan2", "cos",   "sin",   "tan",   "cosh",
    "sinh",   "tanh",  "exp",  "exp2",  "expm1", "log",   "log2",  "log10",
    "log1p",  "pow",   "fmod", "sqrt",  "cbrt",  "hypot", "floor", "ceil",
    "trunc",  "round", "fma",  "fmin",  "fmax",  "ldexp", "frexp", "modf",
    "sincos",
};

fn isLibm(name: []const u8) bool {
    for (libm) |base| {
        if (!std.mem.startsWith(u8, name, base)) continue;
        const rest = name[base.len..];
        if (rest.len == 0) return true;
        if (rest.len == 1 and (rest[0] == 'f' or rest[0] == 'l')) return true;
    }
    return false;
}

const Error = error{ Truncated, UnknownFormat };

fn read(comptime T: type, bytes: []const u8, offset: u64) Error!T {
    if (offset + @sizeOf(T) > bytes.len) return error.Truncated;
    const o: usize = @intCast(offset);
    return std.mem.bytesToValue(T, bytes[o..][0..@sizeOf(T)]);
}

fn cString(bytes: []const u8, offset: u64) []const u8 {
    if (offset >= bytes.len) return "";
    return std.mem.sliceTo(bytes[@intCast(offset)..], 0);
}

const Found = struct {
    names: [libm.len * 3][]const u8 = undefined,
    len: usize = 0,
    tables: u32 = 0,

    fn add(f: *Found, name: []const u8) void {
        if (!isLibm(name)) return;
        for (f.names[0..f.len]) |n| if (std.mem.eql(u8, n, name)) return;
        if (f.len < f.names.len) {
            f.names[f.len] = name;
            f.len += 1;
        }
    }
};

fn scanMachO(bytes: []const u8, found: *Found) Error!void {
    const header = try read(macho.mach_header_64, bytes, 0);
    var offset: u64 = @sizeOf(macho.mach_header_64);
    for (0..header.ncmds) |_| {
        const lc = try read(macho.load_command, bytes, offset);
        if (lc.cmd == .SYMTAB) {
            const st = try read(macho.symtab_command, bytes, offset);
            found.tables += 1;
            for (0..st.nsyms) |i| {
                const sym = try read(macho.nlist_64, bytes, st.symoff + i * @sizeOf(macho.nlist_64));
                const bits = sym.n_type.bits;
                if (bits.is_stab != 0 or bits.type == .undf) continue;
                const name = cString(bytes, @as(u64, st.stroff) + sym.n_strx);
                if (name.len > 1 and name[0] == '_') found.add(name[1..]);
            }
        }
        if (lc.cmdsize == 0) return error.Truncated;
        offset += lc.cmdsize;
    }
}

fn scanElf(bytes: []const u8, found: *Found) Error!void {
    const shoff = try read(u64, bytes, @offsetOf(elf.Elf64_Ehdr, "e_shoff"));
    const shentsize = try read(u16, bytes, @offsetOf(elf.Elf64_Ehdr, "e_shentsize"));
    const shnum = try read(u16, bytes, @offsetOf(elf.Elf64_Ehdr, "e_shnum"));
    for (0..shnum) |i| {
        const sh = try read(elf.Elf64_Shdr, bytes, shoff + i * shentsize);
        if (sh.sh_type != elf.SHT_SYMTAB and sh.sh_type != elf.SHT_DYNSYM) continue;
        const strtab = try read(elf.Elf64_Shdr, bytes, shoff + @as(u64, sh.sh_link) * shentsize);
        found.tables += 1;
        const count = sh.sh_size / @sizeOf(elf.Elf64_Sym);
        for (0..count) |k| {
            const sym = try read(elf.Elf64_Sym, bytes, sh.sh_offset + k * @sizeOf(elf.Elf64_Sym));
            if (sym.st_shndx == elf.SHN_UNDEF) continue;
            found.add(cString(bytes, strtab.sh_offset + sym.st_name));
        }
    }
}

fn scan(bytes: []const u8, found: *Found) Error!void {
    if (bytes.len >= 4 and std.mem.readInt(u32, bytes[0..4], .little) == macho.MH_MAGIC_64) return scanMachO(bytes, found);
    if (bytes.len >= 5 and std.mem.eql(u8, bytes[0..4], elf.MAGIC) and bytes[elf.EI.CLASS] == elf.ELFCLASS64 and
        bytes[elf.EI.DATA] == elf.ELFDATA2LSB) return scanElf(bytes, found);
    return error.UnknownFormat;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: libm_guard <executable>\n", .{});
        std.process.exit(2);
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], arena, .limited(1 << 30));
    var found: Found = .{};
    scan(bytes, &found) catch |err| switch (err) {
        error.UnknownFormat => {
            std.debug.print("libm guard: {s} is not 64-bit little-endian Mach-O or ELF, skipped\n", .{args[1]});
            return;
        },
        error.Truncated => {
            std.debug.print("libm guard: {s} is truncated\n", .{args[1]});
            std.process.exit(1);
        },
    };
    if (found.tables == 0) {
        std.debug.print("libm guard: {s} has no symbol table, skipped\n", .{args[1]});
        return;
    }
    if (found.len == 0) return;
    std.debug.print("libm guard: {s} defines libm functions itself:", .{args[1]});
    for (found.names[0..found.len]) |n| std.debug.print(" {s}", .{n});
    std.debug.print(
        \\
        \\Lua would call these instead of libc's and script maths would change.
        \\Something in the Zig code pulled them in from compiler-rt, typically
        \\f128 maths, @mulAdd on a type without native fma, or a std.math
        \\routine. Call libc through src/algo/libm.zig instead.
        \\
    , .{});
    std.process.exit(1);
}

test "libm guard: matches libm names and their float and long forms" {
    try std.testing.expect(isLibm("sin"));
    try std.testing.expect(isLibm("powf"));
    try std.testing.expect(isLibm("fmodl"));
    try std.testing.expect(!isLibm("sinq"));
    try std.testing.expect(!isLibm("single"));
    try std.testing.expect(!isLibm("__sincos_stret"));
}
