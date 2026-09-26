// SPDX-License-Identifier: BSD-2-Clause

//! Zig values in scripts, through fluxion-reflect: a *handle* reads and
//! writes a value's fields by name and calls the methods its type lists in
//! `reflect_methods`, converting numbers, bools, strings, enums and
//! vectors on the way. A struct of two or three `f32`s named x, y (and z)
//! comes over as a `vec2` or `vec3` - an engine's `Vec2` is the script's.
//! An enum is a Flux enum of the same name and members; a tagged union is
//! its live arm - the payload's handle, or the member naming an arm that
//! holds nothing - and a payload has the union's methods besides its own.
//!
//! A handle points at the host's memory and does not own it: the host keeps
//! the value alive as long as scripts can reach it, as with Lua's light
//! userdata. `vm.newHandle(T)` makes one the collector owns instead.

const std = @import("std");
const reflect = @import("fluxion_reflect");

const Vm = @import("vm/Vm.zig");
const Value = @import("vm/value.zig").Value;
const object = @import("vm/object.zig");
const make = @import("vm/make.zig");
const types = @import("vm/types.zig");
const native = @import("lib/native.zig");
const Error = Vm.Error;

/// A handle on the value `pointer` points at.
pub fn handle(vm: *Vm, pointer: anytype) Error!Value {
    return handleOf(vm, reflect.Value.of(pointer), .null);
}

pub fn handleOf(vm: *Vm, rv: reflect.Value, owner: Value) Error!Value {
    return handleAt(vm, rv, owner, .none);
}

/// A handle into `owner`, `step` along from it. The step is kept only when
/// the owner is looked up at each use, since then this one has to be too.
fn handleAt(vm: *Vm, rv: reflect.Value, owner: Value, step: object.Handle.Step) Error!Value {
    const h = try vm.alloc(object.Handle, .handle, 0);
    const moves = owner.tag == .handle and isLive(owner.as(object.Handle));
    h.* = .{ .obj = h.obj, .value = rv, .owner = owner, .step = if (moves) step else .none };
    return .fromObj(.handle, &h.obj);
}

/// A handle on a value the host finds again each time a script uses it -
/// a component that moves when its storage does. Every read, write, index
/// and call asks `resolver` where it is now, and one reached through it asks
/// through it; when it is gone, the script stops with a panic that says so.
pub fn liveHandle(vm: *Vm, resolver: *const object.Resolver, key: u64, t: *const reflect.Type) Error!Value {
    const now = resolver.resolve(resolver.context, key, t) orelse return vm.fail("this {s} is gone: {s}", .{ t.name.slice(), resolver.why });
    const v = try handleOf(vm, now, .null);
    const h = v.as(object.Handle);
    h.live = resolver;
    h.key = key;
    return v;
}

fn isLive(h: *const object.Handle) bool {
    return h.live != null or h.step != .none;
}

/// A type's own name, without the file it is in: what a script calls it.
pub fn nameOf(t: *const reflect.Type) []const u8 {
    const full = t.name.slice();
    const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[dot + 1 ..];
}

/// The type of what a handle holds, a pointer followed.
pub fn heldType(h: *const object.Handle) *const reflect.Type {
    return target(h.value).type;
}

/// Whether `v` is a value of the host's type `t` as a script has one: a
/// handle on one, or, for a tagged union, on one of its arms' payloads or
/// the member naming an arm that holds nothing.
pub fn isOf(v: Value, t: *const reflect.Type) bool {
    switch (v.tag) {
        .handle => {
            const held = heldType(v.as(object.Handle));
            if (held.same(t)) return true;
            if (t.kind == .@"union") for (t.fields()) |arm| if (arm.type.same(held)) return true;
            return false;
        },
        .enum_value => {
            if (t.kind != .@"union") return false;
            const tag = t.info.@"union".tag orelse return false;
            const host = object.EnumType.from(v.obj()).host orelse return false;
            return host.same(tag);
        },
        else => return false,
    }
}

/// The Flux enum a host's enum is to scripts: one for each, made when a
/// value of it first crosses, with its members' names and numbers.
pub fn enumType(vm: *Vm, t: *const reflect.Type) Error!*object.EnumType {
    return fluxEnum(vm, t, nameOf(t));
}

/// The Flux enum of a tagged union's tag, named as the union is: its arms
/// that hold nothing are its members.
pub fn tagType(vm: *Vm, u: *const reflect.Type) Error!*object.EnumType {
    return fluxEnum(vm, u.info.@"union".tag.?, nameOf(u));
}

fn fluxEnum(vm: *Vm, t: *const reflect.Type, name: []const u8) Error!*object.EnumType {
    for (vm.host_enums.items) |e| if (e.host.?.same(t)) return e;
    vm.heap.paused += 1;
    defer vm.heap.paused -= 1;
    const e = try make.enumType(vm, try vm.intern(name));
    const members = t.members();
    e.members = try vm.gpa.alloc(*object.String, members.len);
    e.values = try vm.gpa.alloc(i64, members.len);
    for (members, e.members, e.values) |m, *member_name, *number| {
        member_name.* = try vm.intern(m.name.slice());
        number.* = @bitCast(m.value);
    }
    e.host = t;
    try vm.host_enums.append(vm.gpa, e);
    return e;
}

/// The member of the host's enum `t` whose number is `n`, as a script's.
fn enumValue(vm: *Vm, t: *const reflect.Type, n: i64) Error!Value {
    const e = try enumType(vm, t);
    for (e.values, 0..) |number, i| if (number == n) return .enumValue(&e.obj, @intCast(i));
    return .int(n);
}

/// The union `rv` as a script has it: its live arm. See the top of the file.
fn armOf(vm: *Vm, rv: reflect.Value, union_handle: Value) Error!Value {
    const i = rv.activeIndex() orelse return union_handle;
    const arm = rv.type.fields()[i];
    if (arm.type.kind == .void) return armName(vm, rv.type, i);
    try vm.pushRoot(union_handle);
    defer vm.popRoot();
    const payload = rv.fieldAt(i) catch return union_handle;
    return toFluxAt(vm, payload, union_handle, .{ .field = @intCast(i) });
}

/// The member of a tagged union's tag naming its arm `i`.
fn armName(vm: *Vm, t: *const reflect.Type, i: usize) Error!Value {
    if (t.info.@"union".tag == null) return .null;
    const e = try tagType(vm, t);
    const name = try vm.intern(t.fields()[i].name.slice());
    return .enumValue(&e.obj, e.index(name) orelse return .null);
}

/// A value as a handle holds it: optionals unwrapped and a pointer to one
/// followed, as `toFlux` made the handle of it. Null when nothing is there.
fn settle(rv: reflect.Value) ?reflect.Value {
    var at = rv;
    while (true) switch (at.type.kind) {
        .optional => at = at.unwrap() orelse return null,
        .pointer => {
            if (at.type.isString() or at.type.info.pointer.size != .one) return at;
            at = at.deref() catch return null;
        },
        else => return at,
    };
}

/// Where a handle's value is now; null when it is gone.
pub fn current(h: *const object.Handle) ?reflect.Value {
    if (h.live) |r| return r.resolve(r.context, h.key, h.value.type);
    switch (h.step) {
        .none => return h.value,
        .field => |i| {
            const base = target(current(h.owner.as(object.Handle)) orelse return null);
            return settle(base.fieldAt(i) catch return null);
        },
        .element => |i| {
            const base = target(current(h.owner.as(object.Handle)) orelse return null);
            if (i >= (base.len() catch return null)) return null;
            return settle(base.index(i) catch return null);
        },
    }
}

/// `current`, or a panic that says what is gone and why.
fn resolve(vm: *Vm, h: *const object.Handle) Error!reflect.Value {
    if (current(h)) |v| return v;
    var root = h;
    while (root.live == null and root.owner.tag == .handle) root = root.owner.as(object.Handle);
    const why = if (root.live) |l| l.why else "it is not there any more";
    return vm.fail("this {s} is gone: {s}", .{ h.value.type.name.slice(), why });
}

/// A value the host has as a `fluxion_reflect.Value`, as a script's own, so
/// that the memory it came from can go right after: a host's type as the
/// host says, scalars, enums, strings and vectors converted, a slice or an
/// array as a list of its elements converted, and anything else copied into
/// a handle the collector owns. A copied struct's own pointers and slices
/// point where they did.
pub fn valueOf(vm: *Vm, rv: reflect.Value) Error!Value {
    const t = rv.type;
    if (hostType(vm, t)) |host| return host.to_script(vm, rv);
    switch (t.kind) {
        .optional => return valueOf(vm, rv.unwrap() orelse return .null),
        .pointer => {
            if (t.isString()) if (rv.toString()) |s| return vm.string(s);
            if (t.info.pointer.size == .one) return valueOf(vm, rv.deref() catch return .null);
            return listOf(vm, rv);
        },
        .slice, .array => {
            if (t.isString()) if (rv.toString()) |s| return vm.string(textOf(t, s));
            return listOf(vm, rv);
        },
        .@"struct" => {
            if (vectorLength(t) != null) return toFlux(vm, rv, .null);
            return copied(vm, rv);
        },
        .void, .bool, .int, .float, .@"enum" => return toFlux(vm, rv, .null),
        .@"union" => {
            const i = rv.activeIndex() orelse return copied(vm, rv);
            if (t.fields()[i].type.kind == .void) return armName(vm, t, i);
            const whole = try copied(vm, rv);
            return armOf(vm, whole.as(object.Handle).value, whole);
        },
        else => return copied(vm, rv),
    }
}

fn listOf(vm: *Vm, rv: reflect.Value) Error!Value {
    const n = rv.len() catch return vm.fail("a {s} cannot be handed to a script: how long it is is not known", .{rv.type.name.slice()});
    const list = try make.list(vm, n, .any);
    const lv: Value = .fromObj(.list, &list.obj);
    try vm.pushRoot(lv);
    defer vm.popRoot();
    for (0..n) |i| {
        const item = try valueOf(vm, rv.index(i) catch return vm.fail("a {s} cannot be read at {d}", .{ rv.type.name.slice(), i }));
        list.items.appendAssumeCapacity(item);
        vm.heap.barrier(&list.obj, item);
    }
    return lv;
}

fn copied(vm: *Vm, rv: reflect.Value) Error!Value {
    const t = rv.type;
    if (t.size == 0 or rv.is_bit_field) return toFlux(vm, rv, .null);
    const memory = vm.gpa.rawAlloc(t.size, .fromByteUnits(t.alignment), @returnAddress()) orelse return error.OutOfMemory;
    const from: [*]const u8 = @ptrCast(rv.ptr);
    @memcpy(memory[0..t.size], from[0..t.size]);
    const owned: reflect.Value = .init(t, @ptrCast(memory));
    const v = handleOf(vm, owned, .null) catch |err| {
        owned.destroy(vm.gpa);
        return err;
    };
    v.as(object.Handle).owned = true;
    return v;
}

/// A value of type `T` the script owns, starting at `T`'s default.
pub fn create(vm: *Vm, comptime T: type) Error!Value {
    const rv = reflect.Value.create(vm.gpa, reflect.typeOf(T)) catch return error.OutOfMemory;
    errdefer rv.destroy(vm.gpa);
    const v = try handleOf(vm, rv, .null);
    v.as(object.Handle).owned = true;
    return v;
}

pub fn vectorLength(t: *const reflect.Type) ?usize {
    if (t.kind != .@"struct") return null;
    const fields = t.fields();
    if (fields.len != 2 and fields.len != 3) return null;
    const names = [_][]const u8{ "x", "y", "z" };
    for (fields, 0..) |f, i| {
        if (!f.name.eql(names[i]) or f.type.kind != .float or f.type.size != 4) return null;
    }
    return fields.len;
}

fn floatField(rv: reflect.Value, i: usize) f32 {
    return (rv.fieldAt(i) catch return 0).toFloat(f32) orelse 0;
}

/// A reflected value as a Flux value: scalars copied, vectors made vectors,
/// a host's type as the host says, anything else a handle into it.
pub fn toFlux(vm: *Vm, rv: reflect.Value, owner: Value) Error!Value {
    return toFluxAt(vm, rv, owner, .none);
}

/// How the host has a type of its own seen, if it does. See `Vm.HostType`.
pub fn hostType(vm: *const Vm, t: *const reflect.Type) ?*const Vm.HostType {
    for (vm.options.host_types) |*host| {
        if (host.type.same(t)) return host;
    }
    return null;
}

fn toFluxAt(vm: *Vm, rv: reflect.Value, owner: Value, step: object.Handle.Step) Error!Value {
    const t = rv.type;
    if (hostType(vm, t)) |host| return host.to_script(vm, rv);
    switch (t.kind) {
        .void => return .null,
        .bool => return .boolean(rv.toBool() orelse false),
        .int => {
            if (rv.toInt(i64)) |i| return .int(i);
            return vm.fail("{s} does not fit in an int", .{t.name.slice()});
        },
        .float => return .float(rv.toFloat(f64) orelse 0),
        .@"enum" => {
            const n = rv.wideInt() orelse return .null;
            return enumValue(vm, t, @truncate(n));
        },
        .optional => {
            const inner = rv.unwrap() orelse return .null;
            return toFluxAt(vm, inner, owner, step);
        },
        .@"union" => {
            const i = rv.activeIndex() orelse return handleAt(vm, rv, owner, step);
            if (t.fields()[i].type.kind == .void) return armName(vm, t, i);
            return armOf(vm, rv, try handleAt(vm, rv, owner, step));
        },
        .pointer => {
            if (t.isString()) if (rv.toString()) |s| return vm.string(s);
            if (t.info.pointer.size == .one) {
                const pointee = rv.deref() catch return .null;
                return toFluxAt(vm, pointee, owner, step);
            }
            return handleAt(vm, rv, owner, step);
        },
        .slice, .array => {
            if (t.isString()) if (rv.toString()) |s| return vm.string(textOf(t, s));
            return handleAt(vm, rv, owner, step);
        },
        .@"struct" => {
            if (vectorLength(t)) |n| {
                if (n == 2) return .vec2(floatField(rv, 0), floatField(rv, 1));
                return .vec3(floatField(rv, 0), floatField(rv, 1), floatField(rv, 2));
            }
            return handleAt(vm, rv, owner, step);
        },
        else => return handleAt(vm, rv, owner, step),
    }
}

/// A string's text: an array of bytes - a name kept in a component - is its
/// bytes up to the first zero, which pads out the rest.
fn textOf(t: *const reflect.Type, s: []const u8) []const u8 {
    if (t.kind != .array) return s;
    return std.mem.sliceTo(s, 0);
}

fn refused(vm: *Vm, t: *const reflect.Type, v: Value) Error {
    @branchHint(.cold);
    return vm.fail("a {s} cannot be set from {s}", .{ t.name.slice(), types.typeName(v) });
}

fn check(vm: *Vm, err: reflect.Error, t: *const reflect.Type, v: Value) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ReadOnly => vm.fail("this {s} can only be read", .{t.name.slice()}),
        error.OutOfRange => vm.fail("{s} does not hold that value", .{t.name.slice()}),
        else => refused(vm, t, v),
    };
}

/// Writes a Flux value into a reflected one, converting it to the type.
pub fn fromFlux(vm: *Vm, rv: reflect.Value, v: Value) Error!void {
    const t = rv.type;
    if (hostType(vm, t)) |host| return host.from_script(vm, rv, v);
    switch (t.kind) {
        .bool => {
            if (v.tag != .bool) return refused(vm, t, v);
            rv.setBool(v.asBool()) catch |err| return check(vm, err, t, v);
        },
        .int => {
            if (v.tag != .int) return refused(vm, t, v);
            rv.setInt(v.asInt()) catch |err| return check(vm, err, t, v);
        },
        .float => {
            const f = v.toFloat() orelse return refused(vm, t, v);
            rv.setFloat(f) catch |err| return check(vm, err, t, v);
        },
        .@"enum" => {
            if (v.tag != .enum_value) return refused(vm, t, v);
            const e = object.EnumType.from(v.obj());
            const host = e.host orelse return refused(vm, t, v);
            if (!host.same(t)) return refused(vm, t, v);
            rv.setInt(e.values[v.extra]) catch |err| return check(vm, err, t, v);
        },
        .optional => {
            if (v.tag == .null) return rv.setNull() catch |err| check(vm, err, t, v);
            const inner = rv.unwrapOrInit() catch |err| return check(vm, err, t, v);
            return fromFlux(vm, inner, v);
        },
        .@"union" => {
            // An arm that holds nothing, by its member: `.borderless`. One
            // that holds something, by its payload's handle.
            if (v.tag == .enum_value and isOf(v, t)) {
                const e = object.EnumType.from(v.obj());
                const i = t.fieldIndex(e.members[v.extra].bytes()) orelse return refused(vm, t, v);
                _ = rv.activateAt(i) catch |err| return check(vm, err, t, v);
                return;
            }
            if (v.tag == .handle) {
                const from = target(try resolve(vm, v.as(object.Handle)));
                if (from.type.same(t)) {
                    rv.copyFrom(from) catch |err| return check(vm, err, t, v);
                    return;
                }
                for (t.fields(), 0..) |arm, i| if (arm.type.same(from.type)) {
                    const payload = rv.activateAt(i) catch |err| return check(vm, err, t, v);
                    payload.copyFrom(from) catch |err| return check(vm, err, t, v);
                    return;
                };
            }
            return refused(vm, t, v);
        },
        .@"struct" => {
            if (vectorLength(t)) |n| {
                if (!(v.tag == .vec2 and n == 2) and !(v.tag == .vec3 and n == 3)) return refused(vm, t, v);
                const xyz = if (v.tag == .vec2) [3]f32{ v.asVec2()[0], v.asVec2()[1], 0 } else v.asVec3();
                for (0..n) |i| (rv.fieldAt(i) catch unreachable).setFloat(xyz[i]) catch |err| return check(vm, err, t, v);
                return;
            }
            if (v.tag == .handle) {
                rv.copyFrom(try resolve(vm, v.as(object.Handle))) catch |err| return check(vm, err, t, v);
                return;
            }
            return refused(vm, t, v);
        },
        else => {
            if (v.tag == .string and t.isString()) {
                rv.setString(v.as(object.String).bytes()) catch |err| return check(vm, err, t, v);
                return;
            }
            if (v.tag == .handle) {
                rv.copyFrom(try resolve(vm, v.as(object.Handle))) catch |err| return check(vm, err, t, v);
                return;
            }
            return refused(vm, t, v);
        },
    }
}

fn noField(vm: *Vm, t: *const reflect.Type, name: []const u8) Error {
    @branchHint(.cold);
    if (t.suggest(name)) |near| return vm.fail("{s} has no field `{s}`; did you mean `{s}`?", .{ t.name.slice(), name, near });
    return vm.fail("{s} has no field `{s}`", .{ t.name.slice(), name });
}

fn target(rv: reflect.Value) reflect.Value {
    if (rv.type.kind == .pointer and rv.type.info.pointer.size == .one) return rv.deref() catch rv;
    return rv;
}

pub fn get(vm: *Vm, h: Value, name: []const u8) Error!Value {
    const rv = target(try resolve(vm, h.as(object.Handle)));
    if (std.mem.eql(u8, name, "len") and (rv.type.kind == .slice or rv.type.kind == .array)) {
        return .int(@intCast(rv.len() catch 0));
    }
    const i = rv.type.fieldIndex(name) orelse {
        if (vm.options.host_member) |hook| if (try hook(vm, h, name)) |v| return v;
        return noField(vm, rv.type, name);
    };
    const f = rv.fieldAt(i) catch return noField(vm, rv.type, name);
    return toFluxAt(vm, f, h, .{ .field = @intCast(i) });
}

pub fn set(vm: *Vm, h: Value, name: []const u8, v: Value) Error!void {
    const rv = target(try resolve(vm, h.as(object.Handle)));
    // A field with a setter is written through it: the change has more to
    // do than be stored.
    if (rv.type.field(name)) |field| if (field.attribute(reflect.attr.Setter)) |setter| {
        const m = rv.type.method(setter.method) orelse return vm.fail("{s}.{s} is written through `{s}`, which a script cannot call", .{ rv.type.name.slice(), name, setter.method });
        _ = try invoke(vm, m, &.{ h, v }, 0);
        return;
    };
    const f = rv.field(name) catch {
        if (vm.options.host_set_member) |hook| if (try hook(vm, h, name, v)) return;
        return noField(vm, rv.type, name);
    };
    return fromFlux(vm, f, v);
}

pub fn index(vm: *Vm, h: Value, i: Value) Error!Value {
    const rv = target(try resolve(vm, h.as(object.Handle)));
    if (i.tag != .int) return vm.fail("an index is an int, not {s}", .{types.typeName(i)});
    const n = rv.len() catch return vm.fail("{s} cannot be indexed", .{rv.type.name.slice()});
    const at = i.asInt();
    if (at < 0 or at >= n) return vm.fail("index {d} is out of bounds for length {d}", .{ at, n });
    const item = rv.index(@intCast(at)) catch return vm.fail("{s} cannot be indexed", .{rv.type.name.slice()});
    return toFluxAt(vm, item, h, .{ .element = @intCast(at) });
}

/// The native that calls the reflected method `name` on the handle it is
/// given first, made once per method: one of the handle's type, of the
/// union whose arm it is, or one another type gives it (see `extend`).
pub fn method(vm: *Vm, h: Value, name: []const u8) Error!?Value {
    const held = heldType(h.as(object.Handle));
    if (held.method(name) orelse unionMethod(h.as(object.Handle), name)) |m| return try nativeFor(vm, m, &vm.reflect_methods, callMethod, null);
    for (vm.extensions.items) |ext| {
        if (!ext.of.same(held)) continue;
        const m = extensionMethod(vm, ext, name) orelse continue;
        return try nativeFor(vm, m, &vm.extension_methods, callExtension, ext);
    }
    return null;
}

fn nativeFor(vm: *Vm, m: *const reflect.Method, natives: *std.AutoHashMapUnmanaged(*const reflect.Method, *object.Native), call: object.NativeFn, ext: ?*Vm.Extension) Error!Value {
    if (natives.get(m)) |n| return .fromObj(.native, &n.obj);
    // Made before it goes in the map: making it can start a collection, and
    // the collector marks every entry there.
    const n = try make.native(vm, m.name.slice(), call, 1, null);
    n.data = m;
    n.user = ext;
    try natives.put(vm.gpa, m, n);
    return .fromObj(.native, &n.obj);
}

/// A method of the union whose arm's payload `h` is on.
fn unionMethod(h: *const object.Handle, name: []const u8) ?*const reflect.Method {
    if (h.owner.tag != .handle) return null;
    const whole = heldType(h.owner.as(object.Handle));
    if (whole.kind != .@"union") return null;
    return whole.method(name);
}

/// Where a script calls a method: the value it is on, or the union whose
/// arm that value is, whichever the method belongs to.
fn selfOf(vm: *Vm, m: *const reflect.Method, h: *const object.Handle) Error!reflect.Value {
    var at = h;
    while (true) {
        const rv = target(try resolve(vm, at));
        if (m.takesSelf(rv.type) or at.owner.tag != .handle) return rv;
        at = at.owner.as(object.Handle);
    }
}

/// A method of `ext.by` that the values of `ext.of` have: see `extend`.
pub fn extensionMethod(vm: *const Vm, ext: *const Vm.Extension, name: []const u8) ?*const reflect.Method {
    for (ext.by.methods.slice()) |*m| {
        if (std.mem.eql(u8, extensionName(m), name) and extends(vm, m, ext)) return m;
    }
    return null;
}

/// What a method is called on the values it is given to: its `Alias`, or
/// its own name.
pub fn extensionName(m: *const reflect.Method) []const u8 {
    if (m.attribute(Alias)) |a| return a.name;
    return m.name.slice();
}

/// Whether `m` of `ext.by` is given to the values of `ext.of`: the first
/// argument a script would give it is one.
pub fn extends(vm: *const Vm, m: *const reflect.Method, ext: *const Vm.Extension) bool {
    const params = m.type.info.function.params.slice();
    const from: usize = @intFromBool(m.takesSelf(ext.by));
    for (params[@min(from, params.len)..]) |p| {
        if (p.type.is(*Vm)) continue;
        const t = if (p.type.kind == .pointer and p.type.info.pointer.size == .one) p.type.info.pointer.child else p.type;
        if (t.same(ext.of)) return true;
        const host = hostType(vm, t) orelse return false;
        return if (host.script) |s| s.same(ext.of) else false;
    }
    return false;
}

/// The name a method of another type's is given as when it is one of a
/// value's own: `.parentOf = .{ flux.Alias{ .name = "parent" } }` makes
/// `app.parentOf(e)` `e.parent()`. See `Vm.extend`.
pub const Alias = struct { name: []const u8 };

/// What a method that gives back a `flux.Value` gives - a string it made, a
/// handle the collector owns - for the compiler to know it by:
/// `.config = .{ flux.Returns.of(Config) }`, `.nextFrame = .{
/// flux.Returns{ .builtin = .signal } }`. A `?flux.Value` is one of them or
/// null.
pub const Returns = union(enum) {
    type: *const reflect.Type,
    builtin: Vm.BuiltinType,

    pub fn of(comptime T: type) Returns {
        return .{ .type = reflect.typeOf(T) };
    }
};

/// Said of a method, or of a type for all its methods, whose errors a
/// script is given as values, to `catch`: a file that is not there. Without
/// it, an error from a method stops the script, with the error's name, as a
/// mistake in the script would.
pub const GivesErrors = struct {};

/// Whether an error of `m`, called on a value of `owner`, is a value to a
/// script: see `GivesErrors`.
pub fn givesErrors(m: *const reflect.Method, owner: *const reflect.Type) bool {
    return m.attribute(GivesErrors) != null or owner.attribute(GivesErrors) != null;
}

const max_args = 16;

/// Calls a reflected method with the script's arguments. A parameter of type
/// `*flux.Vm` is not the script's to give: it is the VM calling. A
/// parameter of type `flux.Value` is given the script's value as it is - a
/// function to call later, a list - and a result of that type goes back as
/// it is, so a method can hand a script what only it can make - a handle on
/// a value it found by name.
fn callMethod(vm: *Vm, args: []Value) Error!Value {
    const n = vm.current_native.?;
    const m: *const reflect.Method = @ptrCast(@alignCast(n.data.?));
    return invoke(vm, m, args, 0);
}

/// A method of another type's called on a value it is given to: on the
/// value `extend` was given, with the script's value first.
fn callExtension(vm: *Vm, args: []Value) Error!Value {
    const n = vm.current_native.?;
    const m: *const reflect.Method = @ptrCast(@alignCast(n.data.?));
    const ext: *const Vm.Extension = @ptrCast(@alignCast(n.user.?));
    if (args.len + 1 > max_args) return vm.fail("`{s}` takes too many arguments to call from a script", .{m.name.slice()});
    var all: [max_args]Value = undefined;
    all[0] = ext.receiver;
    @memcpy(all[1 .. args.len + 1], args);
    return invoke(vm, m, all[0 .. args.len + 1], 1);
}

/// Calls `m` with `args`, the first the value it belongs to. The last
/// arguments may be left out when the method gives them defaults
/// (`attr.defaults`): those are filled in. `implicit` of the arguments
/// after the first were not the script's to write, as an extension's value.
fn invoke(vm: *Vm, m: *const reflect.Method, args: []const Value, implicit: usize) Error!Value {
    const f = m.type.info.function;
    const params = f.params.slice();
    if (args.len == 0 or args[0].tag != .handle) return vm.fail("`{s}` is called on the value it belongs to", .{m.name.slice()});
    var wanted: usize = 0;
    for (params[1..]) |p| {
        if (!p.type.is(*Vm)) wanted += 1;
    }
    const defaults = m.defaultArgs();
    const least = wanted -| defaults.len;
    const given = args.len - 1;
    if (given < least or given > wanted) {
        const most = wanted - implicit;
        const fewest = least -| implicit;
        const written = given - implicit;
        if (fewest == most) return vm.fail("`{s}` takes {d} argument{s}, and was given {d}", .{ m.name.slice(), most, if (most == 1) "" else "s", written });
        return vm.fail("`{s}` takes {d} to {d} arguments, and was given {d}", .{ m.name.slice(), fewest, most, written });
    }
    if (params.len > max_args) return vm.fail("`{s}` takes too many arguments to call from a script", .{m.name.slice()});
    var storage: [max_args][64]u8 align(16) = undefined;
    var values: [max_args]reflect.Value = undefined;
    values[0] = try selfOf(vm, m, args[0].as(object.Handle));
    var next: usize = 1;
    for (params[1..], 1..) |p, i| {
        if (p.type.is(*Vm)) {
            values[i] = .init(p.type, &storage[i]);
            @as(**Vm, @ptrCast(&storage[i])).* = vm;
            continue;
        }
        if (next == args.len) {
            // Not given: the method's default for it, the last parameters
            // being the ones that have them.
            const first_defaulted = params.len - defaults.len;
            if (i < first_defaulted or p.type.size > 64) return vm.fail("argument {d} of `{s}` was not given", .{ i, m.name.slice() });
            const d = defaults[i - first_defaulted];
            values[i] = .init(p.type, &storage[i]);
            @memcpy(storage[i][0..p.type.size], @as([*]const u8, @ptrCast(d.value))[0..p.type.size]);
            continue;
        }
        const a = args[next];
        next += 1;
        if (p.type.is(Value)) {
            values[i] = .init(p.type, &storage[i]);
            @as(*Value, @ptrCast(@alignCast(&storage[i]))).* = a;
            continue;
        }
        if (p.type.kind == .type) {
            // A type the script names: `entity.get(Sprite)`.
            if (a.tag != .host_type) return vm.fail("argument {d} of `{s}` is a type, such as a component's name, and is given {s}", .{ i - implicit, m.name.slice(), types.typeName(a) });
            values[i] = .init(p.type, &storage[i]);
            @as(**const reflect.Type, @ptrCast(@alignCast(&storage[i]))).* = a.asHostType();
            continue;
        }
        if (a.tag == .handle and hostType(vm, p.type) == null and (p.type.kind == .pointer or p.type.kind == .@"struct")) {
            values[i] = target(try resolve(vm, a.as(object.Handle)));
            continue;
        }
        if (p.type.size > 64) return vm.fail("argument {d} of `{s}` is too large to pass from a script", .{ i, m.name.slice() });
        values[i] = .init(p.type, &storage[i]);
        @memset(storage[i][0..p.type.size], 0);
        try fromFlux(vm, values[i], a);
    }
    const ret = f.return_type;
    var result_storage: [64]u8 align(16) = undefined;
    const result: ?reflect.Value = if (ret.kind == .void or ret.size == 0) null else if (ret.size <= 64) .init(ret, &result_storage) else return vm.fail("`{s}` returns a value too large for a script", .{m.name.slice()});
    reflect.call(m, values[0..params.len], result) catch |err| return vm.fail("`{s}` could not be called: {s}", .{ m.name.slice(), @errorName(err) });
    const r = result orelse return .null;
    if (ret.kind == .error_union) {
        const held = r.unwrap() orelse {
            const name = r.errorName() orelse "Error";
            // A method given the VM stops the script the way a native does.
            if (vm.panic != null and std.mem.eql(u8, name, "Panic")) return error.Panic;
            if (std.mem.eql(u8, name, "OutOfMemory")) return error.OutOfMemory;
            if (givesErrors(m, values[0].type)) return make.errorText(vm, name, null);
            return vm.fail("`{s}` failed: error.{s}", .{ m.name.slice(), name });
        };
        return resultOf(vm, held);
    }
    return resultOf(vm, r);
}

/// A method's result as a script's value. The result is in the call's own
/// storage, which is gone once the call returns: a value is copied out, as
/// `valueOf` copies, and only what a pointer leads to - the host's memory,
/// which stays - is handed over as a handle into it. A `flux.Value` is
/// the script's already.
fn resultOf(vm: *Vm, r: reflect.Value) Error!Value {
    var at = r;
    while (at.type.kind == .optional) at = at.unwrap() orelse return .null;
    if (at.get(Value)) |v| return v;
    const t = at.type;
    if (t.kind == .pointer and t.info.pointer.size == .one) return toFlux(vm, at, .null);
    return valueOf(vm, at);
}

pub fn format(w: *std.Io.Writer, h: *object.Handle) std.Io.Writer.Error!void {
    const now = current(h) orelse return w.print("<{s}, gone>", .{h.value.type.name.slice()});
    try w.print("{f}", .{now});
}
