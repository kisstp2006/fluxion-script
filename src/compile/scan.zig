// SPDX-License-Identifier: BSD-2-Clause

//! Questions answered by looking through a function's body before compiling
//! it: does it return a value, does it `await`. Lambdas inside are their own
//! functions and are not looked into.

const std = @import("std");
const ast = @import("../syntax/ast.zig");

const Question = enum { returns_value, awaits };

pub fn returnsValue(b: *const ast.Block) bool {
    return block(b, .returns_value);
}

pub fn fnAwaits(f: *const ast.Fn) bool {
    return switch (f.body) {
        .block => |b| block(b, .awaits),
        .expr => |e| expr(e, .awaits),
    };
}

fn block(b: *const ast.Block, q: Question) bool {
    for (b.stmts) |s| if (stmt(s, q)) return true;
    return false;
}

fn stmt(s: *const ast.Stmt, q: Question) bool {
    return switch (s.kind) {
        .expr => |e| expr(e, q),
        .@"var" => |v| if (v.value) |e| expr(e, q) else false,
        .assign => |a| expr(a.target, q) or expr(a.value, q),
        .block => |b| block(b, q),
        .@"if" => |x| expr(x.cond, q) or stmt(x.then, q) or (if (x.@"else") |e| stmt(e, q) else false),
        .@"while" => |x| expr(x.cond, q) or stmt(x.body, q) or (if (x.next) |n| stmt(n, q) else false),
        .@"for" => |x| expr(x.iterable, q) or stmt(x.body, q),
        .@"switch" => |sw| switchNode(sw, q),
        .@"defer" => |d| stmt(d.body, q),
        .@"fn", .@"struct", .@"enum", .@"test", .invalid => false,
    };
}

fn switchNode(sw: *const ast.Switch, q: Question) bool {
    if (expr(sw.subject, q)) return true;
    for (sw.prongs) |p| if (expr(p.body, q)) return true;
    return false;
}

fn any(items: []const *ast.Expr, q: Question) bool {
    for (items) |e| if (expr(e, q)) return true;
    return false;
}

fn expr(e: *const ast.Expr, q: Question) bool {
    return switch (e.kind) {
        .@"return" => |v| q == .returns_value and v != null or (if (v) |x| expr(x, q) else false),
        .@"await" => |x| q == .awaits or expr(x, q),
        .int, .float, .bool, .null, .string, .enum_literal, .ident, .self, .invalid, .@"break", .@"continue", .lambda => false,
        .fstring => |parts| blk: {
            for (parts) |p| switch (p) {
                .expr => |x| if (expr(x.value, q)) break :blk true,
                .literal => {},
            };
            break :blk false;
        },
        .error_literal => |x| if (x.message) |m| expr(m, q) else false,
        .list => |items| any(items, q),
        .map => |entries| blk: {
            for (entries) |entry| if (expr(entry.key, q) or expr(entry.value, q)) break :blk true;
            break :blk false;
        },
        .struct_literal => |s| blk: {
            for (s.fields) |f| if (expr(f.value, q)) break :blk true;
            break :blk false;
        },
        .unary => |u| expr(u.operand, q),
        .binary => |b| expr(b.lhs, q) or expr(b.rhs, q),
        .is_type => |x| expr(x.value, q),
        .@"orelse" => |x| expr(x.lhs, q) or expr(x.rhs, q),
        .@"catch" => |x| expr(x.lhs, q) or expr(x.rhs, q),
        .@"try" => |x| expr(x, q),
        .call => |c| expr(c.callee, q) or any(c.args, q),
        .index => |x| expr(x.target, q) or expr(x.index, q),
        .slice => |x| expr(x.target, q) or (if (x.start) |s| expr(s, q) else false) or (if (x.end) |s| expr(s, q) else false),
        .field => |f| expr(f.target, q),
        .unwrap => |x| expr(x, q),
        .@"if" => |x| expr(x.cond, q) or expr(x.then, q) or expr(x.@"else", q),
        .@"switch" => |sw| switchNode(sw, q),
        .builtin => |b| any(b.args, q),
        .range => |r| expr(r.start, q) or (if (r.end) |x| expr(x, q) else false),
        .block => |b| block(b, q),
    };
}

test "a return with a value is found, a lambda's is not" {
    const empty: ast.Block = .{ .span = .empty, .stmts = &.{} };
    try std.testing.expect(!returnsValue(&empty));
}
