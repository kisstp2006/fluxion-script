// SPDX-License-Identifier: BSD-2-Clause

//! Expressions worked out while compiling: `1.0 / 60.0`, `MAX * 2`, `-5`.
//! What would overflow or divide by zero is left for run time, which says
//! so with a line number.

const std = @import("std");

const ast = @import("../syntax/ast.zig");
const Value = @import("../vm/value.zig").Value;
const types = @import("types.zig");
const Type = types.Type;
const Compiler = @import("Compiler.zig");

pub const Literal = struct { type: Type, value: Value };

fn int(i: i64) Literal {
    return .{ .type = .int, .value = .int(i) };
}

fn float(f: f64) Literal {
    return .{ .type = .float, .value = .float(f) };
}

fn boolean(b: bool) Literal {
    return .{ .type = .bool, .value = .boolean(b) };
}

pub fn fold(c: *Compiler, e: *const ast.Expr) ?Literal {
    return foldDepth(c, null, e, 0);
}

/// The same inside a function, where a local may hide a module constant.
pub fn foldIn(f: *const Func, e: *const ast.Expr) ?Literal {
    return foldDepth(f.comp, f, e, 0);
}

const Func = @import("Func.zig");

fn shadowed(f: ?*const Func, name: []const u8) bool {
    var at = f;
    while (at) |x| : (at = x.parent) {
        for (x.locals.items) |l| if (std.mem.eql(u8, l.name, name)) return true;
        for (x.upvals.items) |u| if (std.mem.eql(u8, u.name, name)) return true;
    }
    return false;
}

fn foldDepth(c: *Compiler, f: ?*const Func, e: *const ast.Expr, depth: u32) ?Literal {
    if (depth > 64) return null;
    switch (e.kind) {
        .int => |i| return int(i),
        .float => |x| return float(x),
        .bool => |b| return boolean(b),
        .string => |s| return .{ .type = .string, .value = c.vm.string(s) catch return null },
        .ident => |name| {
            if (shadowed(f, name)) return null;
            const g = c.global(name) orelse return null;
            if (g.kind != .constant) return null;
            const v = g.value orelse return null;
            return .{ .type = g.type, .value = v };
        },
        .unary => |u| {
            const x = foldDepth(c, f, u.operand, depth + 1) orelse return null;
            return switch (u.op) {
                .neg => switch (x.type) {
                    .int => if (x.value.asInt() == std.math.minInt(i64)) null else int(-x.value.asInt()),
                    .float => float(-x.value.asFloat()),
                    else => null,
                },
                .not => if (x.type == .bool) boolean(!x.value.asBool()) else null,
                .bit_not => if (x.type == .int) int(~x.value.asInt()) else null,
            };
        },
        .binary => |b| {
            const l = foldDepth(c, f, b.lhs, depth + 1) orelse return null;
            const r = foldDepth(c, f, b.rhs, depth + 1) orelse return null;
            return binary(b.op, l, r);
        },
        else => return null,
    }
}

fn binary(op: ast.BinaryOp, l: Literal, r: Literal) ?Literal {
    if (l.type == .bool and r.type == .bool) {
        const x = l.value.asBool();
        const y = r.value.asBool();
        return switch (op) {
            .@"and" => boolean(x and y),
            .@"or" => boolean(x or y),
            .eq => boolean(x == y),
            .ne => boolean(x != y),
            else => null,
        };
    }
    if (l.type == .int and r.type == .int) {
        const x = l.value.asInt();
        const y = r.value.asInt();
        return switch (op) {
            .add => if (@addWithOverflow(x, y)[1] == 0) int(x + y) else null,
            .sub => if (@subWithOverflow(x, y)[1] == 0) int(x - y) else null,
            .mul => if (@mulWithOverflow(x, y)[1] == 0) int(x * y) else null,
            .div => if (y == 0 or (x == std.math.minInt(i64) and y == -1)) null else int(@divTrunc(x, y)),
            .mod => if (y == 0) null else int(if (y == -1) 0 else @rem(x, y)),
            .add_wrap => int(x +% y),
            .sub_wrap => int(x -% y),
            .mul_wrap => int(x *% y),
            .bit_and => int(x & y),
            .bit_or => int(x | y),
            .bit_xor => int(x ^ y),
            .shl => if (y < 0 or y > 63) null else int(x << @intCast(y)),
            .shr => if (y < 0 or y > 63) null else int(x >> @intCast(y)),
            .eq => boolean(x == y),
            .ne => boolean(x != y),
            .lt => boolean(x < y),
            .le => boolean(x <= y),
            .gt => boolean(x > y),
            .ge => boolean(x >= y),
            else => null,
        };
    }
    const x = l.value.toFloat() orelse return null;
    const y = r.value.toFloat() orelse return null;
    if (!(l.type == .float or l.type == .int) or !(r.type == .float or r.type == .int)) return null;
    return switch (op) {
        .add => float(x + y),
        .sub => float(x - y),
        .mul => float(x * y),
        .div => float(x / y),
        .mod => float(@rem(x, y)),
        .eq => boolean(x == y),
        .ne => boolean(x != y),
        .lt => boolean(x < y),
        .le => boolean(x <= y),
        .gt => boolean(x > y),
        .ge => boolean(x >= y),
        else => null,
    };
}
