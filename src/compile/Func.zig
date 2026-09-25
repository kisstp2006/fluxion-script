// SPDX-License-Identifier: BSD-2-Clause

//! One function being compiled: its code, constants and registers, its
//! scopes and loops, and what it captures from the functions around it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const diag = @import("../diag.zig");
const ast = @import("../syntax/ast.zig");
const bytecode = @import("../vm/code.zig");
const Instr = bytecode.Instr;
const Op = bytecode.Op;
const Value = @import("../vm/value.zig").Value;
const object = @import("../vm/object.zig");
const make = @import("../vm/make.zig");
const types = @import("types.zig");
const Type = types.Type;
const Compiler = @import("Compiler.zig");

const Func = @This();

pub const Error = Compiler.Error;

pub const Local = struct {
    name: []const u8,
    reg: u8,
    type: Type,
    is_const: bool,
    depth: u32,
    captured: bool = false,
    used: bool = false,
    span: diag.Span,
    /// What it was given, when that is a value the host gives: see
    /// `host.zig`.
    host: ?@import("host.zig").Host = null,
};

pub const Upval = struct {
    name: []const u8,
    desc: object.UpvalDesc,
    type: Type,
    is_const: bool,
};

pub const Jump = struct {
    at: usize,
    kind: enum { sj, sbx, word },
};

pub const Loop = struct {
    label: ?[]const u8,
    breaks: std.ArrayList(Jump) = .empty,
    continues: std.ArrayList(Jump) = .empty,
    depth: u32,
    defers: usize,
    locals: usize,
};

pub const Defer = struct {
    depth: u32,
    stmt: *const ast.Stmt,
    on_error: bool,
};

comp: *Compiler,
parent: ?*Func,
name: []const u8,
code: std.ArrayList(u32) = .empty,
spans: std.ArrayList(diag.Span) = .empty,
constants: std.ArrayList(Value) = .empty,
protos: std.ArrayList(*object.Proto) = .empty,
upvals: std.ArrayList(Upval) = .empty,
caches: u32 = 0,
locals: std.ArrayList(Local) = .empty,
loops: std.ArrayList(Loop) = .empty,
defers: std.ArrayList(Defer) = .empty,
depth: u32 = 0,
free: u8 = 0,
max: u8 = 1,
span: diag.Span = .empty,
ret: Type = .any,
has_self: bool = false,
self_type: Type = .unknown,
coroutine: bool = false,
params: u8 = 0,
required: u8 = 0,
param_types: std.ArrayList(Type) = .empty,
param_names: std.ArrayList([]const u8) = .empty,
class: ?*object.Class = null,
returns_value: bool = false,
/// Whether the code being emitted can be reached: false after a `return`,
/// a `break`, a `continue` or a call that never returns.
reachable: bool = true,
/// The call being compiled is the operand of `await`: a coroutine it calls
/// runs in this task rather than a new one.
awaiting: bool = false,
/// The last call compiled ran a coroutine in this task, so what `await`
/// gets is that coroutine's result.
awaited_coroutine: bool = false,
fast_entry: u32 = 0,

pub fn init(comp: *Compiler, parent: ?*Func, name: []const u8) Func {
    return .{ .comp = comp, .parent = parent, .name = name };
}

pub fn gpa(f: *Func) Allocator {
    return f.comp.gpa;
}

pub fn deinit(f: *Func) void {
    const a = f.gpa();
    f.code.deinit(a);
    f.spans.deinit(a);
    f.constants.deinit(a);
    f.protos.deinit(a);
    f.upvals.deinit(a);
    f.locals.deinit(a);
    for (f.loops.items) |*l| {
        l.breaks.deinit(a);
        l.continues.deinit(a);
    }
    f.loops.deinit(a);
    f.defers.deinit(a);
    f.param_types.deinit(a);
    f.param_names.deinit(a);
}

// ---------------------------------------------------------------------------
// Code

pub fn here(f: *const Func) usize {
    return f.code.items.len;
}

pub fn emit(f: *Func, i: Instr) Error!usize {
    try f.code.append(f.gpa(), i.word());
    try f.spans.append(f.gpa(), f.span);
    return f.code.items.len - 1;
}

pub fn emitWord(f: *Func, w: u32) Error!void {
    try f.code.append(f.gpa(), w);
    try f.spans.append(f.gpa(), f.span);
}

pub fn abc(f: *Func, op: Op, a: u8, b: u8, c: u8) Error!void {
    _ = try f.emit(.abc(op, a, b, c));
}

pub fn abx(f: *Func, op: Op, a: u8, bx: u16) Error!void {
    _ = try f.emit(.abx(op, a, bx));
}

pub fn emitI(f: *Func, op: Op, a: u8, sbx: i16) Error!void {
    _ = try f.emit(.asbx(op, a, sbx));
}

/// A jump whose target is patched in later.
pub fn jumpForward(f: *Func, op: Op, a: u8, b: u8) Error!Jump {
    return switch (op) {
        .jmp => .{ .at = try f.emit(.sj(.jmp, 0)), .kind = .sj },
        .jtrue, .jfalse, .jnull, .jnotnull, .jerr, .jnoterr, .for_prep, .for_loop, .iter_prep, .iter_next, .jargs => .{ .at = try f.emit(.asbx(op, a, 0)), .kind = .sbx },
        else => blk: {
            const at = try f.emit(.abc(op, a, b, 0));
            try f.emitWord(0);
            break :blk .{ .at = at, .kind = .word };
        },
    };
}

pub fn patch(f: *Func, j: Jump, target: usize) Error!void {
    const from: isize = @intCast(j.at + @as(usize, if (j.kind == .word) 2 else 1));
    const offset = @as(isize, @intCast(target)) - from;
    switch (j.kind) {
        .sj => {
            if (offset < std.math.minInt(i24) or offset > std.math.maxInt(i24)) return f.tooLarge();
            f.code.items[j.at] = Instr.sj(.jmp, @intCast(offset)).word();
        },
        .sbx => {
            if (offset < std.math.minInt(i16) or offset > std.math.maxInt(i16)) return f.tooLarge();
            const old = Instr.of(f.code.items[j.at]);
            f.code.items[j.at] = Instr.asbx(old.op, old.a, @intCast(offset)).word();
        },
        .word => f.code.items[j.at + 1] = @bitCast(@as(i32, @intCast(offset))),
    }
}

pub fn patchHere(f: *Func, j: Jump) Error!void {
    return f.patch(j, f.here());
}

pub fn patchAll(f: *Func, list: []const Jump, target: usize) Error!void {
    for (list) |j| try f.patch(j, target);
}

pub fn jumpBack(f: *Func, op: Op, a: u8, target: usize) Error!void {
    const j = try f.jumpForward(op, a, 0);
    try f.patch(j, target);
}

fn tooLarge(f: *Func) Error {
    _ = try f.comp.err(f.span, "this function is too large to jump across; split it into smaller functions", .{});
    return error.CompileFailed;
}

// ---------------------------------------------------------------------------
// Registers

pub fn alloc(f: *Func) Error!u8 {
    if (f.free == 250) {
        _ = try f.comp.err(f.span, "this function needs more than 250 registers; split it into smaller functions", .{});
        return error.CompileFailed;
    }
    const r = f.free;
    f.free += 1;
    if (f.free > f.max) f.max = f.free;
    return r;
}

pub fn allocN(f: *Func, n: u8) Error!u8 {
    const first = f.free;
    for (0..n) |_| _ = try f.alloc();
    return first;
}

/// Makes sure `n` registers from `first` exist in the frame, without
/// taking them.
pub fn reserve(f: *Func, first: u8, n: u8) void {
    if (first + n > f.max) f.max = first + n;
}

pub fn release(f: *Func, to: u8) void {
    std.debug.assert(to <= f.free);
    f.free = to;
}

/// The next free register is `to`, whether that frees registers or takes
/// them.
pub fn setFree(f: *Func, to: u8) void {
    f.free = to;
    if (f.free > f.max) f.max = f.free;
}

// ---------------------------------------------------------------------------
// Constants

pub fn constant(f: *Func, v: Value) Error!u16 {
    for (f.constants.items, 0..) |existing, i| {
        if (existing.tag == v.tag and existing.raw == v.raw and existing.extra == v.extra) return @intCast(i);
    }
    if (f.constants.items.len >= std.math.maxInt(u16)) {
        _ = try f.comp.err(f.span, "this function has too many constants; split it into smaller functions", .{});
        return error.CompileFailed;
    }
    try f.constants.append(f.gpa(), v);
    return @intCast(f.constants.items.len - 1);
}

/// Constants that must sit side by side, as an f-string's specs do; not
/// shared with equal constants elsewhere.
pub fn constantRun(f: *Func, values: []const Value) Error!u16 {
    if (f.constants.items.len + values.len >= std.math.maxInt(u16)) {
        _ = try f.comp.err(f.span, "this function has too many constants; split it into smaller functions", .{});
        return error.CompileFailed;
    }
    const first: u16 = @intCast(f.constants.items.len);
    try f.constants.appendSlice(f.gpa(), values);
    return first;
}

pub fn nameConstant(f: *Func, text: []const u8) Error!u16 {
    return f.constant(.fromObj(.string, &(try f.comp.vm.intern(text)).obj));
}

pub fn cache(f: *Func) Error!u16 {
    if (f.caches >= std.math.maxInt(u16)) return f.tooLarge();
    f.caches += 1;
    return @intCast(f.caches - 1);
}

// ---------------------------------------------------------------------------
// Scopes

pub fn enter(f: *Func) void {
    f.depth += 1;
}

/// Ends a scope: its locals go, their registers free up, and any a closure
/// captured are closed so the closure keeps its own copy.
pub fn leave(f: *Func) Error!void {
    var lowest: ?u8 = null;
    var captured = false;
    while (f.locals.items.len > 0 and f.locals.items[f.locals.items.len - 1].depth >= f.depth) {
        const l = f.locals.pop().?;
        f.warnUnused(l);
        lowest = l.reg;
        captured = captured or l.captured;
    }
    if (captured) try f.abc(.close, lowest.?, 0, 0);
    if (lowest) |r| f.release(@min(r, f.free));
    f.depth -= 1;
}

pub fn warnUnused(f: *Func, l: Local) void {
    if (l.used or l.name.len == 0 or l.name[0] == '_' or std.mem.eql(u8, l.name, "self")) return;
    const h = f.comp.warn(l.span, "`{s}` is never used", .{l.name}) catch return;
    _ = h.help("remove it, or name it `_{s}` to keep it", .{l.name}) catch {};
}

pub fn declare(f: *Func, name: []const u8, reg: u8, t: Type, is_const: bool, span: diag.Span) Error!void {
    for (f.locals.items) |l| {
        if (l.depth == f.depth and std.mem.eql(u8, l.name, name) and name.len > 0 and !std.mem.eql(u8, name, "_")) {
            const h = try f.comp.err(span, "`{s}` is already declared in this scope", .{name});
            _ = try h.label(f.comp.at(l.span), "declared here", .{});
            break;
        }
    }
    try f.locals.append(f.gpa(), .{ .name = name, .reg = reg, .type = t, .is_const = is_const, .depth = f.depth, .span = span });
    if (f.comp.recording()) |r| try r.local(f, f.locals.items[f.locals.items.len - 1]);
}

pub fn findLocal(f: *Func, name: []const u8) ?*Local {
    var i = f.locals.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, f.locals.items[i].name, name)) return &f.locals.items[i];
    }
    return null;
}

/// Finds `name` in an enclosing function and captures it, through every
/// function between.
pub fn findUpval(f: *Func, name: []const u8) Error!?u8 {
    for (f.upvals.items, 0..) |u, i| if (std.mem.eql(u8, u.name, name)) return @intCast(i);
    const parent = f.parent orelse return null;
    if (parent.findLocal(name)) |l| {
        l.captured = true;
        l.used = true;
        return try f.addUpval(name, .{ .from_parent_local = true, .index = l.reg }, l.type, l.is_const);
    }
    if (try parent.findUpval(name)) |i| {
        const u = parent.upvals.items[i];
        return try f.addUpval(name, .{ .from_parent_local = false, .index = i }, u.type, u.is_const);
    }
    return null;
}

fn addUpval(f: *Func, name: []const u8, desc: object.UpvalDesc, t: Type, is_const: bool) Error!u8 {
    if (f.upvals.items.len >= 250) {
        _ = try f.comp.err(f.span, "this function captures too many variables", .{});
        return error.CompileFailed;
    }
    try f.upvals.append(f.gpa(), .{ .name = name, .desc = desc, .type = t, .is_const = is_const });
    return @intCast(f.upvals.items.len - 1);
}

// ---------------------------------------------------------------------------
// Finishing

/// The prototype the virtual machine runs.
pub fn finish(f: *Func, proto: *object.Proto) Error!void {
    const a = f.gpa();
    const vm = f.comp.vm;
    proto.code = try f.code.toOwnedSlice(a);
    proto.spans = try f.spans.toOwnedSlice(a);
    proto.constants = try f.constants.toOwnedSlice(a);
    proto.protos = try f.protos.toOwnedSlice(a);
    const descs = try a.alloc(object.UpvalDesc, f.upvals.items.len);
    for (f.upvals.items, descs) |u, *d| d.* = u.desc;
    proto.upvals = descs;
    proto.caches = try a.alloc(object.Cache, f.caches);
    for (proto.caches) |*c| c.* = .{};
    proto.params = f.params;
    proto.required = f.required;
    proto.regs = @max(f.max, 1);
    proto.has_self = f.has_self;
    proto.coroutine = f.coroutine;
    proto.file = f.comp.file;
    proto.module = f.comp.module;
    proto.class = f.class;
    const checks = try a.alloc(@import("../vm/types.zig").Check, f.param_types.items.len);
    for (f.param_types.items, checks) |t, *c| c.* = try f.comp.pool.check(&vm.checks, a, t);
    proto.param_checks = checks;
    const names = try a.alloc(*object.String, f.param_names.items.len);
    for (f.param_names.items, names) |n, *s| s.* = try vm.intern(n);
    proto.param_names = names;
    proto.returns = try f.comp.pool.check(&vm.checks, a, f.ret);
    proto.fast_entry = f.fast_entry;
    _ = make;
}
