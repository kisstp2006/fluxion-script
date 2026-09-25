// SPDX-License-Identifier: BSD-2-Clause

//! What a name means where it is written: a local, a variable captured from
//! an enclosing function, a module variable, or something built in.

const std = @import("std");

const diag = @import("../diag.zig");
const ast = @import("../syntax/ast.zig");
const Value = @import("../vm/value.zig").Value;
const object = @import("../vm/object.zig");
const access = @import("../vm/access.zig");
const types = @import("types.zig");
const Type = types.Type;
const Func = @import("Func.zig");
const Compiler = @import("Compiler.zig");
const Error = Compiler.Error;
const expr = @import("expr.zig");
const Operand = expr.Operand;

pub const Place = union(enum) {
    local: u8,
    upval: u8,
    global: *Compiler.Global,
    builtin: Value,
    none,
};

pub fn lookup(f: *Func, name: []const u8) Error!Place {
    if (f.findLocal(name)) |l| {
        l.used = true;
        return .{ .local = l.reg };
    }
    if (try f.findUpval(name)) |u| return .{ .upval = u };
    if (f.comp.global(name)) |g| return .{ .global = g };
    const key = f.comp.vm.interned.find(name, @import("../vm/strings.zig").hashBytes(name));
    if (key) |k| if (f.comp.vm.prelude.get(k)) |v| return .{ .builtin = v };
    return .none;
}

pub fn typeOf(f: *Func, place: Place) Type {
    return switch (place) {
        .local => |r| for (f.locals.items) |l| {
            if (l.reg == r) break l.type;
        } else .unknown,
        .upval => |u| f.upvals.items[u].type,
        .global => |g| g.type,
        .builtin => .any,
        .none => .unknown,
    };
}

pub fn localByReg(f: *Func, r: u8) ?*Func.Local {
    var i = f.locals.items.len;
    while (i > 0) {
        i -= 1;
        if (f.locals.items[i].reg == r) return &f.locals.items[i];
    }
    return null;
}

pub fn read(f: *Func, name: []const u8, span: diag.Span, dst: ?u8) Error!Operand {
    const c = f.comp;
    if (std.mem.eql(u8, name, "self") and f.findLocal("self") == null and (try f.findUpval("self")) == null) {
        _ = try c.err(span, "`self` is only inside a method: a function in a struct whose first parameter is `self`", .{});
        return .{ .reg = try expr.target(f, dst), .type = .unknown, .temp = dst == null };
    }
    const place = try lookup(f, name);
    if (c.recording()) |rec| try rec.place(f, name, span, place);
    switch (place) {
        .local => |r| {
            const l = localByReg(f, r).?;
            if (dst) |d| {
                if (d != r) try f.abc(.move, d, r, 0);
                return .{ .reg = d, .type = l.type, .temp = false, .host = l.host };
            }
            return .{ .reg = r, .type = l.type, .temp = false, .host = l.host };
        },
        .upval => |u| {
            const r = try expr.target(f, dst);
            try f.abc(.getupval, r, u, 0);
            return .{ .reg = r, .type = f.upvals.items[u].type, .temp = dst == null };
        },
        .global => |g| {
            switch (g.kind) {
                // An import that failed has no value, and has been reported.
                .@"struct", .@"enum", .import => if (g.value) |v| return expr.constant(f, dst, v, g.type) else return .{ .reg = try expr.target(f, dst), .type = .unknown, .temp = dst == null },
                .constant => if (g.value) |v| return expr.constant(f, dst, v, g.type),
                else => {},
            }
            const r = try expr.target(f, dst);
            try f.abx(.getglobal, r, @intCast(g.index));
            return .{ .reg = r, .type = g.type, .temp = dst == null };
        },
        .builtin => |v| {
            var op = try expr.constant(f, dst, v, .any);
            op.host = @import("host.zig").ofGlobal(c.vm, name, v);
            return op;
        },
        .none => {
            try notDeclared(f, name, span);
            return .{ .reg = try expr.target(f, dst), .type = .unknown, .temp = dst == null };
        },
    }
}

pub fn notDeclared(f: *Func, name: []const u8, span: diag.Span) Error!void {
    const c = f.comp;
    if (c.recording()) |r| if (r.isPlaceholder(name)) return r.scope(f);
    var candidates: std.ArrayList([]const u8) = .empty;
    defer candidates.deinit(c.gpa);
    var at: ?*Func = f;
    while (at) |x| : (at = x.parent) for (x.locals.items) |l| try candidates.append(c.gpa, l.name);
    for (c.globals.keys()) |k| try candidates.append(c.gpa, k);
    var it = c.vm.prelude.keyIterator();
    while (it.next()) |k| try candidates.append(c.gpa, k.*.bytes());
    const h = try c.err(span, "`{s}` is not declared", .{name});
    if (access.nearest(name, candidates.items)) |near| {
        _ = try h.help("did you mean `{s}`?", .{near});
    } else if (std.mem.eql(u8, name, "math") or std.mem.eql(u8, name, "json")) {
        _ = try h.help("import it first: `const {s} = @import(\"{s}\");`", .{ name, name });
    }
}

/// The type a type name used as a value stands for: `Player` in
/// `Player{ ... }`.
pub fn typeValue(f: *Func, e: *const ast.Expr) Error!Type {
    const c = f.comp;
    switch (e.kind) {
        .ident => |name| {
            const g = c.global(name) orelse {
                try notDeclared(f, name, e.span);
                return .unknown;
            };
            if (c.recording()) |r| try r.global(c, e.span, g.*);
            return c.pool.metaOf(g.type) orelse {
                _ = try c.err(e.span, "`{s}` is not a type", .{name});
                return .unknown;
            };
        },
        .field => |fl| {
            if (fl.target.kind != .ident) return .unknown;
            const g = c.global(fl.target.kind.ident) orelse return .unknown;
            const m = c.pool.moduleOf(g.type) orelse return .unknown;
            if (c.recording()) |r| try r.global(c, fl.target.span, g.*);
            const ex = m.exports.get(fl.name.text) orelse {
                _ = try c.err(fl.name.span, "module `{s}` has no `{s}`", .{ m.name, fl.name.text });
                return .unknown;
            };
            if (c.recording()) |r| try r.exported(fl.name.span, g.type, m, fl.name.text, ex);
            return c.pool.metaOf(ex.type) orelse .unknown;
        },
        else => return .unknown,
    }
}
