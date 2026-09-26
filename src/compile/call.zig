// SPDX-License-Identifier: BSD-2-Clause

//! Calls: the callee and its arguments in a row of registers, checked
//! against the signature when the callee is known.

const std = @import("std");

const ast = @import("../syntax/ast.zig");
const code = @import("../vm/code.zig");
const object = @import("../vm/object.zig");
const types = @import("types.zig");
const Type = types.Type;
const Func = @import("Func.zig");
const Compiler = @import("Compiler.zig");
const Error = Compiler.Error;
const expr = @import("expr.zig");
const control = @import("control.zig");
const Operand = expr.Operand;
const names = @import("names.zig");
const member = @import("member.zig");
const builtins = @import("builtins.zig");
const host = @import("host.zig");
const reflect = @import("fluxion_reflect");

const Known = union(enum) {
    signature: *const types.Signature,
    method: struct { receiver: Type, name: []const u8 },
    prelude: struct { name: []const u8, native: *object.Native },
    math: []const u8,
    /// A method of a value of one of the host's types: see `host.zig`.
    host: HostCall,
    dynamic,
};

const HostCall = struct {
    sig: *const types.Signature,
    found: host.Method,
};

pub fn call(f: *Func, e: *const ast.Expr, dst: ?u8) Error!Operand {
    const cl = e.kind.call;
    const c = f.comp;
    const awaited = f.awaiting;
    f.awaiting = false;
    const mark = f.free;
    const reuse = if (dst) |d| d + 1 == f.free and !isLocal(f, d) else false;
    const base = if (reuse) dst.? else try f.alloc();
    var known: Known = .dynamic;
    var method_call = false;
    var self_given = false;
    // The callee is certainly the declaration whose signature was checked,
    // so its parameter checks can be skipped.
    var direct = false;

    if (cl.callee.kind == .field and !isStatic(f, cl.callee)) {
        const fl = cl.callee.kind.field;
        const obj = try control.unlessError(f, try expr.compile(f, fl.target, null, .unknown), fl.target.span);
        const name = fl.name.text;
        const rec = c.recording();
        if (rec) |r| if (r.isPlaceholder(name)) {
            r.members(obj.type);
            method_call = true;
        };
        if (method_call) {
            // The placeholder: a call on it is not checked.
        } else if (c.pool.hostOf(obj.type)) |ht| {
            method_call = true;
            if (host.member(c.vm, ht, name)) |found| switch (found) {
                .method => |m| {
                    const sig = try host.signature(c.vm, c.pool.allocator(), m);
                    if (rec) |r| try member.useHost(c, r, fl.name.span, ht, found, .any);
                    known = .{ .host = .{ .sig = sig, .found = m } };
                },
                .field, .declared => {
                    if (rec) |r| try member.useHost(c, r, fl.name.span, ht, found, try host.memberType(c.vm, found));
                    if (found == .declared and found.declared.type == .signal) {
                        _ = try c.err(fl.name.span, "a signal is not called; emit it: `{s}.emit(...)`", .{name});
                    } else {
                        _ = try c.err(fl.name.span, "`{s}.{s}` is not a method", .{ host.nameOf(ht), name });
                    }
                },
            } else if (!host.open(c.vm, ht)) try member.noHostMember(f, ht, fl.name);
        } else if (c.pool.structOf(obj.type)) |s| {
            if (s.method(name)) |m| {
                if (rec) |r| try r.member(c, fl.name.span, s.self_type, .{ .method = m });
                if (m.sig.has_self) {
                    method_call = true;
                    self_given = true;
                    direct = true;
                    known = .{ .signature = m.sig };
                } else {
                    _ = try (try c.err(fl.name.span, "`{s}.{s}` takes no `self`; call it on the type: `{s}.{s}(...)`", .{ s.name, name, s.name, name }))
                        .text("called on an instance", .{});
                }
            } else if (s.field(name)) |fd| {
                if (rec) |r| try r.member(c, fl.name.span, s.self_type, .{ .field = fd });
                if (c.pool.signatureOf(fd.type)) |sg| known = .{ .signature = sg };
                if (fd.type == .signal) _ = try c.err(fl.name.span, "a signal is not called; emit it: `{s}.emit(...)`", .{name});
                try f.abc(.getfield, base, obj.reg, @intCast(fd.slot));
            } else {
                try member.noMember(f, s, fl.name);
            }
        } else if (c.pool.enumOf(obj.type)) |en| {
            if (en.methods.getPtr(name)) |m| {
                if (rec) |r| try r.member(c, fl.name.span, en.self_type, .{ .method = m });
                method_call = true;
                self_given = m.sig.has_self;
                direct = true;
                known = .{ .signature = m.sig };
                if (!m.sig.has_self) _ = try c.err(fl.name.span, "`{s}.{s}` takes no `self`; call it on the type", .{ en.name, name });
            } else {
                _ = try c.err(fl.name.span, "`{s}` has no method `{s}`", .{ en.name, name });
            }
        } else if (c.pool.isOptional(obj.type) != null) {
            _ = try (try c.err(fl.name.span, "cannot call `{s}` on a value that may be null", .{name}))
                .help("unwrap it first: `x.?.{s}(...)` or `if (x) |v| v.{s}(...)`", .{ name, name });
        } else if (!Compiler.dynamic(obj.type)) {
            if (try builtins.method(c, obj.type, name, &.{}) != null) {
                known = .{ .method = .{ .receiver = obj.type, .name = name } };
                if (rec) |r| try r.use(.{ .span = fl.name.span, .kind = .builtin_method, .type = .any, .owner = obj.type });
            } else {
                const h = try c.err(fl.name.span, "{s} has no method `{s}`", .{ c.typeName(obj.type), name });
                if (obj.type == .signal) _ = try h.help("a signal has connect, once, disconnect, emit, is_connected and connections", .{});
            }
            method_call = true;
        } else {
            method_call = true;
        }
        if (method_call) {
            const k = try f.nameConstant(name);
            try f.abc(.getmethod, base, obj.reg, 0);
            try f.emitWord(@bitCast(code.Extra{ .name = k, .cache = try f.cache() }));
        }
    } else {
        known = try calleeInto(f, cl.callee, base, &direct);
    }
    if (c.recording()) |r| try r.call(cl.callee, switch (known) {
        .signature => |sg| sg,
        .host => |h| h.sig,
        else => null,
    }, self_given);
    f.setFree(base + 1 + @as(u8, @intFromBool(method_call)));

    const ret = try arguments(f, e, known, self_given, awaited);
    f.span = e.span;
    const nargs: usize = cl.args.len + @intFromBool(method_call);
    if (nargs > 250) {
        _ = try c.err(e.span, "too many arguments", .{});
        return .{ .reg = base, .type = .unknown, .temp = true };
    }
    f.reserve(base, @intCast(nargs + 2));
    const checked = direct and known == .signature and !awaited;
    const flags: u8 = @as(u8, @intFromBool(awaited)) | (@as(u8, @intFromBool(method_call)) << 1) | (@as(u8, @intFromBool(checked)) << 2);
    try f.abc(.call, base, @intCast(nargs), flags);
    // A function value may be any function its type allows: what it gives
    // back is checked, as the declaration's own result need not be.
    if (!direct and known == .signature and ret != .void and ret != .never and !Compiler.dynamic(ret)) {
        const check = try c.pool.check(&c.vm.checks, c.vm.gpa, ret);
        if (check != .any) try f.abx(.check, base, @intCast(@intFromEnum(check)));
    }
    if (ret == .never) f.reachable = false;
    f.release(base + 1);
    if (dst) |d| {
        if (d != base) try f.abc(.move, d, base, 0);
        f.release(if (reuse) d + 1 else mark);
        return .{ .reg = d, .type = ret, .temp = false };
    }
    return .{ .reg = base, .type = ret, .temp = true };
}

/// A type named as an argument of a host's method: the host's type it
/// stands for, when it is one.
fn typeArgument(f: *Func, a: *const ast.Expr, given: Operand, p: types.Param) Error!?Type {
    const c = f.comp;
    if (Compiler.dynamic(given.type)) return null;
    if (c.pool.metaOf(given.type)) |t| if (c.pool.hostOf(t) != null) return t;
    _ = try (try c.err(a.span, "`{s}` is a type, and is given {s}", .{ p.name, c.typeName(given.type) }))
        .help("name one of the host's types, as `Sprite`", .{});
    return null;
}

fn isLocal(f: *Func, r: u8) bool {
    for (f.locals.items) |l| if (l.reg == r) return true;
    return false;
}

/// Each argument in the next register, as the callee wants it; and what
/// the call gives back.
fn arguments(f: *Func, e: *const ast.Expr, known: Known, self_given: bool, awaited: bool) Error!Type {
    const c = f.comp;
    const args = e.kind.call.args;
    switch (known) {
        .signature => |sg| {
            const params = if (self_given and sg.has_self) sg.params[1..] else sg.params;
            if (args.len < requiredOf(params) or args.len > params.len) try arity(f, e, requiredOf(params), params.len, args.len);
            for (args, 0..) |a, i| {
                const r = try f.alloc();
                const want: Type = if (i < params.len) params[i].type else .unknown;
                _ = try expr.typedInto(f, a, r, want, "the argument");
            }
            if (sg.coroutine and !awaited) return .task;
            f.awaited_coroutine = sg.coroutine and awaited;
            return sg.ret;
        },
        .host => |h| {
            const params = h.sig.params;
            const least = requiredOf(params);
            if (args.len < least or args.len > params.len) try arity(f, e, least, params.len, args.len);
            var given: ?Type = null;
            for (args, 0..) |a, i| {
                const r = try f.alloc();
                if (i < params.len and params[i].type_arg) {
                    const v = try expr.compile(f, a, r, .unknown);
                    if (try typeArgument(f, a, v, params[i])) |t| given = t;
                } else {
                    _ = try expr.typedInto(f, a, r, if (i < params.len) params[i].type else .unknown, "the argument");
                }
            }
            return host.resultType(c.vm, h.found.method, h.found.owner, given);
        },
        .method => |m| {
            const first = try builtins.method(c, m.receiver, m.name, &.{});
            const shape = first.?;
            if (args.len > shape.params.len) try arity(f, e, 0, shape.params.len, args.len);
            var got: [16]Type = undefined;
            for (args, 0..) |a, i| {
                const r = try f.alloc();
                const want: Type = if (i < shape.params.len) shape.params[i] else .unknown;
                const v = if (want == .unknown) try expr.compile(f, a, r, .unknown) else try expr.typedInto(f, a, r, want, "the argument");
                if (i < got.len) got[i] = v.type;
            }
            const final = try builtins.method(c, m.receiver, m.name, got[0..@min(args.len, got.len)]);
            return final.?.ret;
        },
        .prelude, .math, .dynamic => {
            var got: [32]Type = undefined;
            for (args, 0..) |a, i| {
                const r = try f.alloc();
                const v = try expr.compile(f, a, r, .unknown);
                if (i < got.len) got[i] = v.type;
            }
            const n = @min(args.len, got.len);
            switch (known) {
                .prelude => |p| {
                    if (args.len < p.native.min or (p.native.max != null and args.len > p.native.max.?)) {
                        try arity(f, e, p.native.min, p.native.max orelse 255, args.len);
                    }
                    return builtins.preludeReturn(c, p.name, got[0..n]);
                },
                .math => |name| return builtins.mathReturn(name, got[0..n]),
                else => return .any,
            }
        },
    }
}

fn requiredOf(params: []const types.Param) usize {
    var n: usize = 0;
    for (params) |p| {
        if (p.has_default) break;
        n += 1;
    }
    return n;
}

fn calleeName(e: *const ast.Expr) []const u8 {
    const callee = e.kind.call.callee;
    return switch (callee.kind) {
        .ident => |n| n,
        .field => |fl| fl.name.text,
        else => "this function",
    };
}

fn arity(f: *Func, e: *const ast.Expr, least: usize, most: usize, given: usize) Error!void {
    const c = f.comp;
    const name = calleeName(e);
    const quote: []const u8 = if (e.kind.call.callee.kind == .ident or e.kind.call.callee.kind == .field) "`" else "";
    if (most == 255) {
        _ = try c.err(e.span, "{s}{s}{s} takes at least {d} argument{s}, and is given {d}", .{ quote, name, quote, least, if (least == 1) "" else "s", given });
    } else if (least == most) {
        _ = try c.err(e.span, "{s}{s}{s} takes {d} argument{s}, and is given {d}", .{ quote, name, quote, most, if (most == 1) "" else "s", given });
    } else {
        _ = try c.err(e.span, "{s}{s}{s} takes {d} to {d} arguments, and is given {d}", .{ quote, name, quote, least, most, given });
    }
}

/// `Type.name` and `module.name` name what they call without a value to
/// call it on.
fn isStatic(f: *Func, callee: *const ast.Expr) bool {
    const target = callee.kind.field.target;
    if (target.kind != .ident) return false;
    if (f.findLocal(target.kind.ident) != null) return false;
    const g = f.comp.global(target.kind.ident) orelse return false;
    return g.kind == .import or g.kind == .@"struct" or g.kind == .@"enum";
}

/// The callee in `base`, and what is known about it.
fn calleeInto(f: *Func, callee: *const ast.Expr, base: u8, direct: *bool) Error!Known {
    const c = f.comp;
    switch (callee.kind) {
        .ident => |name| {
            const place = try names.lookup(f, name);
            if (place == .builtin) {
                if (c.recording()) |r| try r.place(f, name, callee.span, place);
                _ = try expr.constant(f, base, place.builtin, .any);
                return .{ .prelude = .{ .name = name, .native = place.builtin.as(object.Native) } };
            }
            if (place == .global and place.global.kind == .function) direct.* = true;
        },
        .field => |fl| {
            if (fl.target.kind == .ident) if (c.global(fl.target.kind.ident)) |g| if (g.kind == .import and f.findLocal(fl.target.kind.ident) == null) {
                const v = try member.field(f, callee, base);
                // An import that failed has no module, and has been reported.
                const mod = c.pool.moduleOf(g.type) orelse return .dynamic;
                if (std.mem.eql(u8, mod.name, "math")) return .{ .math = fl.name.text };
                if (c.pool.signatureOf(v.type)) |sg| return .{ .signature = sg };
                return .dynamic;
            };
        },
        else => {},
    }
    const v = try expr.compile(f, callee, base, .unknown);
    if (c.pool.signatureOf(v.type)) |sg| return .{ .signature = sg };
    if (c.pool.metaOf(v.type)) |t| {
        const what = c.typeName(t);
        _ = try (try c.err(callee.span, "a struct is made with `{s}{{ ... }}`", .{what}))
            .help("or give it a function that makes one, such as `fn init(...) {s}`", .{what});
        return .dynamic;
    }
    if (!Compiler.dynamic(v.type)) _ = try c.err(callee.span, "{s} cannot be called", .{c.typeName(v.type)});
    return .dynamic;
}
