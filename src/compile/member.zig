// SPDX-License-Identifier: BSD-2-Clause

//! `a.b`, `a[i]` and `a[i..j]`, read and assigned. A field of a struct the
//! compiler knows is a slot number; anything else is found by name at run
//! time, through a cache.

const std = @import("std");

const diag = @import("../diag.zig");
const ast = @import("../syntax/ast.zig");
const code = @import("../vm/code.zig");
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
const binary = @import("binary.zig");
const names = @import("names.zig");
const host = @import("host.zig");

pub fn component(name: []const u8) ?u8 {
    if (name.len != 1) return null;
    return switch (name[0]) {
        'x' => 0,
        'y' => 1,
        'z' => 2,
        else => null,
    };
}

fn nameList(s: *const types.Struct, buffer: [][]const u8) [][]const u8 {
    var n: usize = 0;
    for (s.fields.items) |f| if (n < buffer.len) {
        buffer[n] = f.name;
        n += 1;
    };
    var at: ?*const types.Struct = s;
    while (at) |x| : (at = x.parent) for (x.methods.keys()) |k| if (n < buffer.len) {
        buffer[n] = k;
        n += 1;
    };
    return buffer[0..n];
}

pub fn noMember(f: *Func, s: *const types.Struct, name: ast.Name) Error!void {
    var buffer: [128][]const u8 = undefined;
    const h = try f.comp.err(name.span, "`{s}` has no field or method `{s}`", .{ s.name, name.text });
    if (access.nearest(name.text, nameList(s, &buffer))) |near| _ = try h.help("did you mean `{s}`?", .{near});
}

/// A dynamic lookup of `name` on R[target], through a cache of its own.
pub fn getProp(f: *Func, out: u8, target: u8, name: []const u8) Error!void {
    const k = try f.nameConstant(name);
    try f.abc(.getprop, out, target, 0);
    try f.emitWord(@bitCast(code.Extra{ .name = k, .cache = try f.cache() }));
}

pub fn setProp(f: *Func, target: u8, name: []const u8, value: u8) Error!void {
    const k = try f.nameConstant(name);
    try f.abc(.setprop, target, value, 0);
    try f.emitWord(@bitCast(code.Extra{ .name = k, .cache = try f.cache() }));
}

/// A name looked up on a type or a module rather than on a value.
fn staticMember(f: *Func, e: *const ast.Expr, dst: ?u8) Error!?Operand {
    const fl = e.kind.field;
    const c = f.comp;
    if (fl.target.kind != .ident) return null;
    if (f.findLocal(fl.target.kind.ident) != null) return null;
    const g = c.global(fl.target.kind.ident) orelse return null;
    const name = fl.name.text;
    const rec = c.recording();
    if (rec) |r| switch (g.kind) {
        .import, .@"struct", .@"enum" => {
            try r.global(c, fl.target.span, g.*);
            if (r.isPlaceholder(name)) {
                r.statics(g.type);
                return .{ .reg = try expr.target(f, dst), .type = .unknown, .temp = dst == null };
            }
        },
        else => {},
    };
    switch (g.kind) {
        .import => {
            const m = c.pool.moduleOf(g.type) orelse return null;
            if (rec) |r| if (m.exports.get(name)) |ex| try r.exported(fl.name.span, g.type, m, name, ex);
            const ex = m.exports.get(name) orelse {
                var buffer: [128][]const u8 = undefined;
                var n: usize = 0;
                for (m.exports.keys()) |key| if (n < buffer.len) {
                    buffer[n] = key;
                    n += 1;
                };
                const h = try c.err(fl.name.span, "module `{s}` has no `{s}`", .{ m.name, name });
                if (access.nearest(name, buffer[0..n])) |near| _ = try h.help("did you mean `{s}`?", .{near});
                return .{ .reg = try expr.target(f, dst), .type = .unknown, .temp = dst == null };
            };
            if (ex.is_const) if (ex.value) |v| if (v.tag != .undefined) return try expr.constant(f, dst, v, ex.type);
            const out = try expr.target(f, dst);
            const mark = f.free;
            const mod = try expr.constant(f, null, g.value.?, g.type);
            try getProp(f, out, mod.reg, name);
            f.release(@max(mark, out + 1));
            return .{ .reg = out, .type = ex.type, .temp = dst == null };
        },
        .@"struct" => {
            const s = c.pool.structOf(c.pool.metaOf(g.type).?).?;
            if (rec) |r| {
                try r.structConstant(fl.name.span, s, name);
                if (s.method(name)) |m| try r.member(c, fl.name.span, s.self_type, .{ .method = m });
            }
            if (s.constant(name)) |k| if (k.value) |v| return try expr.constant(f, dst, v, k.type);
            if (s.method(name)) |m| {
                const out = try expr.target(f, dst);
                const cls = try expr.constant(f, null, g.value.?, g.type);
                try getProp(f, out, cls.reg, name);
                f.release(@max(cls.reg, out + 1));
                return .{ .reg = out, .type = try c.pool.function(m.sig), .temp = dst == null };
            }
            try noMember(f, s, fl.name);
            return .{ .reg = try expr.target(f, dst), .type = .unknown, .temp = dst == null };
        },
        .@"enum" => {
            const en = c.pool.enumOf(c.pool.metaOf(g.type).?).?;
            if (rec) |r| {
                if (en.index(name)) |i| try r.enumMember(fl.name.span, en, i);
                if (en.methods.getPtr(name)) |m| try r.member(c, fl.name.span, en.self_type, .{ .method = m });
            }
            if (en.index(name)) |i| return try expr.constant(f, dst, .enumValue(&en.type_obj.obj, i), en.self_type);
            if (en.methods.get(name)) |m| {
                const out = try expr.target(f, dst);
                const t = try expr.constant(f, null, g.value.?, g.type);
                try getProp(f, out, t.reg, name);
                f.release(@max(t.reg, out + 1));
                return .{ .reg = out, .type = try c.pool.function(m.sig), .temp = dst == null };
            }
            const h = try c.err(fl.name.span, "`{s}` has no member `{s}`", .{ en.name, name });
            if (access.nearest(name, en.members)) |near| _ = try h.help("did you mean `{s}`?", .{near});
            return .{ .reg = try expr.target(f, dst), .type = .unknown, .temp = dst == null };
        },
        else => return null,
    }
}

pub fn field(f: *Func, e: *const ast.Expr, dst: ?u8) Error!Operand {
    if (try staticMember(f, e, dst)) |op| return op;
    const fl = e.kind.field;
    const c = f.comp;
    const pool = c.pool;
    const name = fl.name.text;
    const mark = f.free;
    const t = try expr.compile(f, fl.target, null, .unknown);
    const rec = c.recording();
    if (rec) |r| if (r.isPlaceholder(name)) {
        if (t.host) |h| r.hostMembers(h.type) else r.members(t.type);
        return .{ .reg = try binary.result(f, dst, mark), .type = .unknown, .temp = dst == null };
    };
    if (t.host) |h| if (Compiler.dynamic(t.type)) return hostMember(f, t, h, fl.name, dst, mark);
    if (pool.structOf(t.type)) |s| {
        if (s.field(name)) |fd| {
            if (rec) |r| try r.member(c, fl.name.span, s.self_type, .{ .field = fd });
            const out = try binary.result(f, dst, mark);
            try f.abc(.getfield, out, t.reg, @intCast(fd.slot));
            return .{ .reg = out, .type = fd.type, .temp = dst == null, .host = if (fd.host_type) |ht| .{ .type = ht } else null };
        }
        if (s.method(name)) |m| {
            if (rec) |r| try r.member(c, fl.name.span, s.self_type, .{ .method = m });
            const out = try binary.result(f, dst, mark);
            try getProp(f, out, t.reg, name);
            return .{ .reg = out, .type = try pool.function(m.sig), .temp = dst == null };
        }
        try noMember(f, s, fl.name);
        return .{ .reg = try binary.result(f, dst, mark), .type = .unknown, .temp = dst == null };
    }
    switch (t.type) {
        .vec2, .vec3 => if (component(name)) |comp| {
            if (comp < 2 or t.type == .vec3) {
                if (rec) |r| try r.use(.{ .span = fl.name.span, .kind = .property, .type = .float, .owner = t.type, .mutable = true });
                const out = try binary.result(f, dst, mark);
                try f.abc(.getcomp, out, t.reg, comp);
                return .{ .reg = out, .type = .float, .temp = dst == null };
            }
        },
        .string => if (std.mem.eql(u8, name, "len")) {
            if (rec) |r| try r.use(.{ .span = fl.name.span, .kind = .property, .type = .int, .owner = t.type });
            const out = try binary.result(f, dst, mark);
            try f.abc(.len, out, t.reg, 0);
            return .{ .reg = out, .type = .int, .temp = dst == null };
        },
        else => {},
    }
    if ((pool.listOf(t.type) != null or pool.mapOf(t.type) != null) and std.mem.eql(u8, name, "len")) {
        if (rec) |r| try r.use(.{ .span = fl.name.span, .kind = .property, .type = .int, .owner = t.type });
        const out = try binary.result(f, dst, mark);
        try f.abc(.len, out, t.reg, 0);
        return .{ .reg = out, .type = .int, .temp = dst == null };
    }
    if (pool.isOptional(t.type)) |child| {
        _ = try (try (try c.err(fl.name.span, "cannot read `{s}` of a value that may be null", .{name}))
            .label(c.at(fl.target.span), "this is {s}", .{c.typeName(t.type)}))
            .help("unwrap it first: `x.?.{s}`, `if (x) |v| v.{s}`, or `(x orelse fallback).{s}`", .{ name, name, name });
        _ = child;
        return .{ .reg = try binary.result(f, dst, mark), .type = .unknown, .temp = dst == null };
    }
    const known: ?Type = switch (t.type) {
        .@"error" => if (std.mem.eql(u8, name, "name")) .string else if (std.mem.eql(u8, name, "message")) try pool.optional(.string) else null,
        .color => if (name.len == 1 and std.mem.indexOfScalar(u8, "rgba", name[0]) != null) .float else null,
        else => null,
    };
    const out = try binary.result(f, dst, mark);
    if (!Compiler.dynamic(t.type) and known == null and !builtinHasMethod(c, t.type, name)) {
        _ = try c.err(fl.name.span, "{s} has no field `{s}`", .{ c.typeName(t.type), name });
        return .{ .reg = out, .type = .unknown, .temp = dst == null };
    }
    if (rec) |r| if (!Compiler.dynamic(t.type)) {
        try r.use(.{ .span = fl.name.span, .kind = if (known != null) .property else .builtin_method, .type = known orelse .any, .owner = t.type });
    };
    try getProp(f, out, t.reg, name);
    return .{ .reg = out, .type = known orelse .any, .temp = dst == null };
}

/// A member of a value the host gives, read by name as any value's is: of
/// the type its host type says, where that lists it - a field - and `any`
/// otherwise, which the host may still have.
fn hostMember(f: *Func, t: Operand, h: host.Host, name: ast.Name, dst: ?u8, mark: u8) Error!Operand {
    const c = f.comp;
    const out = try binary.result(f, dst, mark);
    try getProp(f, out, t.reg, name.text);
    if (host.field(h.type, name.text)) |fd| {
        const seen = host.seen(c.vm, fd.type);
        if (c.recording()) |r| try r.use(.{ .span = name.span, .kind = .field, .type = seen.type, .doc = host.docOf(fd), .detail = try host.fieldDetail(c.vm, r.arena(), fd, h.type), .mutable = true });
        return .{ .reg = out, .type = seen.type, .temp = dst == null, .host = if (seen.host) |ht| .{ .type = ht, .sure = h.sure } else null };
    }
    if (host.method(h.type, name.text)) |m| if (c.recording()) |r| {
        try r.use(.{ .span = name.span, .kind = .method, .type = .any, .doc = host.docOf(m), .detail = try host.methodDetail(c.vm, r.arena(), m, h.type) });
    };
    return .{ .reg = out, .type = .any, .temp = dst == null };
}

fn builtinHasMethod(c: *Compiler, t: Type, name: []const u8) bool {
    const kind: @import("../vm/Vm.zig").BuiltinType = switch (t) {
        .string => .string,
        .vec2 => .vec2,
        .vec3 => .vec3,
        .color => .color,
        .signal => .signal,
        .task => .task,
        .int => .int,
        .float => .float,
        else => if (c.pool.listOf(t) != null) .list else if (c.pool.mapOf(t) != null) .map else return false,
    };
    const key = c.vm.interned.find(name, @import("../vm/strings.zig").hashBytes(name)) orelse return false;
    return c.vm.methods.getPtrConst(kind).contains(key);
}

pub fn index(f: *Func, e: *const ast.Expr, dst: ?u8) Error!Operand {
    const x = e.kind.index;
    const c = f.comp;
    const pool = c.pool;
    const mark = f.free;
    const t = try expr.compile(f, x.target, null, .unknown);
    if (pool.listOf(t.type)) |elem| {
        const i = try expr.typed(f, x.index, .int, "a list index");
        const out = try binary.result(f, dst, mark);
        try f.abc(if (i.type == .int) .getlist else .getindex, out, t.reg, i.reg);
        return .{ .reg = out, .type = elem, .temp = dst == null };
    }
    if (pool.mapOf(t.type)) |kv| {
        const k = try expr.typed(f, x.index, kv.key, "the map's key");
        const out = try binary.result(f, dst, mark);
        try f.abc(.getindex, out, t.reg, k.reg);
        return .{ .reg = out, .type = kv.value, .temp = dst == null };
    }
    if (t.type == .string) {
        const i = try expr.typed(f, x.index, .int, "a string index");
        const out = try binary.result(f, dst, mark);
        try f.abc(.getindex, out, t.reg, i.reg);
        return .{ .reg = out, .type = .string, .temp = dst == null };
    }
    const i = try expr.compile(f, x.index, null, .unknown);
    if (!Compiler.dynamic(t.type)) {
        const h = try c.err(x.target.span, "cannot index {s}", .{c.typeName(t.type)});
        if (pool.isOptional(t.type) != null) _ = try h.help("it may be null: unwrap it first", .{});
    }
    const out = try binary.result(f, dst, mark);
    try f.abc(.getindex, out, t.reg, i.reg);
    return .{ .reg = out, .type = .any, .temp = dst == null };
}

pub fn slice(f: *Func, e: *const ast.Expr, dst: ?u8) Error!Operand {
    const x = e.kind.slice;
    const c = f.comp;
    const mark = f.free;
    const t = try expr.compile(f, x.target, null, .unknown);
    if (!(t.type == .string or c.pool.listOf(t.type) != null or Compiler.dynamic(t.type))) {
        _ = try c.err(x.target.span, "cannot slice {s}", .{c.typeName(t.type)});
    }
    const bounds = try f.allocN(2);
    if (x.start) |s| _ = try expr.typedInto(f, s, bounds, .int, "a slice bound") else _ = try expr.constant(f, bounds, .int(0), .int);
    if (x.end) |s| _ = try expr.typedInto(f, s, bounds + 1, .int, "a slice bound") else _ = try expr.constant(f, bounds + 1, .null, .null);
    const out = try binary.result(f, dst, mark);
    try f.abc(.slice, out, t.reg, bounds);
    return .{ .reg = out, .type = if (Compiler.dynamic(t.type)) .any else t.type, .temp = dst == null };
}

/// `target.name = value` (or `op=`). A vector is a value: its component is
/// changed in a register and the vector written back where it came from.
pub fn assignField(f: *Func, target: *const ast.Expr, value: *const ast.Expr, op: ?ast.BinaryOp) Error!void {
    const fl = target.kind.field;
    const c = f.comp;
    const name = fl.name.text;
    const mark = f.free;
    defer f.release(mark);
    if (fl.target.kind == .ident) if (c.global(fl.target.kind.ident)) |g| {
        if (f.findLocal(fl.target.kind.ident) == null and (g.kind == .import or g.kind == .@"struct" or g.kind == .@"enum")) {
            _ = try c.err(target.span, "`{s}.{s}` cannot be assigned to", .{ fl.target.kind.ident, name });
            return;
        }
    };
    const obj = try expr.compile(f, fl.target, null, .unknown);
    const rec = c.recording();
    if (rec) |r| if (r.isPlaceholder(name)) return r.members(obj.type);
    if (c.pool.structOf(obj.type)) |s| {
        const fd = s.field(name) orelse return noMember(f, s, fl.name);
        if (rec) |r| try r.member(c, fl.name.span, s.self_type, .{ .field = fd });
        if (fd.is_signal or fd.is_const) {
            _ = try c.err(fl.name.span, "`{s}.{s}` cannot be assigned to", .{ s.name, name });
            return;
        }
        const v = try operand(f, value, op, fd.type, target, obj.reg, .{ .slot = fd.slot });
        try f.abc(.setfield, obj.reg, @intCast(fd.slot), v.reg);
        return;
    }
    if ((obj.type == .vec2 or obj.type == .vec3) and component(name) != null) {
        const comp = component(name).?;
        if (comp == 2 and obj.type == .vec2) {
            _ = try c.err(fl.name.span, "vec2 has no field `z`", .{});
            return;
        }
        if (rec) |r| try r.use(.{ .span = fl.name.span, .kind = .property, .type = .float, .owner = obj.type, .mutable = true });
        const in_place = !obj.temp;
        const v = try operand(f, value, op, .float, target, obj.reg, .{ .comp = comp });
        const x = try binary.coerce(f, v, .float, value.span, "a vector's component");
        try f.abc(.setcomp, obj.reg, comp, x.reg);
        if (!in_place) try writeBack(f, fl.target, obj.reg);
        return;
    }
    if (!Compiler.dynamic(obj.type)) {
        _ = try c.err(fl.name.span, "{s} has no field `{s}` that can be set", .{ c.typeName(obj.type), name });
        return;
    }
    const v = try operand(f, value, op, .any, target, obj.reg, .{ .name = name });
    try setProp(f, obj.reg, name, v.reg);
    if (fl.target.kind != .self and fl.target.kind != .ident) try writeBack(f, fl.target, obj.reg);
}

const Read = union(enum) { slot: u32, comp: u8, name: []const u8 };

/// The value to store: `value` itself, or for `op=` the old value and
/// `value` put together.
fn operand(f: *Func, value: *const ast.Expr, op: ?ast.BinaryOp, want: Type, target: *const ast.Expr, obj: u8, read: Read) Error!Operand {
    const o = op orelse return expr.typed(f, value, want, "the field");
    const old = try f.alloc();
    switch (read) {
        .slot => |s| try f.abc(.getfield, old, obj, @intCast(s)),
        .comp => |cmp| try f.abc(.getcomp, old, obj, cmp),
        .name => |n| try getProp(f, old, obj, n),
    }
    const combined = try @import("stmt.zig").combine(f, o, .{ .reg = old, .type = want, .temp = true }, value, target.span);
    return binary.coerce(f, combined, want, value.span, "the field");
}

/// Stores R[reg] back into the place `place` names, after a change to a
/// vector that was copied out of it.
fn writeBack(f: *Func, place: *const ast.Expr, reg: u8) Error!void {
    switch (place.kind) {
        .ident => |name| try @import("stmt.zig").storeName(f, name, place.span, reg, .any),
        .field => |pf| {
            const obj = try expr.compile(f, pf.target, null, .unknown);
            if (f.comp.pool.structOf(obj.type)) |s| {
                if (s.field(pf.name.text)) |fd| return f.abc(.setfield, obj.reg, @intCast(fd.slot), reg);
            }
            try setProp(f, obj.reg, pf.name.text, reg);
        },
        .index => |ix| {
            const obj = try expr.compile(f, ix.target, null, .unknown);
            const i = try expr.compile(f, ix.index, null, .unknown);
            try f.abc(.setindex, obj.reg, i.reg, reg);
        },
        else => {},
    }
}

pub fn assignIndex(f: *Func, target: *const ast.Expr, value: *const ast.Expr, op: ?ast.BinaryOp) Error!void {
    const x = target.kind.index;
    const c = f.comp;
    const pool = c.pool;
    const mark = f.free;
    defer f.release(mark);
    const obj = try expr.compile(f, x.target, null, .unknown);
    var elem: Type = .any;
    var key_type: Type = .any;
    if (pool.listOf(obj.type)) |e| {
        elem = e;
        key_type = .int;
    } else if (pool.mapOf(obj.type)) |kv| {
        elem = kv.value;
        key_type = kv.key;
    } else if (obj.type == .string) {
        _ = try c.err(target.span, "strings cannot be changed; build a new one", .{});
        return;
    } else if (!Compiler.dynamic(obj.type)) {
        _ = try c.err(x.target.span, "cannot index {s}", .{c.typeName(obj.type)});
        return;
    }
    const k = try expr.typed(f, x.index, key_type, "the index");
    const v = if (op) |o| blk: {
        const old = try f.alloc();
        try f.abc(.getindex, old, obj.reg, k.reg);
        const combined = try @import("stmt.zig").combine(f, o, .{ .reg = old, .type = elem, .temp = true }, value, target.span);
        break :blk try binary.coerce(f, combined, elem, value.span, "the element");
    } else try expr.typed(f, value, elem, "the element");
    const typed_list = pool.listOf(obj.type) != null and k.type == .int and elem != .any and v.type != .any;
    try f.abc(if (typed_list) .setlist else .setindex, obj.reg, k.reg, v.reg);
}

test {
    _ = diag;
    _ = Value;
    _ = object;
    _ = names;
}
