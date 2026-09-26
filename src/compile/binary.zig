// SPDX-License-Identifier: BSD-2-Clause

//! Operators, typed where the types are known: `a + b` on two ints is one
//! instruction that never looks at a tag. And `coerce`, the one place a
//! value meets the type of the place it goes.

const std = @import("std");

const diag = @import("../diag.zig");
const ast = @import("../syntax/ast.zig");
const code = @import("../vm/code.zig");
const Op = code.Op;
const types = @import("types.zig");
const Type = types.Type;
const Func = @import("Func.zig");
const Compiler = @import("Compiler.zig");
const expr = @import("expr.zig");
const Operand = expr.Operand;
const Error = Compiler.Error;

/// Makes `op` a `to`: widens an int to a float, checks an `any` at run time,
/// or reports why it cannot be. `what` names the place for the message.
pub fn coerce(f: *Func, op: Operand, to: Type, span: diag.Span, what: []const u8) Error!Operand {
    const c = f.comp;
    const pool = c.pool;
    const from = op.type;
    if (to == .unknown or from == .unknown or from == .never) return op;
    if (to == .any) return .{ .reg = op.reg, .type = if (from == .void) .any else from, .temp = op.temp };
    if (from == to) return op;
    if (from == .void) {
        _ = try c.err(span, "this gives no value, and {s} needs one", .{what});
        return .{ .reg = op.reg, .type = .unknown, .temp = op.temp };
    }
    if (from == .any) {
        const out = try owned(f, op);
        const check = try pool.check(&c.vm.checks, c.vm.gpa, to);
        if (check != .any) try f.abx(.check, out.reg, @intCast(@intFromEnum(check)));
        return .{ .reg = out.reg, .type = to, .temp = out.temp };
    }
    if (to == .float and from == .int) {
        const out = try owned(f, op);
        try f.abc(.to_float, out.reg, out.reg, 0);
        return .{ .reg = out.reg, .type = .float, .temp = out.temp };
    }
    if (pool.isOptional(to)) |child| {
        if (from == .null) return .{ .reg = op.reg, .type = to, .temp = op.temp };
        if (pool.isOptional(from)) |inner| {
            if (inner == child or child == .any) return .{ .reg = op.reg, .type = to, .temp = op.temp };
            if (compatible(c, inner, child)) return .{ .reg = op.reg, .type = to, .temp = op.temp };
        } else {
            const inner = try coerce(f, op, child, span, what);
            return .{ .reg = inner.reg, .type = to, .temp = inner.temp };
        }
    }
    if (pool.isErrorUnion(to)) |child| {
        if (from == .@"error") return .{ .reg = op.reg, .type = to, .temp = op.temp };
        if (pool.isErrorUnion(from)) |inner| {
            if (inner == child or compatible(c, inner, child)) return .{ .reg = op.reg, .type = to, .temp = op.temp };
        } else {
            const inner = try coerce(f, op, child, span, what);
            return .{ .reg = inner.reg, .type = to, .temp = inner.temp };
        }
    }
    if (compatible(c, from, to)) return .{ .reg = op.reg, .type = to, .temp = op.temp };
    try mismatch(f, from, to, span, what);
    return .{ .reg = op.reg, .type = .unknown, .temp = op.temp };
}

/// Whether a `from` is a `to` without anything done to it.
pub fn compatible(c: *Compiler, from: Type, to: Type) bool {
    if (from == to or to == .any or from == .unknown or to == .unknown or from == .never) return true;
    const pool = c.pool;
    if (pool.structOf(from)) |a| if (pool.structOf(to)) |b| return a.extends(b);
    if (pool.hostOf(from)) |a| if (pool.hostOf(to)) |b| return a.same(b) or isArm(a, b);
    if (pool.listOf(from)) |a| if (pool.listOf(to)) |b| return b == .any or a == .unknown or b == .unknown;
    if (pool.mapOf(from)) |a| if (pool.mapOf(to)) |b| return (b.key == .any and b.value == .any) or a.key == .unknown or a.value == .unknown or b.key == .unknown or b.value == .unknown;
    if (pool.signatureOf(to)) |want| {
        const have = pool.signatureOf(from) orelse return false;
        const self = @intFromBool(have.has_self);
        if (want.params.len + self < have.required() or want.params.len + self > have.params.len) return false;
        if (want.ret == .void or Compiler.dynamic(want.ret)) return true;
        // A coroutine called without `await` gives a task, not its result.
        if (have.coroutine and !want.coroutine) return false;
        return have.ret == .any or compatible(c, have.ret, want.ret);
    }
    if (from == .null) return pool.nullable(to);
    return false;
}

/// Whether `t` is the payload of an arm of the host's union `u`: a value of
/// it is a `u`.
fn isArm(t: *const @import("fluxion_reflect").Type, u: *const @import("fluxion_reflect").Type) bool {
    if (u.kind != .@"union") return false;
    for (u.fields()) |arm| if (arm.type.same(t)) return true;
    return false;
}

fn mismatch(f: *Func, from: Type, to: Type, span: diag.Span, what: []const u8) Error!void {
    const c = f.comp;
    const pool = c.pool;
    if (from == .null) {
        _ = try (try c.err(span, "{s} is {s}, which cannot be null", .{ what, c.typeName(to) }))
            .help("make it `?{s}` to allow null", .{c.typeName(to)});
        return;
    }
    if (pool.isOptional(from)) |child| if (compatible(c, child, to)) {
        _ = try (try (try c.err(span, "{s} must be {s}, but this may be null", .{ what, c.typeName(to) }))
            .text("this is {s}", .{c.typeName(from)}))
            .help("unwrap it: `x orelse default`, `x.?`, or `if (x) |value| {{ ... }}`", .{});
        return;
    };
    if (pool.isErrorUnion(from)) |child| if (compatible(c, child, to)) {
        _ = try (try (try c.err(span, "{s} must be {s}, but this may be an error", .{ what, c.typeName(to) }))
            .text("this is {s}", .{c.typeName(from)}))
            .help("pass the error on with `try`, or handle it with `catch |err| ...`", .{});
        return;
    };
    if (from == .float and to == .int) {
        _ = try (try (try c.err(span, "{s} must be an int, not a float", .{what}))
            .text("a float", .{}))
            .help("convert it with `int(...)`, which drops the fraction", .{});
        return;
    }
    _ = try (try c.err(span, "{s} must be {s}, not {s}", .{ what, c.typeName(to), c.typeName(from) }))
        .text("this is {s}", .{c.typeName(from)});
}

/// `op` in a register this expression may change.
pub fn owned(f: *Func, op: Operand) Error!Operand {
    if (op.temp) return op;
    const r = try f.alloc();
    try f.abc(.move, r, op.reg, 0);
    return .{ .reg = r, .type = op.type, .temp = true };
}

fn arithmeticOp(op: ast.BinaryOp) ?@import("../vm/ops.zig").Arith {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .add_wrap => .add_wrap,
        .sub_wrap => .sub_wrap,
        .mul_wrap => .mul_wrap,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .shl => .shl,
        .shr => .shr,
        else => null,
    };
}

fn genericOp(op: ast.BinaryOp) Op {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .add_wrap => .add_wrap,
        .sub_wrap => .sub_wrap,
        .mul_wrap => .mul_wrap,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .shl => .shl,
        .shr => .shr,
        else => unreachable,
    };
}

fn intOp(op: ast.BinaryOp) ?Op {
    return switch (op) {
        .add => .add_ii,
        .sub => .sub_ii,
        .mul => .mul_ii,
        .div => .div_ii,
        .mod => .mod_ii,
        else => null,
    };
}

fn floatOp(op: ast.BinaryOp) ?Op {
    return switch (op) {
        .add => .add_ff,
        .sub => .sub_ff,
        .mul => .mul_ff,
        .div => .div_ff,
        else => null,
    };
}

fn isNumber(t: Type) bool {
    return t == .int or t == .float;
}

fn isVector(t: Type) bool {
    return t == .vec2 or t == .vec3;
}

/// The type `a op b` has, or null when it has none.
fn arithmeticType(c: *Compiler, op: ast.BinaryOp, a: Type, b: Type) ?Type {
    if (Compiler.dynamic(a) or Compiler.dynamic(b)) return .any;
    const bits = switch (op) {
        .bit_and, .bit_or, .bit_xor, .shl, .shr, .add_wrap, .sub_wrap, .mul_wrap => true,
        else => false,
    };
    if (bits) return if (a == .int and b == .int) .int else null;
    if (a == .int and b == .int) return .int;
    if (isNumber(a) and isNumber(b)) return .float;
    if (isVector(a) and a == b and op != .mod) return a;
    if (isVector(a) and isNumber(b) and (op == .mul or op == .div)) return a;
    if (isNumber(a) and isVector(b) and op == .mul) return b;
    if (op == .add and a == .string and b == .string) return .string;
    if (op == .mul and a == .string and b == .int) return .string;
    if (op == .add) if (c.pool.listOf(a)) |x| if (c.pool.listOf(b)) |y| return if (x == y) a else c.pool.list(.any) catch null;
    return null;
}

pub fn binary(f: *Func, e: *const ast.Expr, dst: ?u8) Error!Operand {
    const b = e.kind.binary;
    switch (b.op) {
        .@"and", .@"or" => return logical(f, e, dst),
        .eq, .ne, .lt, .le, .gt, .ge => return comparison(f, e, dst),
        .in => {
            const mark = f.free;
            const item = try expr.compile(f, b.lhs, null, .unknown);
            const container = try expr.compile(f, b.rhs, null, .unknown);
            const out = try result(f, dst, mark);
            try f.abc(.in, out, item.reg, container.reg);
            return .{ .reg = out, .type = .bool, .temp = dst == null };
        },
        else => {},
    }
    const mark = f.free;
    const l = try expr.compile(f, b.lhs, null, .unknown);
    return apply(f, b.op, l, b.rhs, e.span, dst, mark);
}

/// `left op rhs`, with `left` already in a register: what `x op= v` and
/// `a op b` both come down to.
pub fn apply(f: *Func, op_kind: ast.BinaryOp, l: Operand, rhs: *const ast.Expr, span: diag.Span, dst: ?u8, mark: u8) Error!Operand {
    const c = f.comp;
    if (rhs.kind == .int and l.type == .int) {
        const lit = rhs.kind.int;
        const n = if (op_kind == .sub) -%lit else lit;
        const op: ?Op = switch (op_kind) {
            .add, .sub => .addi_i,
            .mul => .muli_i,
            .mod => if (lit != 0) .modi_i else null,
            else => null,
        };
        if (op != null and n >= -128 and n <= 127) {
            const out = try result(f, dst, mark);
            try f.abc(op.?, out, l.reg, @bitCast(@as(i8, @intCast(n))));
            return .{ .reg = out, .type = .int, .temp = dst == null };
        }
    }
    var r = try expr.compile(f, rhs, null, if (l.type == .float) .float else .unknown);
    var left = l;
    const t = arithmeticType(c, op_kind, left.type, r.type) orelse {
        try cannot(f, op_kind, span, rhs.span, left.type, r.type);
        return .{ .reg = try result(f, dst, mark), .type = .unknown, .temp = dst == null };
    };
    if (t == .float and left.type == .int) left = try coerce(f, left, .float, span, "");
    if (t == .float and r.type == .int) r = try coerce(f, r, .float, rhs.span, "");
    if (isVector(t)) if (try vectorOp(f, op_kind, t, &left, &r, span, rhs.span)) |vop| {
        const out = try result(f, dst, mark);
        try f.abc(vop, out, left.reg, r.reg);
        return .{ .reg = out, .type = t, .temp = dst == null };
    };
    const out = try result(f, dst, mark);
    const op: Op = if (t == .int and left.type == .int and r.type == .int)
        intOp(op_kind) orelse genericOp(op_kind)
    else if (t == .float and left.type == .float and r.type == .float)
        floatOp(op_kind) orelse genericOp(op_kind)
    else
        genericOp(op_kind);
    try f.abc(op, out, left.reg, r.reg);
    return .{ .reg = out, .type = t, .temp = dst == null };
}

/// The typed instruction for vector arithmetic, operands put in the order
/// it takes them: the vector first, a number widened to a float.
fn vectorOp(f: *Func, op: ast.BinaryOp, t: Type, left: *Operand, right: *Operand, lspan: diag.Span, rspan: diag.Span) Error!?Op {
    const two = t == .vec2;
    if (left.type == t and right.type == t) {
        return switch (op) {
            .add => if (two) .add_v2 else .add_v3,
            .sub => if (two) .sub_v2 else .sub_v3,
            .mul => if (two) .mul_v2 else .mul_v3,
            else => null,
        };
    }
    if (left.type == t and isNumber(right.type)) {
        if (op != .mul and op != .div) return null;
        right.* = try coerce(f, right.*, .float, rspan, "");
        return if (op == .mul) (if (two) .mul_v2f else .mul_v3f) else (if (two) .div_v2f else .div_v3f);
    }
    if (isNumber(left.type) and right.type == t and op == .mul) {
        const scalar = try coerce(f, left.*, .float, lspan, "");
        left.* = right.*;
        right.* = scalar;
        return if (two) .mul_v2f else .mul_v3f;
    }
    return null;
}

fn cannot(f: *Func, op: ast.BinaryOp, span: diag.Span, rhs_span: diag.Span, a: Type, b: Type) Error!void {
    const c = f.comp;
    const pool = c.pool;
    const h = try c.err(span, "cannot use `{s}` on {s} and {s}", .{ op.symbol(), c.typeName(a), c.typeName(b) });
    const unready = struct {
        fn is(p: *types.Pool, t: Type) bool {
            return p.isErrorUnion(t) != null or p.isOptional(t) != null;
        }
    }.is;
    if (unready(pool, b)) _ = try h.label(c.at(rhs_span), "this is {s}", .{c.typeName(b)});
    if (pool.isErrorUnion(a) != null or pool.isErrorUnion(b) != null) {
        _ = try h.help("use it once its error is handled - `x catch 0` - or pass the error on with `try x`", .{});
    } else if (unready(pool, a) or unready(pool, b)) {
        _ = try h.help("use it once it is unwrapped: `x orelse 0`, `x.?`, or `if (x) |v| ...`", .{});
    } else if (op == .add and (a == .string or b == .string)) {
        _ = try h.help("build the text with an f-string: f\"{{a}}{{b}}\", or convert with str()", .{});
    } else if (a == .int and b == .float or a == .float and b == .int) {
        _ = try h.help("bit operations and wrapping arithmetic are for ints", .{});
    }
}

/// Where the result goes: `dst`, or the first register the operands used.
/// Either way the operands' registers are free again after it, so the
/// arguments of a call stay side by side.
pub fn result(f: *Func, dst: ?u8, mark: u8) Error!u8 {
    f.release(mark);
    if (dst) |d| return d;
    return f.alloc();
}

fn logical(f: *Func, e: *const ast.Expr, dst: ?u8) Error!Operand {
    const b = e.kind.binary;
    const out = dst orelse try f.alloc();
    const mark = f.free;
    const l = try expr.compile(f, b.lhs, out, .bool);
    try boolOperand(f, l.type, b.lhs.span, b.op);
    const skip = try f.jumpForward(if (b.op == .@"and") .jfalse else .jtrue, out, 0);
    const narrowed = try @import("control.zig").narrow(f, b.lhs, b.op == .@"and");
    const r = try expr.compile(f, b.rhs, out, .bool);
    f.unnarrow(narrowed);
    try boolOperand(f, r.type, b.rhs.span, b.op);
    try f.patchHere(skip);
    f.release(mark);
    return .{ .reg = out, .type = .bool, .temp = dst == null };
}

fn boolOperand(f: *Func, t: Type, span: diag.Span, op: ast.BinaryOp) Error!void {
    if (t == .bool or Compiler.dynamic(t) or t == .never) return;
    const c = f.comp;
    _ = try (try c.err(span, "`{s}` needs bools on both sides, and this is {s}", .{ op.symbol(), c.typeName(t) }))
        .help("compare it: `x != null`, `x > 0`, `!s.is_empty()`", .{});
}

pub fn comparable(c: *Compiler, a: Type, b: Type, op: ast.BinaryOp) bool {
    if (Compiler.dynamic(a) or Compiler.dynamic(b)) return true;
    if (isNumber(a) and isNumber(b)) return true;
    if (op == .eq or op == .ne) {
        if (a == b) return true;
        if (a == .null) return c.pool.nullable(b);
        if (b == .null) return c.pool.nullable(a);
        if (c.pool.isOptional(a)) |x| return x == b or compatible(c, b, x);
        if (c.pool.isOptional(b)) |x| return x == a or compatible(c, a, x);
        if (a == .@"error" or b == .@"error") return c.pool.isErrorUnion(a) != null or c.pool.isErrorUnion(b) != null or a == b;
        return compatible(c, a, b) or compatible(c, b, a);
    }
    return a == .string and b == .string;
}

fn comparison(f: *Func, e: *const ast.Expr, dst: ?u8) Error!Operand {
    const b = e.kind.binary;
    const c = f.comp;
    const mark = f.free;
    var l = try expr.compile(f, b.lhs, null, .unknown);
    var r = try expr.compile(f, b.rhs, null, l.type);
    if (!comparable(c, l.type, r.type, b.op)) {
        const h = try c.err(e.span, "cannot compare {s} with {s}", .{ c.typeName(l.type), c.typeName(r.type) });
        if (b.op == .eq or b.op == .ne) _ = try h.note("values of different types are never equal", .{});
        return .{ .reg = try result(f, dst, mark), .type = .bool, .temp = dst == null };
    }
    if (l.type == .int and r.type == .float) l = try coerce(f, l, .float, b.lhs.span, "");
    if (l.type == .float and r.type == .int) r = try coerce(f, r, .float, b.rhs.span, "");
    const out = try result(f, dst, mark);
    const swap = b.op == .gt or b.op == .ge;
    const x = if (swap) r.reg else l.reg;
    const y = if (swap) l.reg else r.reg;
    const ints = l.type == .int and r.type == .int;
    const floats = l.type == .float and r.type == .float;
    const op: Op = switch (b.op) {
        .eq, .ne => if (ints) .eq_ii else .eq,
        .lt, .gt => if (ints) .lt_ii else if (floats) .lt_ff else .lt,
        .le, .ge => if (ints) .le_ii else if (floats) .le_ff else .le,
        else => unreachable,
    };
    try f.abc(op, out, x, y);
    if (b.op == .ne) try f.abc(.not, out, out, 0);
    return .{ .reg = out, .type = .bool, .temp = dst == null };
}

pub fn unary(f: *Func, e: *const ast.Expr, dst: ?u8) Error!Operand {
    const u = e.kind.unary;
    const c = f.comp;
    const mark = f.free;
    const v = try expr.compile(f, u.operand, null, .unknown);
    const out = try result(f, dst, mark);
    switch (u.op) {
        .neg => {
            const op: Op = switch (v.type) {
                .int => .neg_i,
                .float => .neg_f,
                else => .neg,
            };
            if (!(v.type == .int or v.type == .float or isVector(v.type) or Compiler.dynamic(v.type))) {
                _ = try c.err(e.span, "cannot negate {s}", .{c.typeName(v.type)});
            }
            try f.abc(op, out, v.reg, 0);
            return .{ .reg = out, .type = if (Compiler.dynamic(v.type)) .any else v.type, .temp = dst == null };
        },
        .not => {
            if (!(v.type == .bool or Compiler.dynamic(v.type))) {
                _ = try (try c.err(e.span, "`!` needs a bool, and this is {s}", .{c.typeName(v.type)}))
                    .help("compare it instead: `x == null`, `x == 0`", .{});
            }
            try f.abc(.not, out, v.reg, 0);
            return .{ .reg = out, .type = .bool, .temp = dst == null };
        },
        .bit_not => {
            if (!(v.type == .int or Compiler.dynamic(v.type))) _ = try c.err(e.span, "`~` needs an int, and this is {s}", .{c.typeName(v.type)});
            try f.abc(.bit_not, out, v.reg, 0);
            return .{ .reg = out, .type = .int, .temp = dst == null };
        },
    }
}

pub fn compoundType(c: *Compiler, op: ast.BinaryOp, a: Type, b: Type) ?Type {
    return arithmeticType(c, op, a, b);
}

test {
    _ = arithmeticOp;
}
