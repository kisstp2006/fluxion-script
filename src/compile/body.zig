// SPDX-License-Identifier: BSD-2-Clause

//! Function bodies: declared functions and methods, lambdas, the code that
//! gives a struct's fields their starting values, and tests.

const std = @import("std");

const ast = @import("../syntax/ast.zig");
const object = @import("../vm/object.zig");
const make = @import("../vm/make.zig");
const types = @import("types.zig");
const Type = types.Type;
const Func = @import("Func.zig");
const Compiler = @import("Compiler.zig");
const Error = Compiler.Error;
const expr = @import("expr.zig");
const Operand = expr.Operand;
const stmt = @import("stmt.zig");
const decl = @import("decl.zig");
const scan = @import("scan.zig");
const resolve = @import("resolve.zig");

fn concrete(t: Type) bool {
    return !(t == .any or t == .unknown);
}

/// Parameters as the first registers, their defaults filled in when the
/// caller gave fewer, then each typed one checked.
fn parameters(f: *Func, node: *const ast.Fn, sig: *const types.Signature) Error!void {
    const c = f.comp;
    f.params = @intCast(sig.params.len);
    f.required = @intCast(sig.required());
    f.has_self = sig.has_self;
    for (node.params, sig.params) |p, sp| {
        const r = try f.alloc();
        try f.declare(p.name.text, r, sp.type, true, p.name.span);
        f.locals.items[f.locals.items.len - 1].used = true;
        try f.param_types.append(c.gpa, if (p.is_self) .any else sp.type);
        try f.param_names.append(c.gpa, p.name.text);
    }
    try checkParams(f, node, sig, true);
    f.fast_entry = @intCast(f.here());
    for (node.params, sig.params, 0..) |p, sp, i| if (p.default) |d| {
        f.span = d.span;
        const skip = try f.jumpForward(.jargs, @intCast(i), 0);
        _ = try expr.typedInto(f, d, @intCast(i), sp.type, "the default");
        try f.patchHere(skip);
    };
    try checkParams(f, node, sig, false);
}

/// Typed parameters checked on entry: the required ones first, which a
/// call the compiler already checked jumps past, then the optional ones
/// once their defaults are in.
fn checkParams(f: *Func, node: *const ast.Fn, sig: *const types.Signature, required: bool) Error!void {
    const c = f.comp;
    for (node.params, sig.params, 0..) |p, sp, i| {
        if (p.is_self or !concrete(sp.type) or (p.default == null) != required) continue;
        f.span = p.name.span;
        const check = try c.pool.check(&c.vm.checks, c.vm.gpa, sp.type);
        if (check != .any) try f.abx(.check_param, @intCast(i), @intCast(@intFromEnum(check)));
    }
}

fn finishBody(f: *Func, node: *const ast.Fn) Error!void {
    const c = f.comp;
    switch (node.body) {
        .block => |b| {
            try stmt.block(f, b);
            f.span = .at(b.span.end -| 1);
        },
        .expr => |e| {
            const v = if (concrete(f.ret) and f.ret != .void) try expr.typed(f, e, f.ret, "the return value") else try expr.compile(f, e, null, .unknown);
            if (!concrete(f.ret)) f.ret = if (v.type == .never or v.type == .unknown) .any else v.type;
            if (f.reachable) {
                if (v.type == .void or f.ret == .void) try f.abc(.retnull, 0, 0, 0) else try f.abc(.ret, v.reg, 0, 0);
            }
            f.reachable = false;
        },
    }
    if (f.reachable) {
        const needs = !(f.ret == .void or Compiler.dynamic(f.ret) or c.pool.nullable(f.ret) or f.ret == .never or c.pool.isErrorUnion(f.ret) == .void);
        if (needs) {
            const name = if (node.name) |n| n.text else "this lambda";
            _ = try (try c.err(f.span, "`{s}` must return {s}, but can reach its end without returning", .{ name, c.typeName(f.ret) }))
                .help("return a value on every path, or make the return type `?{s}`", .{c.typeName(f.ret)});
        }
        try control().runDefers(f, 0, false);
        try f.abc(.retnull, 0, 0, 0);
    }
}

fn control() type {
    return @import("control.zig");
}

pub fn function(c: *Compiler, fd: decl.FnDecl) Error!void {
    var f: Func = .init(c, null, fd.node.name.?.text);
    defer f.deinit();
    f.span = fd.node.span;
    f.ret = fd.sig.ret;
    f.coroutine = fd.sig.coroutine;
    switch (fd.owner) {
        .none => {},
        .@"struct" => |s| {
            f.class = s.class;
            f.self_type = s.self_type;
        },
        .@"enum" => |e| f.self_type = e.self_type,
    }
    try parameters(&f, fd.node, fd.sig);
    try finishBody(&f, fd.node);
    try f.finish(fd.proto);
}

pub fn lambda(f: *Func, node: *const ast.Fn, dst: ?u8, expected: Type) Error!Operand {
    const c = f.comp;
    const want = c.pool.signatureOf(expected);
    const a = c.pool.allocator();
    const params = try a.alloc(types.Param, node.params.len);
    for (node.params, params, 0..) |p, *out, i| {
        const t: Type = if (p.type) |te| try resolve.typeExpr(c, te) else if (want != null and i < want.?.params.len) want.?.params[i].type else .any;
        out.* = .{ .name = p.name.text, .type = t, .has_default = p.default != null };
    }
    const ret: Type = if (node.ret) |r| try resolve.typeExpr(c, r) else switch (node.body) {
        .block => |b| if (want) |w| (if (concrete(w.ret)) w.ret else if (scan.returnsValue(b)) Type.any else .void) else if (scan.returnsValue(b)) .any else .void,
        .expr => if (want) |w| (if (concrete(w.ret) and w.ret != .void) w.ret else Type.unknown) else .unknown,
    };
    const sig = try a.create(types.Signature);
    sig.* = .{ .params = params, .ret = ret, .coroutine = scan.fnAwaits(node) };

    var child: Func = .init(c, f, if (node.name) |n| n.text else "<lambda>");
    defer child.deinit();
    child.span = node.span;
    child.ret = ret;
    child.coroutine = sig.coroutine;
    child.class = f.class;
    child.self_type = f.self_type;
    try parameters(&child, node, sig);
    try finishBody(&child, node);
    sig.ret = if (child.ret == .unknown) .any else child.ret;
    const proto = try make.proto(c.vm, try c.vm.intern(if (node.name) |n| n.text else "<lambda>"));
    proto.decl = node.span;
    try child.finish(proto);

    if (f.protos.items.len >= std.math.maxInt(u16)) {
        _ = try c.err(node.span, "too many lambdas in one function", .{});
        return error.CompileFailed;
    }
    try f.protos.append(c.gpa, proto);
    const out = try expr.target(f, dst);
    try f.abx(.closure, out, @intCast(f.protos.items.len - 1));
    return .{ .reg = out, .type = try c.pool.function(sig), .temp = dst == null };
}

/// The starting values a struct's fields cannot share: a list, a map, or
/// anything computed, made again for every instance.
pub fn defaults(c: *Compiler, s: decl.StructDecl) Error!void {
    const info = s.info;
    const inherited = if (info.parent) |p| p.fields.items.len else 0;
    var f: Func = .init(c, null, "<defaults>");
    defer f.deinit();
    f.has_self = true;
    f.params = 1;
    f.required = 1;
    f.class = info.class;
    f.self_type = info.self_type;
    const self = try f.alloc();
    try f.declare("self", self, info.self_type, true, s.node.name.span);
    try f.param_types.append(c.gpa, .any);
    try f.param_names.append(c.gpa, "self");
    var any = false;
    for (s.node.fields) |node| {
        const field = info.field(node.name.text) orelse continue;
        if (field.slot < inherited) continue;
        const mark = f.free;
        defer f.release(mark);
        if (node.value) |v| {
            if (decl.literal(c, v) != null or v.kind == .null) continue;
            f.span = v.span;
            const r = try expr.typed(&f, v, field.type, "the field's default");
            try f.abc(.setfield, self, @intCast(field.slot), r.reg);
            any = true;
        } else if (c.pool.listOf(field.type) != null or c.pool.mapOf(field.type) != null) {
            f.span = node.name.span;
            const r = try f.alloc();
            if (c.pool.listOf(field.type)) |elem| {
                try f.abc(.newlist, r, 0, 0);
                try f.emitWord(@intFromEnum(try c.pool.check(&c.vm.checks, c.vm.gpa, elem)));
            } else {
                const kv = c.pool.mapOf(field.type).?;
                const k = try c.pool.check(&c.vm.checks, c.vm.gpa, kv.key);
                const v = try c.pool.check(&c.vm.checks, c.vm.gpa, kv.value);
                try f.abc(.newmap, r, @truncate(@intFromEnum(k)), @truncate(@intFromEnum(v)));
            }
            try f.abc(.setfield, self, @intCast(field.slot), r);
            any = true;
        } else if (c.pool.structOf(field.type) != null or c.pool.signatureOf(field.type) != null) {
            _ = try (try c.err(node.name.span, "field `{s}` of type {s} needs a default value", .{ node.name.text, c.typeName(field.type) }))
                .help("give it one, or make it `?{s}` so it can start as null", .{c.typeName(field.type)});
        }
    }
    if (!any) return;
    try f.abc(.retnull, 0, 0, 0);
    const proto = try make.proto(c.vm, try c.vm.intern("<defaults>"));
    try f.finish(proto);
    info.class.defaults = try make.closure(c.vm, proto);
}

pub fn testBlock(c: *Compiler, t: *const ast.Test) Error!void {
    var f: Func = .init(c, null, t.name);
    defer f.deinit();
    f.span = t.span;
    f.ret = .void;
    try stmt.block(&f, t.body);
    if (f.reachable) {
        try control().runDefers(&f, 0, false);
        try f.abc(.retnull, 0, 0, 0);
    }
    const proto = try make.proto(c.vm, try c.vm.intern(t.name));
    proto.decl = t.span;
    try f.finish(proto);
    const closure = try make.closure(c.vm, proto);
    try c.module.tests.append(c.vm.gpa, .{ .name = try c.vm.intern(t.name), .function = closure });
}

test {
    _ = object;
}
