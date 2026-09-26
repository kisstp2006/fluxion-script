// SPDX-License-Identifier: BSD-2-Clause

//! Where control goes: conditions as jumps, `if` and `switch` as values,
//! and the ways out of a function or a loop, with the `defer`s they run.

const std = @import("std");

const diag = @import("../diag.zig");
const ast = @import("../syntax/ast.zig");
const code = @import("../vm/code.zig");
const Op = code.Op;
const types = @import("types.zig");
const Type = types.Type;
const Func = @import("Func.zig");
const Jump = Func.Jump;
const Compiler = @import("Compiler.zig");
const Error = Compiler.Error;
const expr = @import("expr.zig");
const Operand = expr.Operand;
const binary = @import("binary.zig");
const stmt = @import("stmt.zig");

pub const Jumps = std.ArrayList(Jump);

fn smallInt(e: *const ast.Expr) ?i8 {
    return switch (e.kind) {
        .int => |i| if (i >= -128 and i <= 127) @intCast(i) else null,
        else => null,
    };
}

/// What `cond` being `when` says of the types of constants, made so until
/// `f.unnarrow` is given what this returns: `x is T` true, `x` is a `T`;
/// `!c` says the reverse of `c`; `a and b` true says what each does, `a or
/// b` false too. Only a constant is narrowed - a parameter, a `const`, a
/// capture - as nothing can give it another value, and only to a type a
/// value is checked for exactly.
pub fn narrow(f: *Func, cond: *const ast.Expr, when: bool) Error!usize {
    const mark = f.narrowed.items.len;
    try facts(f, cond, when);
    return mark;
}

fn facts(f: *Func, e: *const ast.Expr, when: bool) Error!void {
    switch (e.kind) {
        .unary => |u| if (u.op == .not) try facts(f, u.operand, !when),
        .binary => |b| switch (b.op) {
            .@"and" => if (when) {
                try facts(f, b.lhs, true);
                try facts(f, b.rhs, true);
            },
            .@"or" => if (!when) {
                try facts(f, b.lhs, false);
                try facts(f, b.rhs, false);
            },
            else => {},
        },
        .is_type => |x| if (when and x.value.kind == .ident) {
            const c = f.comp;
            // Resolved again: not recorded twice.
            const recorder = c.recorder;
            c.recorder = null;
            defer c.recorder = recorder;
            const t = try @import("resolve.zig").typeExpr(c, x.type);
            if (exact(c, t)) try narrowName(f, x.value.kind.ident, t);
        },
        else => {},
    }
}

/// Whether `is T` tells a value is a `T` and nothing else: not for a float,
/// which an int passes too.
fn exact(c: *Compiler, t: Type) bool {
    return switch (t) {
        .int, .bool, .string, .vec2, .vec3, .color, .@"error", .task, .signal => true,
        else => c.pool.structOf(t) != null or c.pool.enumOf(t) != null or c.pool.hostOf(t) != null or c.pool.listOf(t) != null or c.pool.mapOf(t) != null,
    };
}

fn narrowName(f: *Func, name: []const u8, t: Type) Error!void {
    const c = f.comp;
    if (f.findLocal(name)) |l| {
        if (!l.is_const or !narrower(c, t, l.type)) return;
        const i = (@intFromPtr(l) - @intFromPtr(f.locals.items.ptr)) / @sizeOf(Func.Local);
        try f.narrowed.append(c.gpa, .{ .place = .{ .local = i }, .was = l.type, .depth = f.depth });
        l.type = t;
        return;
    }
    const u = (try f.findUpval(name)) orelse return;
    const up = &f.upvals.items[u];
    if (!up.is_const or !narrower(c, t, up.type)) return;
    try f.narrowed.append(c.gpa, .{ .place = .{ .upval = u }, .was = up.type, .depth = f.depth });
    up.type = t;
}

/// Whether a value of type `was` found to be a `t` is better known as one.
fn narrower(c: *Compiler, t: Type, was: Type) bool {
    if (Compiler.dynamic(was)) return true;
    const inner = c.pool.isOptional(was) orelse was;
    return t != inner and binary.compatible(c, t, inner);
}

/// Code that jumps when `e` is `when`, the jumps added to `out`.
pub fn jumpIf(f: *Func, e: *const ast.Expr, when: bool, out: *Jumps) Error!void {
    const c = f.comp;
    const saved = f.span;
    f.span = e.span;
    defer f.span = saved;
    switch (e.kind) {
        .bool => |b| {
            if (b == when) try out.append(c.gpa, try f.jumpForward(.jmp, 0, 0));
            return;
        },
        .unary => |u| if (u.op == .not) return jumpIf(f, u.operand, !when, out),
        .binary => |b| switch (b.op) {
            .@"and", .@"or" => {
                const joins = (b.op == .@"and") != when;
                if (joins) {
                    try jumpIf(f, b.lhs, when, out);
                    const narrowed = try narrow(f, b.lhs, b.op == .@"and");
                    try jumpIf(f, b.rhs, when, out);
                    f.unnarrow(narrowed);
                } else {
                    var skip: Jumps = .empty;
                    defer skip.deinit(c.gpa);
                    try jumpIf(f, b.lhs, !when, &skip);
                    const narrowed = try narrow(f, b.lhs, b.op == .@"and");
                    try jumpIf(f, b.rhs, when, out);
                    f.unnarrow(narrowed);
                    try f.patchAll(skip.items, f.here());
                }
                return;
            },
            .lt, .le, .gt, .ge, .eq, .ne => if (try compareJump(f, e, when, out)) return,
            else => {},
        },
        else => {},
    }
    const mark = f.free;
    const v = try expr.compile(f, e, null, .bool);
    try condition(f, v.type, e.span);
    try out.append(c.gpa, try f.jumpForward(if (when) .jtrue else .jfalse, v.reg, 0));
    f.release(mark);
}

pub fn condition(f: *Func, t: Type, span: diag.Span) Error!void {
    const c = f.comp;
    if (t == .bool or Compiler.dynamic(t) or t == .never) return;
    if (c.pool.isOptional(t) != null) {
        _ = try (try c.err(span, "a condition is a bool, and this is {s}", .{c.typeName(t)}))
            .help("to use the value when it is there: `if (x) |value| {{ ... }}`; to test it: `x != null`", .{});
        return;
    }
    _ = try (try c.err(span, "a condition is a bool, and this is {s}", .{c.typeName(t)}))
        .text("not a bool", .{});
}

/// A comparison as one compare-and-jump instruction, when the operand types
/// allow; false when they do not and the caller falls back.
fn compareJump(f: *Func, e: *const ast.Expr, when: bool, out: *Jumps) Error!bool {
    const b = e.kind.binary;
    const c = f.comp;
    const mark = f.free;
    var l = try expr.compile(f, b.lhs, null, .unknown);
    if (l.type == .int) if (smallInt(b.rhs)) |imm| {
        const op: Op = switch (b.op) {
            .lt => if (when) .jlti else .jgei,
            .le => if (when) .jlei else .jgti,
            .gt => if (when) .jgti else .jlei,
            .ge => if (when) .jgei else .jlti,
            else => .nop,
        };
        if (op != .nop) {
            try out.append(c.gpa, try f.jumpForward(op, l.reg, @bitCast(imm)));
            f.release(mark);
            return true;
        }
    };
    var r = try expr.compile(f, b.rhs, null, l.type);
    if (!binary.comparable(c, l.type, r.type, b.op)) {
        _ = try c.err(e.span, "cannot compare {s} with {s}", .{ c.typeName(l.type), c.typeName(r.type) });
        f.release(mark);
        return true;
    }
    if (l.type == .int and r.type == .float) l = try binary.coerce(f, l, .float, b.lhs.span, "");
    if (l.type == .float and r.type == .int) r = try binary.coerce(f, r, .float, b.rhs.span, "");
    const ints = l.type == .int and r.type == .int;
    const floats = l.type == .float and r.type == .float;
    const swap = b.op == .gt or b.op == .ge;
    const x = if (swap) r.reg else l.reg;
    const y = if (swap) l.reg else r.reg;
    const strict = b.op == .lt or b.op == .gt;
    switch (b.op) {
        .eq, .ne => {
            const same = (b.op == .eq) == when;
            const op: Op = if (ints) (if (same) .jeq_ii else .jne_ii) else (if (same) .jeq else .jne);
            try out.append(c.gpa, try f.jumpForward(op, l.reg, r.reg));
        },
        else => if (when) {
            const op: Op = if (ints) (if (strict) .jlt_ii else .jle_ii) else if (floats) (if (strict) .jlt_ff else .jle_ff) else (if (strict) .jlt else .jle);
            try out.append(c.gpa, try f.jumpForward(op, x, y));
        } else if (ints) {
            try out.append(c.gpa, try f.jumpForward(if (strict) .jle_ii else .jlt_ii, y, x));
        } else {
            const op: Op = if (floats) (if (strict) .jlt_ff else .jle_ff) else (if (strict) .jlt else .jle);
            const skip = try f.jumpForward(op, x, y);
            try out.append(c.gpa, try f.jumpForward(.jmp, 0, 0));
            try f.patchHere(skip);
        },
    }
    f.release(mark);
    return true;
}

fn join(c: *Compiler, a: Type, b: Type) Type {
    if (a == .never) return b;
    if (b == .never) return a;
    if (a == b) return a;
    if (a == .null) return c.pool.optional(b) catch .any;
    if (b == .null) return c.pool.optional(a) catch .any;
    return .any;
}

fn concrete(t: Type) bool {
    return !(t == .unknown or t == .any);
}

pub fn ifExpr(f: *Func, e: *const ast.Expr, dst: ?u8, expected: Type) Error!Operand {
    const x = e.kind.@"if";
    const c = f.comp;
    const out = try expr.target(f, dst);
    const mark = f.free;
    var skip: Jumps = .empty;
    defer skip.deinit(c.gpa);
    var then_type: Type = .unknown;
    const reachable = f.reachable;
    if (x.capture) |cap| {
        const v = try expr.compile(f, x.cond, null, .unknown);
        const child = c.pool.isOptional(v.type) orelse v.type;
        try skip.append(c.gpa, try f.jumpForward(.jnull, v.reg, 0));
        f.enter();
        const r = if (v.temp) v.reg else blk: {
            const t = try f.alloc();
            try f.abc(.move, t, v.reg, 0);
            break :blk t;
        };
        try f.declare(cap.text, r, child, true, cap.span);
        const then = if (concrete(expected)) try expr.typedInto(f, x.then, out, expected, "the value") else try expr.into(f, x.then, out, .unknown);
        then_type = then.type;
        try f.leave();
    } else {
        try jumpIf(f, x.cond, false, &skip);
        const narrowed = try narrow(f, x.cond, true);
        const then = if (concrete(expected)) try expr.typedInto(f, x.then, out, expected, "the value") else try expr.into(f, x.then, out, .unknown);
        f.unnarrow(narrowed);
        then_type = then.type;
    }
    const end = try f.jumpForward(.jmp, 0, 0);
    try f.patchAll(skip.items, f.here());
    // Past the `if`, either branch may have got here: a `return` in one
    // does not make what follows unreachable.
    const then_reachable = f.reachable;
    f.reachable = reachable;
    const narrowed = if (x.capture == null) try narrow(f, x.cond, false) else f.narrowed.items.len;
    const otherwise = if (concrete(expected)) try expr.typedInto(f, x.@"else", out, expected, "the value") else try expr.into(f, x.@"else", out, .unknown);
    f.unnarrow(narrowed);
    f.reachable = f.reachable or then_reachable;
    try f.patchHere(end);
    f.release(@max(mark, out + 1));
    const t = if (concrete(expected)) expected else join(c, then_type, otherwise.type);
    return .{ .reg = out, .type = t, .temp = dst == null };
}

pub fn orElse(f: *Func, e: *const ast.Expr, dst: ?u8, expected: Type) Error!Operand {
    const x = e.kind.@"orelse";
    const c = f.comp;
    const out = try expr.target(f, dst);
    const mark = f.free;
    const l = try expr.into(f, x.lhs, out, .unknown);
    const child = c.pool.isOptional(l.type) orelse blk: {
        if (!Compiler.dynamic(l.type) and l.type != .null) {
            _ = try (try c.err(x.lhs.span, "`orelse` is for a value that may be null, and this is {s}", .{c.typeName(l.type)}))
                .text("never null", .{});
        }
        break :blk l.type;
    };
    const end = try f.jumpForward(.jnotnull, out, 0);
    const reachable = f.reachable;
    const t = try fallback(f, x.rhs, out, child, expected);
    // A value that is there goes on past a fallback that returns.
    f.reachable = reachable;
    try f.patchHere(end);
    f.release(@max(mark, out + 1));
    return .{ .reg = out, .type = t, .temp = dst == null };
}

/// The value used when the left side of `orelse` or `catch` has none: of
/// the type the place wants if it wants one, else of the left side's type
/// when it matches, else `any`.
fn fallback(f: *Func, rhs: *const ast.Expr, out: u8, payload: Type, expected: Type) Error!Type {
    const c = f.comp;
    if (concrete(expected) and rhs.kind != .block) {
        _ = try expr.typedInto(f, rhs, out, expected, "the fallback");
        return expected;
    }
    const v = try expr.into(f, rhs, out, payload);
    if (v.type == .never or v.type == payload) return payload;
    if (!concrete(payload)) return if (v.type == .void) .any else v.type;
    if (binary.compatible(c, v.type, payload)) return payload;
    return .any;
}

pub fn catchExpr(f: *Func, e: *const ast.Expr, dst: ?u8, expected: Type) Error!Operand {
    const x = e.kind.@"catch";
    const c = f.comp;
    const out = try expr.target(f, dst);
    const mark = f.free;
    const l = try expr.into(f, x.lhs, out, .unknown);
    const payload = c.pool.isErrorUnion(l.type) orelse blk: {
        if (!Compiler.dynamic(l.type)) {
            _ = try (try c.err(x.lhs.span, "`catch` is for a value that may be an error, and this is {s}", .{c.typeName(l.type)}))
                .text("never an error", .{});
        }
        break :blk l.type;
    };
    const end = try f.jumpForward(.jnoterr, out, 0);
    f.enter();
    if (x.capture) |cap| {
        const r = try f.alloc();
        try f.abc(.move, r, out, 0);
        try f.declare(cap.text, r, .@"error", true, cap.span);
    }
    const reachable = f.reachable;
    const t = try fallback(f, x.rhs, out, payload, expected);
    try f.leave();
    f.reachable = reachable;
    try f.patchHere(end);
    f.release(@max(mark, out + 1));
    return .{ .reg = out, .type = t, .temp = dst == null };
}

/// The `defer`s from the innermost down to scope `depth`, newest first;
/// `errdefer`s too when `failing`.
pub fn runDefers(f: *Func, depth: u32, failing: bool) Error!void {
    var i = f.defers.items.len;
    const saved_reachable = f.reachable;
    while (i > 0) {
        i -= 1;
        const d = f.defers.items[i];
        if (d.depth < depth) break;
        if (d.on_error and !failing) continue;
        const saved = f.defers.items.len;
        f.defers.items.len = i;
        try stmt.compile(f, d.stmt);
        f.defers.items.len = saved;
    }
    f.reachable = saved_reachable;
}

fn hasErrdefer(f: *Func) bool {
    for (f.defers.items) |d| if (d.on_error) return true;
    return false;
}

pub fn tryExpr(f: *Func, x: *const ast.Expr, span: diag.Span, dst: ?u8) Error!Operand {
    const c = f.comp;
    const out = try expr.target(f, dst);
    const mark = f.free;
    const v = try expr.into(f, x, out, .unknown);
    const payload = c.pool.isErrorUnion(v.type) orelse blk: {
        if (v.type == .@"error") break :blk Type.never;
        if (!Compiler.dynamic(v.type)) {
            _ = try (try c.err(span, "`try` is for a value that may be an error, and this is {s}", .{c.typeName(v.type)}))
                .text("never an error", .{});
        }
        break :blk v.type;
    };
    if (!(Compiler.dynamic(f.ret) or f.ret == .@"error" or c.pool.isErrorUnion(f.ret) != null)) {
        _ = try (try c.err(span, "`try` passes an error on to the caller, but this function returns {s}", .{c.typeName(f.ret)}))
            .help("make the return type `!{s}`, or handle the error here with `catch`", .{c.typeName(f.ret)});
    }
    const ok = try f.jumpForward(.jnoterr, out, 0);
    try runDefers(f, 0, true);
    try f.abc(.ret, out, 0, 0);
    try f.patchHere(ok);
    f.release(@max(mark, out + 1));
    return .{ .reg = out, .type = payload, .temp = dst == null };
}

pub fn awaitExpr(f: *Func, x: *const ast.Expr, span: diag.Span, dst: ?u8) Error!Operand {
    const c = f.comp;
    if (!f.coroutine) {
        _ = try c.err(span, "`await` makes this function a coroutine, which a lambda cannot be yet", .{});
    }
    const out = try expr.target(f, dst);
    const mark = f.free;
    if (x.kind == .call) f.awaiting = true;
    f.awaited_coroutine = false;
    const v = try expr.compile(f, x, null, .unknown);
    f.awaiting = false;
    const inline_coroutine = f.awaited_coroutine;
    f.awaited_coroutine = false;
    if (inline_coroutine) {
        if (v.reg != out) try f.abc(.move, out, v.reg, 0);
    } else {
        try f.abc(.@"await", out, v.reg, 0);
    }
    f.release(@max(mark, out + 1));
    const t: Type = if (inline_coroutine) v.type else switch (v.type) {
        .float, .int => .void,
        .task, .signal, .any, .unknown => .any,
        else => v.type,
    };
    return .{ .reg = out, .type = t, .temp = dst == null };
}

pub fn returnExpr(f: *Func, value: ?*const ast.Expr, span: diag.Span, dst: ?u8) Error!Operand {
    const c = f.comp;
    const mark = f.free;
    if (value) |v| {
        if (f.ret == .void) {
            _ = try (try c.err(v.span, "this function returns nothing, so its `return` gives no value", .{}))
                .help("give the function a return type: `fn {s}(...) {s} {{`", .{ f.name, "int" });
        }
        const r = try expr.typed(f, v, if (f.ret == .void) .unknown else f.ret, "the return value");
        const kept = if (f.defers.items.len > 0) try binary.owned(f, r) else r;
        if (f.defers.items.len > 0) {
            if (hasErrdefer(f) and (Compiler.dynamic(kept.type) or kept.type == .@"error" or c.pool.isErrorUnion(kept.type) != null)) {
                const ok = try f.jumpForward(.jnoterr, kept.reg, 0);
                try runDefers(f, 0, true);
                const done = try f.jumpForward(.jmp, 0, 0);
                try f.patchHere(ok);
                try runDefers(f, 0, false);
                try f.patchHere(done);
            } else try runDefers(f, 0, false);
        }
        try f.abc(.ret, kept.reg, 0, 0);
    } else {
        if (!(f.ret == .void or f.ret == .any or f.ret == .unknown or c.pool.nullable(f.ret))) {
            _ = try c.err(span, "this function returns {s}; `return` needs a value", .{c.typeName(f.ret)});
        }
        try runDefers(f, 0, false);
        try f.abc(.retnull, 0, 0, 0);
    }
    f.release(mark);
    f.reachable = false;
    return .{ .reg = try expr.target(f, dst), .type = .never, .temp = dst == null };
}

pub fn breakExpr(f: *Func, label: ?ast.Name, span: diag.Span, dst: ?u8, is_continue: bool) Error!Operand {
    const c = f.comp;
    const word = if (is_continue) "continue" else "break";
    var i = f.loops.items.len;
    const loop: ?*Func.Loop = while (i > 0) {
        i -= 1;
        const l = &f.loops.items[i];
        if (label == null) break l;
        if (l.label) |name| if (std.mem.eql(u8, name, label.?.text)) break l;
    } else null;
    const target = loop orelse {
        if (label) |l| {
            _ = try c.err(l.span, "there is no loop labelled `{s}` around this `{s}`", .{ l.text, word });
        } else {
            _ = try c.err(span, "`{s}` is only inside a loop", .{word});
        }
        return .{ .reg = try expr.target(f, dst), .type = .never, .temp = dst == null };
    };
    try runDefers(f, target.depth + 1, false);
    const captured = for (f.locals.items[target.locals..]) |l| {
        if (l.captured) break true;
    } else false;
    if (captured) try f.abc(.close, f.locals.items[target.locals].reg, 0, 0);
    const j = try f.jumpForward(.jmp, 0, 0);
    if (is_continue) try target.continues.append(c.gpa, j) else try target.breaks.append(c.gpa, j);
    f.reachable = false;
    return .{ .reg = try expr.target(f, dst), .type = .never, .temp = dst == null };
}

pub fn blockExpr(f: *Func, b: *const ast.Block, dst: ?u8) Error!Operand {
    try stmt.block(f, b);
    return .{ .reg = try expr.target(f, dst), .type = if (f.reachable) .void else .never, .temp = dst == null };
}

pub fn switchExpr(f: *Func, sw: *const ast.Switch, span: diag.Span, dst: ?u8, expected: Type) Error!Operand {
    return switchNode(f, sw, span, dst, expected, true);
}

pub fn switchStmt(f: *Func, sw: *const ast.Switch, span: diag.Span) Error!void {
    const mark = f.free;
    _ = try switchNode(f, sw, span, null, .unknown, false);
    f.release(mark);
}

fn switchNode(f: *Func, sw: *const ast.Switch, span: diag.Span, dst: ?u8, expected: Type, wants_value: bool) Error!Operand {
    const c = f.comp;
    const out = if (wants_value) try expr.target(f, dst) else 0;
    const mark = f.free;
    const subject = try expr.compile(f, sw.subject, null, .unknown);
    const s = try binary.owned(f, subject);
    const e = c.pool.enumOf(subject.type);
    var covered: std.ArrayList(bool) = .empty;
    defer covered.deinit(c.gpa);
    if (e) |en| try covered.appendNTimes(c.gpa, false, en.members.len);
    var ends: Jumps = .empty;
    defer ends.deinit(c.gpa);
    var has_else = false;
    var result_type: Type = .never;
    var any_reachable = false;
    // A switch on a bool names every value once it has both.
    var bools: [2]bool = .{ false, false };
    for (sw.prongs) |prong| {
        var to_body: Jumps = .empty;
        defer to_body.deinit(c.gpa);
        if (prong.is_else) {
            has_else = true;
        } else for (prong.cases) |case| switch (case) {
            .value => |v| {
                const k = try expr.compile(f, v, null, subject.type);
                if (!binary.comparable(c, subject.type, k.type, .eq)) {
                    _ = try c.err(v.span, "this case is {s}, and the switch is on {s}", .{ c.typeName(k.type), c.typeName(subject.type) });
                }
                if (e) |en| if (v.kind == .enum_literal) if (en.index(v.kind.enum_literal.text)) |idx| {
                    if (covered.items[idx]) _ = try c.err(v.span, "`.{s}` is handled twice", .{v.kind.enum_literal.text});
                    covered.items[idx] = true;
                };
                if (subject.type == .bool and v.kind == .bool) bools[@intFromBool(v.kind.bool)] = true;
                try to_body.append(c.gpa, try f.jumpForward(if (subject.type == .int and k.type == .int) .jeq_ii else .jeq, s.reg, k.reg));
                f.release(s.reg + 1);
            },
            .range => |r| {
                const lo = try expr.typed(f, r.from, .int, "a range's start");
                const hi = try expr.typed(f, r.to, .int, "a range's end");
                const below = try f.jumpForward(if (subject.type == .int) .jlt_ii else .jlt, s.reg, lo.reg);
                const above = try f.jumpForward(if (subject.type == .int) .jlt_ii else .jlt, hi.reg, s.reg);
                try to_body.append(c.gpa, try f.jumpForward(.jmp, 0, 0));
                try f.patchHere(below);
                try f.patchHere(above);
                f.release(s.reg + 1);
            },
        };
        const next = if (prong.is_else) null else try f.jumpForward(.jmp, 0, 0);
        try f.patchAll(to_body.items, f.here());
        f.reachable = true;
        if (wants_value) {
            const v = if (concrete(expected)) try expr.typedInto(f, prong.body, out, expected, "the value") else try expr.into(f, prong.body, out, .unknown);
            result_type = if (result_type == .never) v.type else join(c, result_type, v.type);
        } else {
            f.enter();
            _ = try expr.compile(f, prong.body, null, .unknown);
            try f.leave();
        }
        any_reachable = any_reachable or f.reachable;
        f.release(s.reg + 1);
        try ends.append(c.gpa, try f.jumpForward(.jmp, 0, 0));
        if (next) |n| try f.patchHere(n);
    }
    if (!has_else) {
        if (e) |en| {
            var missing: std.ArrayList(u8) = .empty;
            defer missing.deinit(c.gpa);
            for (covered.items, en.members) |done, name| if (!done) {
                if (missing.items.len > 0) try missing.appendSlice(c.gpa, ", ");
                try missing.print(c.gpa, ".{s}", .{name});
            };
            if (missing.items.len > 0) {
                _ = try (try c.err(span, "this switch does not handle {s}", .{missing.items}))
                    .help("add a case for each, or an `else => ...`", .{});
            }
        } else if (wants_value and !(bools[0] and bools[1])) {
            _ = try (try c.err(span, "a switch that gives a value needs an `else`", .{}))
                .help("add `else => ...` for everything the cases do not name", .{});
        }
        if (wants_value) {
            try f.abc(.loadnull, out, 0, 0);
        }
        any_reachable = true;
    }
    try f.patchAll(ends.items, f.here());
    f.reachable = any_reachable;
    f.release(if (wants_value) @max(mark, out + 1) else mark);
    const t = if (concrete(expected)) expected else if (result_type == .never and any_reachable) Type.any else result_type;
    return .{ .reg = out, .type = t, .temp = dst == null };
}
