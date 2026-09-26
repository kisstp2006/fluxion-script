// SPDX-License-Identifier: BSD-2-Clause

//! Expressions: each compiled into a register, with the type it is known to
//! have. `expected` is the type the place wants, which is how `.idle` finds
//! its enum, `[]` its element type and a lambda its parameters' types.

const std = @import("std");

const diag = @import("../diag.zig");
const ast = @import("../syntax/ast.zig");
const Value = @import("../vm/value.zig").Value;
const object = @import("../vm/object.zig");
const make = @import("../vm/make.zig");
const access = @import("../vm/access.zig");
const types = @import("types.zig");
const Type = types.Type;
const Func = @import("Func.zig");
const Compiler = @import("Compiler.zig");
const Error = Compiler.Error;
const binary = @import("binary.zig");
const names = @import("names.zig");
const member = @import("member.zig");
const call = @import("call.zig");
const control = @import("control.zig");
const body = @import("body.zig");

pub const Operand = struct {
    reg: u8,
    type: Type,
    /// The register was taken for this expression, and may be changed.
    temp: bool,
};

pub fn target(f: *Func, dst: ?u8) Error!u8 {
    return dst orelse f.alloc();
}

pub fn constant(f: *Func, dst: ?u8, v: Value, t: Type) Error!Operand {
    const r = try target(f, dst);
    switch (v.tag) {
        .int => if (v.asInt() >= std.math.minInt(i16) and v.asInt() <= std.math.maxInt(i16)) {
            try f.emitI(.loadi, r, @intCast(v.asInt()));
            return .{ .reg = r, .type = t, .temp = dst == null };
        },
        .float => {
            const x = v.asFloat();
            if (x == @trunc(x) and x >= -32768 and x <= 32767 and !(x == 0 and std.math.signbit(x))) {
                try f.emitI(.loadf, r, @intFromFloat(x));
                return .{ .reg = r, .type = t, .temp = dst == null };
            }
        },
        .bool => {
            try f.abc(if (v.asBool()) .loadtrue else .loadfalse, r, 0, 0);
            return .{ .reg = r, .type = t, .temp = dst == null };
        },
        .null => {
            try f.abc(.loadnull, r, 0, 0);
            return .{ .reg = r, .type = t, .temp = dst == null };
        },
        else => {},
    }
    try f.abx(.loadk, r, try f.constant(v));
    return .{ .reg = r, .type = t, .temp = dst == null };
}

/// Whether compiling `e` straight into a variable's own register is safe:
/// true when `e` reads everything it needs before it writes its result.
fn writesLast(e: *const ast.Expr) bool {
    return switch (e.kind) {
        .int, .float, .bool, .null, .string, .enum_literal, .ident, .self, .unary, .binary, .field, .index, .call, .is_type, .unwrap, .lambda, .error_literal => true,
        else => false,
    };
}

/// `e` into `dst`, even when `dst` is a variable that `e` reads.
pub fn into(f: *Func, e: *const ast.Expr, dst: u8, expected: Type) Error!Operand {
    if (writesLast(e) or !isLocal(f, dst)) return compile(f, e, dst, expected);
    const mark = f.free;
    const v = try compile(f, e, null, expected);
    if (v.reg != dst) try f.abc(.move, dst, v.reg, 0);
    f.release(mark);
    return .{ .reg = dst, .type = v.type, .temp = false };
}

fn isLocal(f: *Func, r: u8) bool {
    for (f.locals.items) |l| if (l.reg == r) return true;
    return false;
}

/// `e` as a value of type `want`, in any register.
pub fn typed(f: *Func, e: *const ast.Expr, want: Type, what: []const u8) Error!Operand {
    const v = try compile(f, e, null, want);
    return binary.coerce(f, v, want, e.span, what);
}

/// `e` as a value of type `want`, in `dst`.
pub fn typedInto(f: *Func, e: *const ast.Expr, dst: u8, want: Type, what: []const u8) Error!Operand {
    const v = try into(f, e, dst, want);
    if (v.reg != dst) try f.abc(.move, dst, v.reg, 0);
    // Checked or converted where it is: a copy of a local made for it would
    // hold a register the next argument wants.
    const w = try binary.coerce(f, .{ .reg = dst, .type = v.type, .temp = true }, want, e.span, what);
    return .{ .reg = dst, .type = w.type, .temp = false };
}

pub fn compile(f: *Func, e: *const ast.Expr, dst: ?u8, expected: Type) Error!Operand {
    const saved = f.span;
    f.span = e.span;
    defer f.span = saved;
    const c = f.comp;
    switch (e.kind) {
        .int => |i| {
            if (expected == .float or (c.pool.isOptional(expected) orelse .unknown) == .float) return constant(f, dst, .float(@floatFromInt(i)), .float);
            return constant(f, dst, .int(i), .int);
        },
        .float => |x| return constant(f, dst, .float(x), .float),
        .bool => |b| return constant(f, dst, .boolean(b), .bool),
        .null => return constant(f, dst, .null, .null),
        .string => |s| return constant(f, dst, try c.vm.string(s), .string),
        .fstring => |parts| return fstring(f, parts, dst),
        .enum_literal => |n| return enumLiteral(f, n, dst, expected, e.span),
        .error_literal => |x| return errorLiteral(f, x.name, x.message, dst),
        .ident => |name| return names.read(f, name, e.span, dst),
        .self => return names.read(f, "self", e.span, dst),
        .list => |items| return list(f, items, dst, expected),
        .map => |entries| return mapLiteral(f, entries, dst, expected),
        .struct_literal => |s| return structLiteral(f, s.type, s.fields, dst),
        .unary, .binary => {
            if (@import("fold.zig").foldIn(f, e)) |lit| {
                if (expected == .float and lit.type == .int) return constant(f, dst, .float(@floatFromInt(lit.value.asInt())), .float);
                return constant(f, dst, lit.value, lit.type);
            }
            return if (e.kind == .unary) binary.unary(f, e, dst) else binary.binary(f, e, dst);
        },
        .is_type => |x| {
            const mark = f.free;
            const v = try compile(f, x.value, null, .unknown);
            const t = try @import("resolve.zig").typeExpr(c, x.type);
            const out = try binary.result(f, dst, mark);
            try f.abc(.is, out, v.reg, 0);
            try f.emitWord(@intFromEnum(try c.pool.check(&c.vm.checks, c.vm.gpa, t)));
            return .{ .reg = out, .type = .bool, .temp = dst == null };
        },
        .call => return call.call(f, e, dst),
        .index => return member.index(f, e, dst),
        .slice => return member.slice(f, e, dst),
        .field => return member.field(f, e, dst),
        .unwrap => |x| {
            const mark = f.free;
            const v = try compile(f, x, null, .unknown);
            const child = c.pool.isOptional(v.type) orelse blk: {
                if (!Compiler.dynamic(v.type)) {
                    _ = try (try c.err(e.span, "`.?` unwraps an optional, and this is {s}", .{c.typeName(v.type)}))
                        .text("never null", .{});
                }
                break :blk v.type;
            };
            const out = try binary.result(f, dst, mark);
            try f.abc(.unwrap, out, v.reg, 0);
            return .{ .reg = out, .type = child, .temp = dst == null };
        },
        .@"if" => return control.ifExpr(f, e, dst, expected),
        .@"switch" => |sw| return control.switchExpr(f, sw, e.span, dst, expected),
        .@"orelse" => return control.orElse(f, e, dst, expected),
        .@"catch" => return control.catchExpr(f, e, dst, expected),
        .@"try" => |x| return control.tryExpr(f, x, e.span, dst),
        .@"await" => |x| return control.awaitExpr(f, x, e.span, dst),
        .@"return" => |v| return control.returnExpr(f, v, e.span, dst),
        .@"break" => |l| return control.breakExpr(f, l, e.span, dst, false),
        .@"continue" => |l| return control.breakExpr(f, l, e.span, dst, true),
        .block => |b| return control.blockExpr(f, b, dst),
        .lambda => |l| return body.lambda(f, l, dst, expected),
        .builtin => |b| {
            if (std.mem.eql(u8, b.name.text, "import")) {
                _ = try (try c.err(e.span, "`@import` goes at the top of a file", .{}))
                    .help("write `const math = @import(\"math\");` there, and use `math` here", .{});
            } else {
                _ = try c.err(b.name.span, "there is no builtin `@{s}`", .{b.name.text});
            }
            return .{ .reg = try target(f, dst), .type = .unknown, .temp = dst == null };
        },
        .range => {
            _ = try (try c.err(e.span, "a range is written only in a `for` loop or a slice", .{}))
                .help("for a list of ints, use `range(a, b)`", .{});
            return .{ .reg = try target(f, dst), .type = .unknown, .temp = dst == null };
        },
        .invalid => return .{ .reg = try target(f, dst), .type = .unknown, .temp = dst == null },
    }
}

fn fstring(f: *Func, parts: []const ast.FPart, dst: ?u8) Error!Operand {
    const c = f.comp;
    const out = try target(f, dst);
    const mark = f.free;
    const first = f.free;
    var specs: std.ArrayList(Value) = .empty;
    defer specs.deinit(c.gpa);
    for (parts) |part| {
        const r = try f.alloc();
        switch (part) {
            .literal => |s| {
                _ = try constant(f, r, try c.vm.string(s), .string);
                try specs.append(c.gpa, .null);
            },
            .expr => |x| {
                _ = try compile(f, x.value, r, .unknown);
                try specs.append(c.gpa, if (x.spec.len > 0) try c.vm.string(x.spec) else .null);
            },
        }
    }
    const k = try f.constantRun(specs.items);
    try f.abc(.format, out, first, @intCast(parts.len));
    try f.emitWord(k);
    f.release(mark);
    return .{ .reg = out, .type = .string, .temp = dst == null };
}

fn enumLiteral(f: *Func, n: ast.Name, dst: ?u8, expected: Type, span: diag.Span) Error!Operand {
    const c = f.comp;
    const want = c.pool.isOptional(expected) orelse expected;
    const rec = c.recording();
    if (rec) |r| if (r.isPlaceholder(n.text)) {
        if (c.pool.enumOf(want) != null) r.enumMembers(want);
        if (c.pool.hostOf(want)) |u| if (u.kind == .@"union" and u.info.@"union".tag != null) r.enumMembers(try @import("host.zig").tagOf(c.vm, u));
        return .{ .reg = try target(f, dst), .type = .unknown, .temp = dst == null };
    };
    if (c.pool.hostOf(want)) |u| if (u.kind == .@"union") return armLiteral(f, n, dst, want, u);
    const e = c.pool.enumOf(want) orelse {
        _ = try (try c.err(span, "which enum is `.{s}` a member of?", .{n.text}))
            .help("name it here, as in `State.{s}`, or give the variable a type", .{n.text});
        return .{ .reg = try target(f, dst), .type = .unknown, .temp = dst == null };
    };
    if (rec) |r| if (e.index(n.text)) |i| try r.enumMember(n.span, e, i);
    const i = e.index(n.text) orelse {
        const h = try c.err(n.span, "`{s}` has no member `{s}`", .{ e.name, n.text });
        if (access.nearest(n.text, e.members)) |near| _ = try h.help("did you mean `.{s}`?", .{near});
        return .{ .reg = try target(f, dst), .type = .unknown, .temp = dst == null };
    };
    return constant(f, dst, .enumValue(&e.type_obj.obj, i), e.self_type);
}

/// `.borderless` where one of the host's unions is wanted: the arm of the
/// name, which must hold nothing.
fn armLiteral(f: *Func, n: ast.Name, dst: ?u8, want: Type, u: *const @import("fluxion_reflect").Type) Error!Operand {
    const c = f.comp;
    const name = @import("host.zig").nameOf(u);
    const i = u.fieldIndex(n.text) orelse {
        _ = try c.err(n.span, "`{s}` has no arm `{s}`", .{ name, n.text });
        return .{ .reg = try target(f, dst), .type = .unknown, .temp = dst == null };
    };
    const arm = u.fields()[i];
    if (arm.type.kind != .void) {
        _ = try c.err(n.span, "`{s}.{s}` holds a {s}, which a name does not give", .{ name, n.text, @import("host.zig").nameOf(arm.type) });
        return .{ .reg = try target(f, dst), .type = .unknown, .temp = dst == null };
    }
    const tag = @import("../reflect.zig").tagType(c.vm, u) catch return error.OutOfMemory;
    const at = tag.index(try c.vm.intern(n.text)).?;
    return constant(f, dst, .enumValue(&tag.obj, at), want);
}

fn errorLiteral(f: *Func, n: ast.Name, message: ?*ast.Expr, dst: ?u8) Error!Operand {
    const c = f.comp;
    const name = try c.vm.intern(n.text);
    if (message) |m| {
        const out = try target(f, dst);
        const mark = f.free;
        const text = try compile(f, m, null, .string);
        const k = try f.constant(.fromObj(.string, &name.obj));
        try f.abc(.make_error, out, text.reg, 0);
        try f.emitWord(k);
        f.release(mark);
        return .{ .reg = out, .type = .@"error", .temp = dst == null };
    }
    const v = try make.errorValue(c.vm, name, null);
    return constant(f, dst, v, .@"error");
}

fn elementType(f: *Func, items: []const *ast.Expr, expected: Type) Error!Type {
    const c = f.comp;
    const want = c.pool.isOptional(expected) orelse expected;
    if (c.pool.listOf(want)) |e| return e;
    if (items.len == 0) return .any;
    return .unknown;
}

fn list(f: *Func, items: []const *ast.Expr, dst: ?u8, expected: Type) Error!Operand {
    const c = f.comp;
    var elem = try elementType(f, items, expected);
    const out = try target(f, dst);
    const mark = f.free;
    const new_at = f.here();
    try f.abc(.newlist, out, @intCast(@min(items.len, 255)), 0);
    try f.emitWord(0);
    var i: usize = 0;
    var inferred: ?Type = null;
    while (i < items.len) {
        const chunk = @min(items.len - i, 64);
        const first = f.free;
        for (items[i .. i + chunk]) |item| {
            const r = try f.alloc();
            if (elem == .unknown) {
                const v = try compile(f, item, r, .unknown);
                inferred = if (inferred) |t| (if (t == v.type) t else if (numberJoin(t, v.type)) |j| j else .any) else v.type;
            } else {
                _ = try typedInto(f, item, r, elem, "a list element");
            }
        }
        try f.abc(.append, out, first, @intCast(chunk));
        f.release(first);
        i += chunk;
    }
    if (elem == .unknown) elem = if (inferred) |t| (if (t == .null or t == .void) .any else t) else .any;
    const t = try c.pool.list(elem);
    const check = try c.pool.check(&c.vm.checks, c.vm.gpa, elem);
    f.code.items[new_at + 1] = @intFromEnum(check);
    f.release(mark);
    return .{ .reg = out, .type = t, .temp = dst == null };
}

fn numberJoin(a: Type, b: Type) ?Type {
    if ((a == .int and b == .float) or (a == .float and b == .int)) return .any;
    return null;
}

fn mapLiteral(f: *Func, entries: []const ast.MapEntry, dst: ?u8, expected: Type) Error!Operand {
    const c = f.comp;
    const want = c.pool.isOptional(expected) orelse expected;
    var key: Type = .any;
    var value: Type = .any;
    var fixed = false;
    if (c.pool.mapOf(want)) |kv| {
        key = kv.key;
        value = kv.value;
        fixed = true;
    } else if (entries.len > 0) {
        key = .unknown;
        value = .unknown;
    }
    const out = try target(f, dst);
    const mark = f.free;
    const new_at = f.here();
    try f.abc(.newmap, out, 0, 0);
    for (entries) |entry| {
        const k = if (fixed) try typed(f, entry.key, key, "a map key") else try compile(f, entry.key, null, .unknown);
        const v = if (fixed) try typed(f, entry.value, value, "a map value") else try compile(f, entry.value, null, .unknown);
        if (!fixed) {
            key = if (key == .unknown) k.type else if (key == k.type) key else .any;
            value = if (value == .unknown) v.type else if (value == v.type) value else .any;
        }
        try f.abc(.setindex, out, k.reg, v.reg);
        f.release(mark);
    }
    if (key == .unknown or key == .null) key = .any;
    if (value == .unknown or value == .null) value = .any;
    const kc = try c.pool.check(&c.vm.checks, c.vm.gpa, key);
    const vc = try c.pool.check(&c.vm.checks, c.vm.gpa, value);
    if (@intFromEnum(kc) > 255 or @intFromEnum(vc) > 255) {
        _ = try c.err(f.span, "too many distinct map types in this program", .{});
    }
    f.code.items[new_at] = @import("../vm/code.zig").Instr.abc(.newmap, out, @truncate(@intFromEnum(kc)), @truncate(@intFromEnum(vc))).word();
    return .{ .reg = out, .type = try c.pool.map(key, value), .temp = dst == null };
}

fn structLiteral(f: *Func, type_expr: *const ast.Expr, fields: []const ast.FieldInit, dst: ?u8) Error!Operand {
    const c = f.comp;
    const t = try names.typeValue(f, type_expr);
    const s = c.pool.structOf(t) orelse {
        if (t != .unknown) _ = try c.err(type_expr.span, "`{s}` is not a struct", .{c.typeName(t)});
        for (fields) |fi| _ = try compile(f, fi.value, null, .unknown);
        return .{ .reg = try target(f, dst), .type = .unknown, .temp = dst == null };
    };
    const out = try target(f, dst);
    const mark = f.free;
    try f.abx(.newinstance, out, try f.constant(.fromObj(.class, &s.class.obj)));
    const rec = c.recording();
    for (fields) |fi| {
        if (rec) |r| if (r.isPlaceholder(fi.name.text)) {
            try r.fields(s.self_type, fields);
            continue;
        };
        if (rec) |r| if (s.field(fi.name.text)) |fd| try r.member(c, fi.name.span, s.self_type, .{ .field = fd });
        const field = s.field(fi.name.text) orelse {
            const h = try c.err(fi.name.span, "`{s}` has no field `{s}`", .{ s.name, fi.name.text });
            var list_names: [64][]const u8 = undefined;
            var n: usize = 0;
            for (s.fields.items) |x| if (n < list_names.len) {
                list_names[n] = x.name;
                n += 1;
            };
            if (access.nearest(fi.name.text, list_names[0..n])) |near| _ = try h.help("did you mean `{s}`?", .{near});
            _ = try compile(f, fi.value, null, .unknown);
            f.release(mark);
            continue;
        };
        if (field.is_signal) {
            _ = try c.err(fi.name.span, "`{s}` is a signal, made with each instance; it cannot be set", .{fi.name.text});
            continue;
        }
        const v = try typed(f, fi.value, field.type, "the field");
        try f.abc(.setfield, out, @intCast(field.slot), v.reg);
        f.release(mark);
    }
    return .{ .reg = out, .type = s.self_type, .temp = dst == null };
}
