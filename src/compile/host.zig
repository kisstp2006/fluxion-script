// SPDX-License-Identifier: BSD-2-Clause

//! The host's types to the compiler. A struct, a union or a handle of the
//! host's is a type of its own - `Sprite`, `InputEvent` - known by what its
//! reflected type lists: fields, methods, the union's methods for an arm's
//! payload, the methods another type gives it (`Vm.extend`), and the members
//! the host declares beside those (`Vm.declareMember`). An enum is a Flux
//! enum; numbers, strings, vectors and colours are the language's own.
//!
//! A call of a host's method is checked as a script function's is: how many
//! arguments - the last ones may be left out where the method gives them
//! defaults - and of what types; what it gives back is of the type it says.
//! A method given a type, `entity.get(Sprite)`, gives a value of that type
//! when it says it gives a `flux.Value`: a `?flux.Value`, one that may be
//! null.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const reflect = @import("fluxion_reflect");
const Vm = @import("../vm/Vm.zig");
const Value = @import("../vm/value.zig").Value;
const bridge = @import("../reflect.zig");
const types = @import("types.zig");
const Type = types.Type;

pub const nameOf = bridge.nameOf;

fn pool(vm: *Vm) *types.Pool {
    return &vm.session.?.pool;
}

/// The compiler's type of a value of the host's type `t`.
pub fn typeOf(vm: *Vm, t: *const reflect.Type) Allocator.Error!Type {
    const p = pool(vm);
    if (bridge.hostType(vm, t)) |h| {
        if (h.script) |s| return p.host(s);
        return if (h.given) |g| builtin(g) else .any;
    }
    if (t.is(Value)) return .any;
    return switch (t.kind) {
        .void => .void,
        .noreturn => .never,
        .bool => .bool,
        .int => .int,
        .float => .float,
        .@"enum" => enumOf(vm, t),
        .optional => p.optional(try typeOf(vm, t.child().?)),
        .error_union => typeOf(vm, t.child().?),
        .pointer => if (t.isString()) .string else if (t.info.pointer.size == .one) typeOf(vm, t.info.pointer.child) else .any,
        .slice, .array => if (t.isString()) .string else p.list(try typeOf(vm, t.child().?)),
        .@"struct" => switch (bridge.vectorLength(t) orelse 0) {
            2 => .vec2,
            3 => .vec3,
            else => p.host(t),
        },
        .@"union" => if (allVoid(t)) tagOf(vm, t) else p.host(t),
        .@"opaque" => p.host(t),
        else => .any,
    };
}

fn builtin(b: Vm.BuiltinType) Type {
    return switch (b) {
        .string => .string,
        .vec2 => .vec2,
        .vec3 => .vec3,
        .color => .color,
        .signal => .signal,
        .task => .task,
        .@"error" => .@"error",
        .int => .int,
        .float => .float,
        .bool => .bool,
        .list, .map => .any,
    };
}

/// Whether every arm of a union holds nothing: an enum, to a script.
fn allVoid(t: *const reflect.Type) bool {
    if (t.info.@"union".tag == null) return false;
    for (t.fields()) |arm| if (arm.type.kind != .void) return false;
    return true;
}

/// The Flux enum of the host's enum `t`: one for each, shared by the
/// modules compiled in the VM.
pub fn enumOf(vm: *Vm, t: *const reflect.Type) Allocator.Error!Type {
    return fluxEnum(vm, bridge.enumType(vm, t) catch return error.OutOfMemory);
}

/// The Flux enum of the tag of the host's union `u`, named as `u` is.
pub fn tagOf(vm: *Vm, u: *const reflect.Type) Allocator.Error!Type {
    return fluxEnum(vm, bridge.tagType(vm, u) catch return error.OutOfMemory);
}

fn fluxEnum(vm: *Vm, obj: *@import("../vm/object.zig").EnumType) Allocator.Error!Type {
    const session = vm.session.?;
    for (session.host_enums.items) |e| if (e.type_obj == obj) return e.self_type;
    const a = session.pool.allocator();
    const names = try a.alloc([]const u8, obj.members.len);
    for (obj.members, names) |m, *n| n.* = m.bytes();
    const e = try a.create(types.Enum);
    e.* = .{ .name = obj.name.bytes(), .file = .none, .span = .empty, .members = names, .type_obj = obj };
    e.self_type = try session.pool.intern(.{ .@"enum" = e });
    try session.host_enums.append(vm.gpa, e);
    return e.self_type;
}

/// The host's type a type named in a script stands for: `Sprite`, `Key`.
pub fn named(vm: *Vm, name: []const u8) Allocator.Error!?Type {
    const t = vm.named_types.get(name) orelse return null;
    if (t.kind == .@"enum") return try enumOf(vm, t);
    return try typeOf(vm, t);
}

/// What a method gives back. A `flux.Value` is the type it was given, when
/// it was given one. An error a script cannot catch - the VM stopping it -
/// is no error to it, nor is one of a type whose errors stop the script
/// (see `bridge.GivesErrors`).
pub fn resultType(vm: *Vm, m: *const reflect.Method, owner: *const reflect.Type, given: ?Type) Allocator.Error!Type {
    const p = pool(vm);
    var ret = m.type.info.function.return_type;
    var catchable = false;
    if (ret.kind == .error_union) {
        catchable = owner.attribute(bridge.GivesErrors) != null and !onlyStops(ret.info.error_union.error_set);
        ret = ret.info.error_union.payload;
    }
    const optional = ret.kind == .optional and ret.child().?.is(Value);
    if (!ret.is(Value) and !optional) {
        const t = try typeOf(vm, ret);
        return if (catchable) p.errorUnion(t) else t;
    }
    // A `flux.Value`: the type given, or the one the method says it gives.
    const said: ?Type = if (given) |g| g else if (m.attribute(bridge.Returns)) |r| switch (r.*) {
        .type => |t| try typeOf(vm, t),
        .builtin => |b| builtin(b),
    } else null;
    const t = said orelse return if (catchable) p.errorUnion(.any) else .any;
    const held = if (optional) try p.optional(t) else t;
    return if (catchable) p.errorUnion(held) else held;
}

/// Whether the only errors of a set are those that stop a script.
fn onlyStops(set: *const reflect.Type) bool {
    const e = set.info.error_set;
    if (e.is_any) return false;
    for (e.names.slice()) |n| if (!n.eql("Panic") and !n.eql("OutOfMemory")) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Members

pub const Member = union(enum) {
    field: struct { field: *const reflect.Field, owner: *const reflect.Type },
    method: Method,
    /// Declared by the host beside what the type lists.
    declared: *const Vm.DeclaredMember,
};

pub const Method = struct {
    method: *const reflect.Method,
    /// The type it is declared in: the value's own, the union whose arm the
    /// value is, or the one an extension gives it from.
    owner: *const reflect.Type,
    /// The type of the value it is called on.
    on: *const reflect.Type,
    extension: bool = false,
};

/// The member `name` of a value of the host's type `t`, if it has one.
pub fn member(vm: *const Vm, t: *const reflect.Type, name: []const u8) ?Member {
    if (t.kind == .@"struct") if (t.field(name)) |f| return .{ .field = .{ .field = f, .owner = t } };
    if (t.kind == .@"union") if (commonField(t, name)) |f| return .{ .field = f };
    if (t.method(name)) |m| return .{ .method = .{ .method = m, .owner = t, .on = t } };
    if (unionOf(vm, t)) |u| if (u.method(name)) |m| return .{ .method = .{ .method = m, .owner = u, .on = t } };
    for (vm.extensions.items) |ext| if (ext.of.same(t)) {
        if (bridge.extensionMethod(vm, ext, name)) |m| return .{ .method = .{ .method = m, .owner = ext.by, .on = t, .extension = true } };
    };
    for (vm.members.items) |*d| if (d.of.same(t) and std.mem.eql(u8, d.name, name)) return .{ .declared = d };
    return null;
}

/// The field of the name every arm of a union holds, of one type.
fn commonField(u: *const reflect.Type, name: []const u8) ?@FieldType(Member, "field") {
    var found: ?@FieldType(Member, "field") = null;
    for (u.fields()) |arm| {
        if (arm.type.kind != .@"struct") return null;
        const f = arm.type.field(name) orelse return null;
        if (found) |x| {
            if (!x.field.type.same(f.type)) return null;
        } else found = .{ .field = f, .owner = arm.type };
    }
    return found;
}

/// The union a type named to scripts has `t` as an arm's payload of.
pub fn unionOf(vm: *const Vm, t: *const reflect.Type) ?*const reflect.Type {
    for (vm.named_types.values()) |u| {
        if (u.kind != .@"union") continue;
        for (u.fields()) |arm| if (arm.type.same(t)) return u;
    }
    return null;
}

/// Whether a value of `t` may have members the compiler cannot know, the
/// host finding them as the script runs: see `Vm.declareOpen`.
pub fn open(vm: *const Vm, t: *const reflect.Type) bool {
    for (vm.open_types.items) |o| if (o.same(t)) return true;
    return false;
}

/// The arms of the union `u` whose payloads have a field `name`, as many as
/// fit: where a script reading it is told to ask with `is` first.
pub fn armsWith(u: *const reflect.Type, name: []const u8, into: [][]const u8) [][]const u8 {
    var n: usize = 0;
    for (u.fields()) |arm| {
        if (arm.type.kind != .@"struct" or arm.type.field(name) == null or n == into.len) continue;
        into[n] = nameOf(arm.type);
        n += 1;
    }
    return into[0..n];
}

/// Every member of a value of `t`, as `member` finds them, for an editor to
/// offer: `each(member)` is called with each, but those kept out of a
/// person's view.
pub fn eachMember(vm: *const Vm, t: *const reflect.Type, context: anytype, each: fn (@TypeOf(context), []const u8, Member) Allocator.Error!void) Allocator.Error!void {
    if (t.kind == .@"struct") for (t.fields()) |*f| {
        if (!hidden(f)) try each(context, f.name.slice(), .{ .field = .{ .field = f, .owner = t } });
    };
    if (t.kind == .@"union") if (t.fields().len > 0 and t.fields()[0].type.kind == .@"struct") for (t.fields()[0].type.fields()) |*f| {
        if (commonField(t, f.name.slice())) |common| if (!hidden(f)) try each(context, f.name.slice(), .{ .field = common });
    };
    for (t.methods.slice()) |*m| try each(context, m.name.slice(), .{ .method = .{ .method = m, .owner = t, .on = t } });
    if (unionOf(vm, t)) |u| for (u.methods.slice()) |*m| try each(context, m.name.slice(), .{ .method = .{ .method = m, .owner = u, .on = t } });
    for (vm.extensions.items) |ext| if (ext.of.same(t)) for (ext.by.methods.slice()) |*m| {
        if (bridge.extends(vm, m, ext) and t.method(bridge.extensionName(m)) == null) {
            try each(context, bridge.extensionName(m), .{ .method = .{ .method = m, .owner = ext.by, .on = t, .extension = true } });
        }
    };
    for (vm.members.items) |*d| if (d.of.same(t)) try each(context, d.name, .{ .declared = d });
}

/// The type of a field or a declared member.
pub fn memberType(vm: *Vm, found: Member) Allocator.Error!Type {
    return switch (found) {
        .field => |f| typeOf(vm, f.field.type),
        .declared => |d| if (d.type) |b| builtin(b) else .any,
        .method => .any,
    };
}

// ---------------------------------------------------------------------------
// Signatures and what an editor shows

/// The parameters of `m` a script writes: after `self` and, for an
/// extension, the value it is called on; the VM calling it aside.
fn written(found: Method) []const reflect.Param {
    const params = found.method.type.info.function.params.slice();
    var from: usize = @intFromBool(found.method.takesSelf(found.owner));
    if (found.extension) {
        while (from < params.len and params[from].type.is(*Vm)) from += 1;
        from += 1;
    }
    return params[@min(from, params.len)..];
}

/// The method as a signature the compiler checks a call by and an editor
/// shows, made in `arena`.
pub fn signature(vm: *Vm, arena: Allocator, found: Method) Allocator.Error!*types.Signature {
    const m = found.method;
    const all = m.type.info.function.params.slice();
    const params = written(found);
    const skipped = all.len - params.len;
    const names = m.paramNames();
    const defaults = m.defaultArgs();
    const first_default = all.len - @min(defaults.len, all.len);
    // The names cover every parameter after `self`, or those a script gives.
    const self_count: usize = @intFromBool(m.takesSelf(found.owner));
    var visible: usize = 0;
    for (all[self_count..]) |p| {
        if (!p.type.is(*Vm)) visible += 1;
    }
    var shown: std.ArrayList(types.Param) = .empty;
    var seen_visible: usize = 0;
    for (all[self_count..], self_count..) |p, i| {
        if (p.type.is(*Vm)) continue;
        defer seen_visible += 1;
        if (i < skipped) continue;
        const name = if (names) |n| (if (n.len == all.len - self_count) n[i - self_count] else if (n.len == visible and seen_visible < n.len) n[seen_visible] else "") else "";
        const has_default = i >= first_default;
        const is_type = p.type.kind == .type;
        try shown.append(arena, .{
            .name = if (name.len > 0) name else try std.fmt.allocPrint(arena, "arg{d}", .{shown.items.len + 1}),
            .type = if (is_type) .any else try typeOf(vm, p.type),
            .has_default = has_default,
            .default_text = if (has_default) try defaultText(arena, defaults[i - first_default]) else null,
            .type_text = if (is_type) "type" else null,
            .type_arg = is_type,
        });
    }
    const sig = try arena.create(types.Signature);
    sig.* = .{ .params = shown.items, .ret = try resultType(vm, m, found.owner, null) };
    return sig;
}

/// A default as it would be written: `""`, `1.0`, `false`, `.linear`.
fn defaultText(arena: Allocator, d: reflect.attr.Defaults.Default) Allocator.Error![]const u8 {
    const v: reflect.Value = .initConst(d.type, d.value);
    const t = d.type;
    switch (t.kind) {
        .bool => return if (v.toBool() orelse false) "true" else "false",
        .int => return std.fmt.allocPrint(arena, "{d}", .{v.toInt(i64) orelse 0}),
        .float => {
            const x = v.toFloat(f64) orelse 0;
            if (x == @trunc(x) and @abs(x) < 1e15) return std.fmt.allocPrint(arena, "{d}.0", .{x});
            return std.fmt.allocPrint(arena, "{d}", .{x});
        },
        .@"enum" => if (v.wideInt()) |n| if (t.memberOf(@bitCast(@as(i64, @truncate(n))))) |member_| {
            return std.fmt.allocPrint(arena, ".{s}", .{member_.name.slice()});
        },
        else => if (t.isString()) if (v.toString()) |s| return std.fmt.allocPrint(arena, "\"{s}\"", .{s}),
    }
    return "...";
}

/// How a member is shown: `fn Sprite.play(name: string = "") bool`,
/// `Sprite.frame: int`.
pub fn detail(vm: *Vm, arena: Allocator, t: *const reflect.Type, name: []const u8, found: Member) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    (switch (found) {
        .method => |m| writeSignature(pool(vm), &out.writer, nameOf(t), name, try signature(vm, arena, m)),
        .field, .declared => out.writer.print("{s}.{s}: {s}", .{ nameOf(t), name, pool(vm).name(try memberType(vm, found)) }),
    }) catch return error.OutOfMemory;
    return out.written();
}

pub fn writeSignature(p: *types.Pool, w: *Writer, owner: []const u8, name: []const u8, sig: *const types.Signature) Writer.Error!void {
    try w.print("fn {s}.{s}(", .{ owner, name });
    for (sig.params, 0..) |param, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("{s}: {s}", .{ param.name, param.type_text orelse p.name(param.type) });
        if (param.default_text) |d| try w.print(" = {s}", .{d});
    }
    try w.writeByte(')');
    if (sig.ret != .void) try w.print(" {s}", .{p.name(sig.ret)});
}

/// What the host says of a member: its `attr.Doc`, or what `Vm.Options.docs`
/// says of it.
pub fn docOf(vm: *const Vm, found: Member) ?[]const u8 {
    switch (found) {
        .field => |f| return attributeDoc(f.field) orelse listed(vm, f.owner, f.field.name.slice()),
        .method => |m| return attributeDoc(m.method) orelse listed(vm, m.owner, m.method.name.slice()),
        .declared => |d| return d.doc,
    }
}

fn attributeDoc(attributes: anytype) ?[]const u8 {
    const d = attributes.attribute(reflect.attr.Doc) orelse return null;
    return d.text;
}

/// What the host's list says of `owner.name`.
pub fn listed(vm: *const Vm, owner: *const reflect.Type, name: []const u8) ?[]const u8 {
    var key: [256]u8 = undefined;
    const wanted = std.fmt.bufPrint(&key, "{s}.{s}", .{ nameOf(owner), name }) catch return null;
    return typeDoc(vm, wanted);
}

/// What the host's list says under `key`: a type's own is its name.
pub fn typeDoc(vm: *const Vm, key: []const u8) ?[]const u8 {
    const docs = vm.options.docs;
    var lo: usize = 0;
    var hi: usize = docs.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.mem.order(u8, docs[mid].key, key)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return docs[mid].text,
        }
    }
    return null;
}

/// Whether a field is kept out of a person's view: `attr.Hidden`.
pub fn hidden(f: *const reflect.Field) bool {
    return f.attribute(reflect.attr.Hidden) != null;
}
