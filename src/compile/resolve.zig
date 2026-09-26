// SPDX-License-Identifier: BSD-2-Clause

//! Names of types, as written, into types; and `@import`.

const std = @import("std");

const diag = @import("../diag.zig");
const ast = @import("../syntax/ast.zig");
const Value = @import("../vm/value.zig").Value;
const object = @import("../vm/object.zig");
const access = @import("../vm/access.zig");
const types = @import("types.zig");
const Type = types.Type;
const Compiler = @import("Compiler.zig");
const Error = Compiler.Error;

const builtin_types = std.StaticStringMap(Type).initComptime(.{
    .{ "int", .int },
    .{ "float", .float },
    .{ "bool", .bool },
    .{ "string", .string },
    .{ "void", .void },
    .{ "any", .any },
    .{ "vec2", .vec2 },
    .{ "vec3", .vec3 },
    .{ "color", .color },
    .{ "error", .@"error" },
    .{ "task", .task },
    .{ "signal", .signal },
    .{ "null", .null },
});

fn unknownType(c: *Compiler, span: diag.Span, name: []const u8) Error!Type {
    var names: [64][]const u8 = undefined;
    var n: usize = 0;
    for (builtin_types.keys()) |k| {
        names[n] = k;
        n += 1;
    }
    for (c.globals.keys(), c.globals.values()) |k, g| {
        if ((g.kind == .@"struct" or g.kind == .@"enum") and n < names.len) {
            names[n] = k;
            n += 1;
        }
    }
    for (c.vm.named_types.keys()) |k| if (n < names.len) {
        names[n] = k;
        n += 1;
    };
    const h = try c.err(span, "`{s}` is not a type", .{name});
    if (access.nearest(name, names[0..n])) |near| _ = try h.help("did you mean `{s}`?", .{near});
    return .unknown;
}

pub fn typeExpr(c: *Compiler, t: *const ast.TypeExpr) Error!Type {
    const rec = c.recording();
    switch (t.kind) {
        .name => |name| {
            if (builtin_types.get(name)) |b| {
                if (rec) |r| try r.use(.{ .span = t.span, .kind = .builtin_type, .type = b });
                return b;
            }
            if (c.global(name)) |g| {
                if (rec) |r| try r.global(c, t.span, g.*);
                if (c.pool.metaOf(g.type)) |inner| return inner;
                const h = try c.err(t.span, "`{s}` is a {s}, not a type", .{ name, @tagName(g.kind) });
                _ = try h.label(c.at(g.span), "declared here", .{});
                return .unknown;
            }
            if (try @import("host.zig").named(c.vm, name)) |ht| {
                if (rec) |r| try r.hostType(c, t.span, name, ht);
                return ht;
            }
            if (rec) |r| if (r.isPlaceholder(name)) {
                try r.typeNames(c);
                return .unknown;
            };
            return unknownType(c, t.span, name);
        },
        .member => |m| {
            const g = c.global(m.module) orelse return unknownType(c, t.span, m.module);
            // One span for the two names: each has its own end of it.
            const module_span: diag.Span = .{ .start = t.span.start, .end = t.span.start + @as(u32, @intCast(m.module.len)) };
            const name_span: diag.Span = .{ .start = t.span.end -| @as(u32, @intCast(m.name.len)), .end = t.span.end };
            if (rec) |r| try r.global(c, module_span, g.*);
            const mod = c.pool.moduleOf(g.type) orelse {
                _ = try c.err(t.span, "`{s}` is not a module", .{m.module});
                return .unknown;
            };
            if (rec) |r| if (r.isPlaceholder(m.name)) {
                r.moduleTypes(g.type);
                return .unknown;
            };
            const e = mod.exports.get(m.name) orelse {
                _ = try c.err(t.span, "module `{s}` has no `{s}`", .{ mod.name, m.name });
                return .unknown;
            };
            if (rec) |r| try r.exported(name_span, g.type, mod, m.name, e);
            if (c.pool.metaOf(e.type)) |inner| return inner;
            _ = try c.err(t.span, "`{s}.{s}` is not a type", .{ m.module, m.name });
            return .unknown;
        },
        .optional => |inner| return c.pool.optional(try typeExpr(c, inner)),
        .error_union => |inner| return c.pool.errorUnion(try typeExpr(c, inner)),
        .list => |inner| return c.pool.list(try typeExpr(c, inner)),
        .map => |kv| {
            const key = try typeExpr(c, kv.key);
            if (c.pool.listOf(key) != null or c.pool.mapOf(key) != null) {
                _ = try c.err(kv.key.span, "a list or a map cannot be a map key", .{});
            }
            return c.pool.map(key, try typeExpr(c, kv.value));
        },
        .func => |f| {
            const a = c.pool.allocator();
            const params = try a.alloc(types.Param, f.params.len);
            for (f.params, params) |p, *out| out.* = .{ .name = "", .type = try typeExpr(c, p), .has_default = false };
            const sig = try a.create(types.Signature);
            sig.* = .{ .params = params, .ret = if (f.ret) |r| try typeExpr(c, r) else .void };
            return c.pool.function(sig);
        },
    }
}

/// A field's type from its default, when no type is written: what can be
/// seen without compiling the expression.
pub fn shallowType(c: *Compiler, e: *const ast.Expr) Error!Type {
    return switch (e.kind) {
        .int => .int,
        .float => .float,
        .bool => .bool,
        .string, .fstring => .string,
        .error_literal => .@"error",
        .unary => |u| if (u.op == .neg) try shallowType(c, u.operand) else if (u.op == .not) .bool else .int,
        .list => |items| blk: {
            if (items.len == 0) break :blk c.pool.list(.any);
            const first = try shallowType(c, items[0]);
            for (items[1..]) |item| if (try shallowType(c, item) != first) break :blk c.pool.list(.any);
            break :blk c.pool.list(first);
        },
        .map => |entries| blk: {
            if (entries.len == 0) break :blk c.pool.map(.any, .any);
            const k = try shallowType(c, entries[0].key);
            const v = try shallowType(c, entries[0].value);
            for (entries[1..]) |entry| {
                if (try shallowType(c, entry.key) != k or try shallowType(c, entry.value) != v) break :blk c.pool.map(.any, .any);
            }
            break :blk c.pool.map(k, v);
        },
        .call => |call| blk: {
            if (call.callee.kind == .ident) {
                const name = call.callee.kind.ident;
                if (std.mem.eql(u8, name, "vec2")) break :blk .vec2;
                if (std.mem.eql(u8, name, "vec3")) break :blk .vec3;
                if (std.mem.eql(u8, name, "color")) break :blk .color;
            }
            break :blk .any;
        },
        .struct_literal => |s| blk: {
            if (s.type.kind == .ident) if (c.global(s.type.kind.ident)) |g| if (c.pool.metaOf(g.type)) |t| break :blk t;
            break :blk .any;
        },
        else => .any,
    };
}

/// `const name = @import("path");` at the top of a file: the module is
/// compiled now, so what it exports has types before anything uses it.
pub fn importGlobal(c: *Compiler, g: *Compiler.Global, init: *const ast.Expr) Error!void {
    const args = init.kind.builtin.args;
    g.kind = .import;
    g.type = .unknown;
    if (args.len != 1 or args[0].kind != .string) {
        _ = try c.err(init.span, "`@import` takes the module's name as a string: `@import(\"math\")`", .{});
        return;
    }
    const path = args[0].kind.string;
    const info = (try importModule(c, path, args[0].span)) orelse return;
    g.type = try c.pool.intern(.{ .module = info });
    g.value = .fromObj(.module, &info.object.obj);
    c.module.globals.items[g.index] = g.value.?;
    try c.module.imports.append(c.vm.gpa, info.object);
}

fn importModule(c: *Compiler, path: []const u8, span: diag.Span) Error!?*types.Module {
    const vm = c.vm;
    if (c.session.modules.get(path)) |existing| return existing;
    if (vm.native_modules.get(path)) |m| return try nativeInfo(c, path, m);
    const loader = vm.options.loader orelse {
        _ = try (try c.err(span, "there is no module `{s}`", .{path}))
            .note("the modules built in are `math` and `json`; the host has not set a loader for files", .{});
        return null;
    };
    const loaded = loader.load(loader.context, vm.gpa, c.name, path) catch |e| {
        _ = try c.err(span, "cannot load `{s}`: {s}", .{ path, @errorName(e) });
        return null;
    };
    defer vm.gpa.free(loaded.name);
    defer vm.gpa.free(loaded.source);
    if (c.session.modules.get(loaded.name)) |existing| return existing;
    _ = Compiler.compileModule(vm, loaded.name, loaded.source, c.diags) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CompileFailed => {
            _ = try c.err(span, "`{s}` has errors, reported above", .{path});
            return null;
        },
    };
    return c.session.modules.get(loaded.name);
}

fn nativeInfo(c: *Compiler, name: []const u8, m: *object.Module) Error!*types.Module {
    const a = c.pool.allocator();
    const info = try a.create(types.Module);
    info.* = .{ .name = try a.dupe(u8, name), .object = m };
    for (m.names.items, m.globals.items, 0..) |n, v, i| {
        const t: Type = switch (v.tag) {
            .int => .int,
            .float => .float,
            .bool => .bool,
            .string => .string,
            else => .any,
        };
        try info.exports.put(a, try a.dupe(u8, n.bytes()), .{ .type = t, .global = @intCast(i), .value = v, .is_const = true });
    }
    try c.session.modules.put(c.vm.gpa, info.name, info);
    return info;
}
