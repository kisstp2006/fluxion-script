// SPDX-License-Identifier: BSD-2-Clause

//! A module's declarations: every name gathered first, so order in the file
//! does not matter; then each one's type worked out; and at the end, the
//! objects the module hands to the virtual machine.

const std = @import("std");
const Allocator = std.mem.Allocator;

const diag = @import("../diag.zig");
const ast = @import("../syntax/ast.zig");
const Value = @import("../vm/value.zig").Value;
const object = @import("../vm/object.zig");
const make = @import("../vm/make.zig");
const types = @import("types.zig");
const Type = types.Type;
const Compiler = @import("Compiler.zig");
const Error = Compiler.Error;
const resolve_mod = @import("resolve.zig");
const body = @import("body.zig");
const scan = @import("scan.zig");
const binary = @import("binary.zig");

pub const StructDecl = struct {
    node: *const ast.Struct,
    info: *types.Struct,
};

pub const EnumDecl = struct {
    node: *const ast.Enum,
    info: *types.Enum,
};

pub const Owner = union(enum) {
    none,
    @"struct": *types.Struct,
    @"enum": *types.Enum,
};

pub const FnDecl = struct {
    node: *const ast.Fn,
    sig: *types.Signature,
    owner: Owner,
    global: ?u32,
    proto: *object.Proto,
};

pub fn collect(c: *Compiler, tree: ast.Module) Error!void {
    const vm = c.vm;
    for (tree.stmts) |s| switch (s.kind) {
        .@"fn" => |f| {
            const name = f.name.?.text;
            _ = try c.addGlobal(name, .{ .index = 0, .type = .unknown, .kind = .function, .span = f.name.?.span, .node = s });
        },
        .@"struct" => |st| {
            const name = try vm.intern(st.name.text);
            const reused = if (c.patch) |p| try p.reuseClass(vm.gpa, name) else null;
            const class = reused orelse try make.class(vm, name);
            class.module = c.module;
            if (st.doc) |d| class.doc = try vm.gpa.dupe(u8, d);
            const info = try c.pool.allocator().create(types.Struct);
            info.* = .{ .name = try c.pool.allocator().dupe(u8, st.name.text), .file = c.file, .span = st.name.span, .class = class };
            info.self_type = try c.pool.intern(.{ .@"struct" = info });
            const g = try c.addGlobal(st.name.text, .{ .index = 0, .type = try c.pool.meta(info.self_type), .kind = .@"struct", .span = st.name.span, .node = s });
            g.value = .fromObj(.class, &class.obj);
            c.module.globals.items[g.index] = g.value.?;
            try c.structs.append(c.gpa, .{ .node = st, .info = info });
        },
        .@"enum" => |e| {
            const name = try vm.intern(e.name.text);
            const reused = if (c.patch) |p| try p.reuseEnum(vm.gpa, name) else null;
            const type_obj = reused orelse try make.enumType(vm, name);
            type_obj.module = c.module;
            const info = try c.pool.allocator().create(types.Enum);
            info.* = .{ .name = try c.pool.allocator().dupe(u8, e.name.text), .file = c.file, .span = e.name.span, .members = &.{}, .type_obj = type_obj };
            info.self_type = try c.pool.intern(.{ .@"enum" = info });
            const g = try c.addGlobal(e.name.text, .{ .index = 0, .type = try c.pool.meta(info.self_type), .kind = .@"enum", .span = e.name.span, .node = s });
            g.value = .fromObj(.enum_type, &type_obj.obj);
            c.module.globals.items[g.index] = g.value.?;
            try c.enums.append(c.gpa, .{ .node = e, .info = info });
        },
        .@"var" => |v| {
            _ = try c.addGlobal(v.name.text, .{ .index = 0, .type = .unknown, .kind = if (v.is_const) .constant else .variable, .span = v.name.span, .node = s });
        },
        .@"test" => |t| try c.tests.append(c.gpa, t),
        else => {},
    };
}

pub fn resolve(c: *Compiler) Error!void {
    for (c.globals.values()) |*g| {
        if (g.kind != .constant and g.kind != .variable) continue;
        const v = g.node.?.kind.@"var";
        const init = v.value orelse continue;
        if (init.kind == .builtin and std.mem.eql(u8, init.kind.builtin.name.text, "import")) {
            try resolve_mod.importGlobal(c, g, init);
        }
    }
    for (c.enums.items) |e| try resolveEnum(c, e);
    for (c.structs.items) |s| try resolveStruct(c, s);
    for (c.structs.items) |s| try resolveMethods(c, s);
    for (c.globals.values()) |*g| switch (g.kind) {
        .function => {
            const node = g.node.?.kind.@"fn";
            const sig = try signature(c, node, null);
            g.type = try c.pool.function(sig);
            const proto = try make.proto(c.vm, try c.vm.intern(node.name.?.text));
            proto.decl = node.name.?.span;
            if (node.doc) |d| proto.doc = try c.vm.gpa.dupe(u8, d);
            try c.functions.append(c.gpa, .{ .node = node, .sig = sig, .owner = .none, .global = g.index, .proto = proto });
        },
        .constant, .variable => try resolveVar(c, g),
        else => {},
    };
}

fn resolveVar(c: *Compiler, g: *Compiler.Global) Error!void {
    if (g.kind == .import) return;
    const v = g.node.?.kind.@"var";
    if (v.type) |t| {
        g.type = try resolve_mod.typeExpr(c, t);
        return;
    }
    if (v.value == null) {
        _ = try (try c.err(v.name.span, "`{s}` needs a type or a value", .{v.name.text}))
            .help("write `var {s}: int = 0;` or give it a starting value", .{v.name.text});
        g.type = .unknown;
        return;
    }
    if (g.kind == .constant) {
        if (literal(c, v.value.?)) |lit| {
            g.type = lit.type;
            g.value = lit.value;
        }
    }
}

pub const Literal = struct { type: Type, value: Value };

/// The value of an expression a declaration can fold, without compiling it.
pub fn literal(c: *Compiler, e: *const ast.Expr) ?Literal {
    const lit = @import("fold.zig").fold(c, e) orelse return null;
    return .{ .type = lit.type, .value = lit.value };
}

fn resolveEnum(c: *Compiler, e: EnumDecl) Error!void {
    const vm = c.vm;
    const node = e.node;
    const names = try c.pool.allocator().alloc([]const u8, node.members.len);
    const spans = try c.pool.allocator().alloc(diag.Span, node.members.len);
    const members = try vm.gpa.alloc(*object.String, node.members.len);
    const values = try vm.gpa.alloc(i64, node.members.len);
    var next: i64 = 0;
    for (node.members, 0..) |m, i| {
        for (node.members[0..i]) |prior| if (std.mem.eql(u8, prior.name.text, m.name.text)) {
            const h = try c.err(m.name.span, "`{s}` is already a member of `{s}`", .{ m.name.text, node.name.text });
            _ = try h.label(c.at(prior.name.span), "first here", .{});
        };
        names[i] = try c.pool.allocator().dupe(u8, m.name.text);
        spans[i] = m.name.span;
        members[i] = try vm.intern(m.name.text);
        if (m.value) |v| {
            if (literal(c, v)) |lit| {
                if (lit.type == .int) next = lit.value.asInt() else _ = try c.err(v.span, "an enum member's value is an int", .{});
            } else _ = try c.err(v.span, "an enum member's value must be written as a number", .{});
        }
        values[i] = next;
        next +%= 1;
    }
    e.info.members = names;
    e.info.spans = spans;
    e.info.type_obj.members = members;
    e.info.type_obj.values = values;
    if (node.members.len == 0) _ = try c.err(node.name.span, "`{s}` has no members", .{node.name.text});
    for (node.methods) |m| {
        const sig = try signature(c, m, e.info.self_type);
        const proto = try make.proto(vm, try vm.intern(m.name.?.text));
        proto.decl = m.name.?.span;
        try e.info.methods.put(c.pool.allocator(), try c.pool.allocator().dupe(u8, m.name.?.text), .{ .name = m.name.?.text, .sig = sig, .span = m.name.?.span, .file = c.file });
        try c.functions.append(c.gpa, .{ .node = m, .sig = sig, .owner = .{ .@"enum" = e.info }, .global = null, .proto = proto });
    }
}

fn resolveStruct(c: *Compiler, s: StructDecl) Error!void {
    const info = s.info;
    if (info.resolved) return;
    info.resolved = true;
    const vm = c.vm;
    const node = s.node;
    if (node.parent) |p| {
        const pt = try resolve_mod.typeExpr(c, p);
        if (c.pool.structOf(pt)) |parent| {
            if (parent.extends(info)) {
                _ = try c.err(p.span, "`{s}` cannot extend `{s}`: that would make each the other's parent", .{ node.name.text, parent.name });
            } else {
                for (c.structs.items) |other| if (other.info == parent) try resolveStruct(c, other);
                info.parent = parent;
                info.class.parent = parent.class;
                for (parent.fields.items) |f| try info.fields.append(c.pool.allocator(), f);
            }
        } else if (pt != .unknown) {
            _ = try c.err(p.span, "a struct can only extend a struct, and `{s}` is {s}", .{ c.typeName(pt), c.typeName(pt) });
        }
    }
    const inherited = info.fields.items.len;
    if (info.parent == null) for (vm.host_members.items) |m| {
        const t: Type = if (m.type) |host_type| try @import("host.zig").typeOf(vm, host_type) else .any;
        try info.fields.append(c.pool.allocator(), .{ .name = m.name, .type = t, .slot = @intCast(info.fields.items.len), .is_const = true, .is_signal = false, .span = .empty, .file = .none, .host = true, .doc = m.doc });
    };
    for (node.fields) |f| {
        if (info.field(f.name.text)) |prior| {
            if (prior.host) {
                _ = try c.err(f.name.span, "`{s}` is a member the host gives every struct; call the field something else", .{f.name.text});
                continue;
            }
            const h = try c.err(f.name.span, "`{s}` already has a field `{s}`", .{ node.name.text, f.name.text });
            _ = try h.label(.{ .file = prior.file, .span = prior.span }, "first declared here", .{});
            continue;
        }
        const t: Type = if (f.type) |te| try resolve_mod.typeExpr(c, te) else if (f.value) |v| try resolve_mod.shallowType(c, v) else blk: {
            _ = try (try c.err(f.name.span, "field `{s}` needs a type or a default value", .{f.name.text}))
                .help("write `var {s}: int = 0;`", .{f.name.text});
            break :blk .unknown;
        };
        try info.fields.append(c.pool.allocator(), .{ .name = f.name.text, .type = t, .slot = @intCast(info.fields.items.len), .is_const = false, .is_signal = false, .span = f.name.span, .file = c.file });
    }
    for (node.signals) |sig| {
        if (info.field(sig.name.text)) |prior| if (prior.host) {
            _ = try c.err(sig.name.span, "`{s}` is a member the host gives every struct; call the signal something else", .{sig.name.text});
            continue;
        };
        if (info.field(sig.name.text) != null) {
            _ = try c.err(sig.name.span, "`{s}` already has a member `{s}`", .{ node.name.text, sig.name.text });
            continue;
        }
        const params = try c.pool.allocator().alloc(types.Param, sig.params.len);
        for (sig.params, params) |p, *out| out.* = .{ .name = p.name.text, .type = if (p.type) |t| try resolve_mod.typeExpr(c, t) else .any, .has_default = false };
        const signature_info = try c.pool.allocator().create(types.Signature);
        signature_info.* = .{ .params = params, .ret = .void };
        try info.fields.append(c.pool.allocator(), .{ .name = sig.name.text, .type = .signal, .slot = @intCast(info.fields.items.len), .is_const = true, .is_signal = true, .span = sig.name.span, .file = c.file, .signal = signature_info });
    }
    for (node.consts) |k| {
        const lit = if (k.value) |v| literal(c, v) else null;
        const t: Type = if (k.type) |te| try resolve_mod.typeExpr(c, te) else if (lit) |l| l.type else .unknown;
        if (lit == null) _ = try c.err(k.name.span, "a struct constant is a literal: a number, a string or a bool", .{});
        const what = try std.fmt.allocPrint(c.arena, "`{s}.{s}`", .{ node.name.text, k.name.text });
        const value = if (lit != null) try literalDefault(c, what, t, lit, k.value.?) else null;
        try info.consts.put(c.pool.allocator(), k.name.text, .{ .name = k.name.text, .type = t, .value = value, .span = k.name.span });
    }

    const class = info.class;
    // The annotations' maps and lists belong to nothing the collector sees
    // until the fields are the class's.
    vm.heap.paused += 1;
    defer vm.heap.paused -= 1;
    const fields = try vm.gpa.alloc(object.Field, info.fields.items.len);
    for (info.fields.items, fields, 0..) |f, *out, i| {
        out.* = .{
            .name = try vm.intern(f.name),
            .check = try c.pool.check(&vm.checks, vm.gpa, f.type),
            .default = if (f.is_signal) .int(@intCast(f.signal.?.params.len)) else zeroOf(c, f.type),
            .exported = false,
            .is_const = f.is_const,
            .is_signal = f.is_signal,
            .host = f.host,
        };
        if (f.signal) |sig| out.signature = try paramsText(c, sig.params);
        if (i >= inherited) {
            if (f.host) if (f.doc) |d| {
                out.doc = try vm.gpa.dupe(u8, d);
            };
            if (f.is_signal) for (node.signals) |sig| if (std.mem.eql(u8, sig.name.text, f.name)) {
                if (sig.doc) |d| out.doc = try vm.gpa.dupe(u8, d);
            };
            const ast_field = findField(node, f.name);
            if (ast_field) |af| {
                if (af.doc) |d| out.doc = try vm.gpa.dupe(u8, d);
                for (af.annotations) |a| {
                    if (std.mem.eql(u8, a.name.text, "export")) {
                        out.exported = true;
                    } else {
                        try unheard(c, a);
                        try annotate(c, out, a);
                    }
                }
                if (af.value) |v| {
                    const what = try std.fmt.allocPrint(c.arena, "field `{s}`", .{f.name});
                    if (try literalDefault(c, what, f.type, literal(c, v), v)) |value| out.default = value;
                }
                out.computed = if (af.value) |v| literal(c, v) == null and v.kind != .null else c.pool.listOf(f.type) != null or c.pool.mapOf(f.type) != null;
            }
        } else if (info.parent) |p| {
            out.default = p.class.fields[i].default;
            out.exported = p.class.fields[i].exported;
            out.annotations = p.class.fields[i].annotations;
            out.computed = p.class.fields[i].computed;
            if (p.class.fields[i].doc) |d| out.doc = try vm.gpa.dupe(u8, d);
        }
        if (f.is_signal) class.has_signals = true;
        try class.slots.put(vm.gpa, out.name, f.slot);
    }
    class.fields = fields;
    if (std.mem.indexOfScalar(*object.Class, vm.classes.items, class) == null) try vm.classes.append(vm.gpa, class);
}

/// A default written as a literal, as its field keeps it: an int where a
/// float is wanted becomes a float, and one of another type is a mistake.
/// No code checks it when an instance is made, so it is checked here.
fn literalDefault(c: *Compiler, what: []const u8, t: Type, lit: ?Literal, v: *const ast.Expr) Error!?Value {
    if (v.kind == .null) {
        if (c.pool.nullable(t)) return .null;
        _ = try (try c.err(v.span, "{s} is {s}, which cannot be null", .{ what, c.typeName(t) }))
            .help("make it `?{s}` to allow null", .{c.typeName(t)});
        return null;
    }
    const l = lit orelse return null;
    const widened = l.type == .int and (t == .float or c.pool.isOptional(t) == .float);
    if (widened) return .float(@floatFromInt(l.value.asInt()));
    if (binary.compatible(c, l.type, t)) return l.value;
    _ = try (try c.err(v.span, "{s} must be {s}, not {s}", .{ what, c.typeName(t), c.typeName(l.type) }))
        .text("this is {s}", .{c.typeName(l.type)});
    return null;
}

/// An annotation the host did not say it reads, where it said which it
/// does: most likely a mistake.
fn unheard(c: *Compiler, a: ast.Annotation) Error!void {
    const vm = c.vm;
    if (vm.annotations.items.len == 0) return;
    var names: [64][]const u8 = undefined;
    var n: usize = 0;
    names[n] = "export";
    n += 1;
    for (vm.annotations.items) |known| {
        if (std.mem.eql(u8, known.name, a.name.text)) return;
        if (n < names.len) {
            names[n] = known.name;
            n += 1;
        }
    }
    const h = try c.warn(a.name.span, "`@{s}` is no annotation the host reads", .{a.name.text});
    if (@import("../vm/access.zig").nearest(a.name.text, names[0..n])) |near| _ = try h.help("did you mean `@{s}`?", .{near});
}

/// An annotation of a field's besides `@export` - `@range(0, 100)`,
/// `@multiline` - kept with the field for the host, by its name, with its
/// arguments: literals, each.
fn annotate(c: *Compiler, field: *object.Field, a: ast.Annotation) Error!void {
    const vm = c.vm;
    const args = try make.list(vm, a.args.len, .any);
    for (a.args) |arg| {
        const lit = literal(c, arg) orelse {
            _ = try c.err(arg.span, "an annotation's arguments are literals: a number, a string or a bool", .{});
            continue;
        };
        args.items.appendAssumeCapacity(lit.value);
    }
    const table = field.annotations orelse try make.map(vm, .string, .any);
    field.annotations = table;
    const key: Value = .fromObj(.string, &(try vm.intern(a.name.text)).obj);
    table.table.put(vm.gpa, key, .fromObj(.list, &args.obj)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

fn findField(node: *const ast.Struct, name: []const u8) ?*const ast.VarDecl {
    for (node.fields) |f| if (std.mem.eql(u8, f.name.text, name)) return f;
    return null;
}

/// What a field starts as when nothing says: the zero of its type. Lists
/// and maps are made fresh for each instance, by the struct's defaults.
pub fn zeroOf(c: *Compiler, t: Type) Value {
    return switch (t) {
        .int => .int(0),
        .float => .float(0),
        .bool => .false,
        .string => c.vm.string("") catch .null,
        .vec2 => .vec2(0, 0),
        .vec3 => .vec3(0, 0, 0),
        else => if (c.pool.enumOf(t)) |e| .enumValue(&e.type_obj.obj, 0) else .null,
    };
}

fn resolveMethods(c: *Compiler, s: StructDecl) Error!void {
    const vm = c.vm;
    for (s.node.methods) |m| {
        const name = m.name.?.text;
        if (s.info.field(name)) |prior| if (prior.host) {
            _ = try c.err(m.name.?.span, "`{s}` is a member the host gives every struct; call the method something else", .{name});
            continue;
        };
        if (s.info.field(name) != null) {
            _ = try c.err(m.name.?.span, "`{s}` already has a field `{s}`; a method cannot share its name", .{ s.info.name, name });
            continue;
        }
        if (s.info.methods.contains(name)) {
            _ = try c.err(m.name.?.span, "`{s}` already has a method `{s}`", .{ s.info.name, name });
            continue;
        }
        const sig = try signature(c, m, s.info.self_type);
        if (vm.hookNamed(name)) |hook| try hooked(c, m, sig, hook);
        if (s.info.parent) |p| if (p.method(name)) |inherited| {
            if (!sameShape(inherited.sig, sig)) {
                const h = try c.err(m.name.?.span, "`{s}.{s}` must take the arguments, and return the type, of the `{s}.{s}` it overrides", .{ s.info.name, name, p.name, name });
                _ = try h.label(.{ .file = inherited.file, .span = inherited.span }, "overridden here", .{});
            }
        };
        const proto = try make.proto(vm, try vm.intern(name));
        proto.decl = m.name.?.span;
        if (m.doc) |d| proto.doc = try vm.gpa.dupe(u8, d);
        proto.signature = try paramsText(c, sig.params[@intFromBool(sig.has_self)..]);
        try s.info.methods.put(c.pool.allocator(), name, .{ .name = name, .sig = sig, .span = m.name.?.span, .file = c.file });
        try c.functions.append(c.gpa, .{ .node = m, .sig = sig, .owner = .{ .@"struct" = s.info }, .global = null, .proto = proto });
    }
}

/// A method the host calls: what it takes checked against what the host
/// gives, and a parameter given no type given the one the host passes.
fn hooked(c: *Compiler, node: *const ast.Fn, sig: *types.Signature, hook: *const @import("../vm/Vm.zig").Hook) Error!void {
    if (!sig.has_self) return;
    const params = sig.params[1..];
    if (params.len != hook.params.len) {
        var text: std.Io.Writer.Allocating = .init(c.arena);
        (blk: {
            text.writer.print("fn {s}(self", .{hook.name}) catch |e| break :blk e;
            for (hook.params) |p| text.writer.print(", {s}: {s}", .{ p.name, c.typeName(try @import("host.zig").typeOf(c.vm, p.type)) }) catch |e| break :blk e;
            text.writer.writeByte(')') catch |e| break :blk e;
        }) catch return error.OutOfMemory;
        const h = try c.warn(node.name.?.span, "the host calls `{s}` with {d} argument{s}, and this takes {d}", .{ hook.name, hook.params.len, if (hook.params.len == 1) "" else "s", params.len });
        _ = try h.help("write it `{s}`", .{text.written()});
        return;
    }
    const typed = try c.pool.allocator().dupe(types.Param, sig.params);
    for (typed[1..], hook.params) |*p, given| {
        if (p.type == .any) p.type = try @import("host.zig").typeOf(c.vm, given.type);
    }
    sig.params = typed;
}

/// An override is called wherever the method it overrides is, with
/// arguments checked against that one's signature, so the two must agree.
fn sameShape(a: *const types.Signature, b: *const types.Signature) bool {
    if (a.has_self != b.has_self or a.params.len != b.params.len or a.ret != b.ret or a.coroutine != b.coroutine) return false;
    for (a.params, b.params, 0..) |x, y, i| {
        if (i == 0 and a.has_self) continue;
        if (x.type != y.type or x.has_default != y.has_default) return false;
    }
    return true;
}

/// Parameters as a host shows them, `by: ?Actor, damage: int`; an untyped
/// one is its name alone.
fn paramsText(c: *Compiler, params: []const types.Param) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(c.vm.gpa);
    errdefer out.deinit();
    for (params, 0..) |param, i| {
        if (i > 0) out.writer.writeAll(", ") catch return error.OutOfMemory;
        out.writer.writeAll(param.name) catch return error.OutOfMemory;
        if (param.type != .any and param.type != .unknown) out.writer.print(": {s}", .{c.typeName(param.type)}) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

pub fn signature(c: *Compiler, node: *const ast.Fn, self_type: ?Type) Error!*types.Signature {
    const a = c.pool.allocator();
    const sig = try a.create(types.Signature);
    var params: std.ArrayList(types.Param) = .empty;
    var has_self = false;
    for (node.params) |p| {
        if (p.is_self) {
            has_self = true;
            if (self_type == null) _ = try c.err(p.name.span, "`self` can only be the first parameter of a method", .{});
            try params.append(a, .{ .name = "self", .type = self_type orelse .unknown, .has_default = false });
            continue;
        }
        const t: Type = if (p.type) |te| try resolve_mod.typeExpr(c, te) else if (p.default) |d| (if (literal(c, d)) |lit| lit.type else .any) else .any;
        try params.append(a, .{ .name = try a.dupe(u8, p.name.text), .type = t, .has_default = p.default != null });
    }
    const ret: Type = if (node.ret) |r| try resolve_mod.typeExpr(c, r) else switch (node.body) {
        .block => |b| if (scan.returnsValue(b)) .any else .void,
        .expr => .any,
    };
    sig.* = .{ .params = params.items, .ret = ret, .has_self = has_self, .coroutine = scan.fnAwaits(node) };
    return sig;
}

pub fn compileBodies(c: *Compiler) Error!void {
    for (c.functions.items) |fd| {
        if (c.diags.full()) return;
        body.function(c, fd) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CompileFailed => {},
        };
    }
    for (c.structs.items) |s| {
        body.defaults(c, s) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CompileFailed => {},
        };
    }
    for (c.tests.items) |t| {
        body.testBlock(c, t) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CompileFailed => {},
        };
    }
}

/// A declared function's value: on a reload the one it had before, which
/// whatever holds it goes on calling, now running the new code.
fn functionValue(c: *Compiler, fd: FnDecl) Error!*object.Closure {
    if (c.patch) |p| {
        const gpa = c.vm.gpa;
        const name = try c.vm.intern(fd.node.name.?.text);
        const reused = switch (fd.owner) {
            .none => try p.reuseFunction(gpa, name, fd.proto),
            .@"struct" => |s| try p.reuseMethod(gpa, s.class, name, fd.sig.has_self, fd.proto),
            .@"enum" => |e| try p.reuseEnumMethod(gpa, e.type_obj, name, fd.proto),
        };
        if (reused) |r| return r;
    }
    return make.closure(c.vm, fd.proto);
}

/// Hands the compiled functions to their module variables, structs and
/// enums, and lists what the module exports.
pub fn publish(c: *Compiler) Error!void {
    const vm = c.vm;
    for (c.functions.items) |fd| {
        const closure = try functionValue(c, fd);
        const v: Value = .fromObj(.function, &closure.obj);
        switch (fd.owner) {
            .none => c.module.globals.items[fd.global.?] = v,
            .@"struct" => |s| {
                const name = try vm.intern(fd.node.name.?.text);
                if (fd.sig.has_self) try s.class.methods.put(vm.gpa, name, v) else try s.class.statics.put(vm.gpa, name, v);
                s.methods.getPtr(fd.node.name.?.text).?.closure = closure;
            },
            .@"enum" => |e| {
                try e.type_obj.methods.put(vm.gpa, try vm.intern(fd.node.name.?.text), v);
                e.methods.getPtr(fd.node.name.?.text).?.closure = closure;
            },
        }
    }
    for (c.structs.items) |s| {
        var it = s.info.consts.iterator();
        while (it.next()) |e| if (e.value_ptr.value) |v| try s.info.class.statics.put(vm.gpa, try vm.intern(e.key_ptr.*), v);
    }
    for (c.globals.keys(), c.globals.values()) |name, g| {
        if (std.mem.startsWith(u8, name, "_")) continue;
        const key = try c.pool.allocator().dupe(u8, name);
        const value: ?Value = switch (g.kind) {
            .function, .@"struct", .@"enum", .import => c.module.globals.items[g.index],
            .constant => g.value,
            .variable => null,
        };
        try c.info.exports.put(c.pool.allocator(), key, .{ .type = g.type, .global = g.index, .value = value, .is_const = g.kind != .variable });
    }
}
