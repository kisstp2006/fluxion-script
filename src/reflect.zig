// SPDX-License-Identifier: BSD-2-Clause

//! Zig values in scripts, through fluxion-reflect: a *handle* reads and
//! writes a value's fields by name and calls the methods its type lists in
//! `reflect_methods`, converting numbers, bools, strings, enums and
//! vectors on the way. A struct of two or three `f32`s named x, y (and z)
//! comes over as a `vec2` or `vec3` - an engine's `Vec2` is the script's.
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
            if (t.isString()) if (rv.toString()) |s| return vm.string(s);
            return listOf(vm, rv);
        },
        .@"struct" => {
            if (vectorLength(t) != null) return toFlux(vm, rv, .null);
            return copied(vm, rv);
        },
        .void, .bool, .int, .float, .@"enum" => return toFlux(vm, rv, .null),
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

fn vectorLength(t: *const reflect.Type) ?usize {
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
fn hostType(vm: *const Vm, t: *const reflect.Type) ?*const Vm.HostType {
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
            if (t.memberOf(@bitCast(@as(i64, @truncate(n))))) |m| return vm.string(m.name.slice());
            return .int(@truncate(n));
        },
        .optional => {
            const inner = rv.unwrap() orelse return .null;
            return toFluxAt(vm, inner, owner, step);
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
            if (t.isString()) if (rv.toString()) |s| return vm.string(s);
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
        .@"enum" => switch (v.tag) {
            .string => {
                const m = t.member(v.as(object.String).bytes()) orelse
                    return vm.fail("{s} has no member \"{s}\"", .{ t.name.slice(), v.as(object.String).bytes() });
                rv.setInt(@as(i64, @bitCast(m.value))) catch |err| return check(vm, err, t, v);
            },
            .int => rv.setInt(v.asInt()) catch |err| return check(vm, err, t, v),
            .enum_value => {
                const e = object.EnumType.from(v.obj());
                return fromFlux(vm, rv, try vm.string(e.members[v.extra].bytes()));
            },
            else => return refused(vm, t, v),
        },
        .optional => {
            if (v.tag == .null) return rv.setNull() catch |err| check(vm, err, t, v);
            const inner = rv.unwrapOrInit() catch |err| return check(vm, err, t, v);
            return fromFlux(vm, inner, v);
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
    const f = rv.field(name) catch return noField(vm, rv.type, name);
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

/// The native that calls reflected method `m` on the handle it is given
/// first, made once per method.
pub fn method(vm: *Vm, h: Value, name: []const u8) Error!?Value {
    const rv = target(h.as(object.Handle).value);
    const m = rv.type.method(name) orelse return null;
    if (vm.reflect_methods.get(m)) |n| return .fromObj(.native, &n.obj);
    // Made before it goes in the map: making it can start a collection, and
    // the collector marks every entry there.
    const n = try make.native(vm, m.name.slice(), callMethod, 1, null);
    n.data = m;
    try vm.reflect_methods.put(vm.gpa, m, n);
    return .fromObj(.native, &n.obj);
}

const max_args = 16;

/// Calls a reflected method with the script's arguments. A parameter of type
/// `*flux.Vm` is not the script's to give: it is the VM calling. A result of
/// type `flux.Value` goes back as it is, so a method can hand a script what
/// only it can make - a handle on a value it found by name.
fn callMethod(vm: *Vm, args: []Value) Error!Value {
    const n = vm.current_native.?;
    const m: *const reflect.Method = @ptrCast(@alignCast(n.data.?));
    const f = m.type.info.function;
    const params = f.params.slice();
    if (args.len == 0 or args[0].tag != .handle) return vm.fail("`{s}` is called on the value it belongs to", .{m.name.slice()});
    var wanted: usize = 0;
    for (params[1..]) |p| {
        if (!p.type.is(*Vm)) wanted += 1;
    }
    if (args.len - 1 != wanted) return vm.fail("`{s}` takes {d} argument{s}, and was given {d}", .{ m.name.slice(), wanted, if (wanted == 1) "" else "s", args.len - 1 });
    if (params.len > max_args) return vm.fail("`{s}` takes too many arguments to call from a script", .{m.name.slice()});
    var storage: [max_args][64]u8 align(16) = undefined;
    var values: [max_args]reflect.Value = undefined;
    values[0] = target(try resolve(vm, args[0].as(object.Handle)));
    var next: usize = 1;
    for (params[1..], 1..) |p, i| {
        if (p.type.is(*Vm)) {
            values[i] = .init(p.type, &storage[i]);
            @as(**Vm, @ptrCast(&storage[i])).* = vm;
            continue;
        }
        const a = args[next];
        next += 1;
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
            return make.errorText(vm, name, null);
        };
        if (held.get(Value)) |v| return v;
        return resultOf(vm, held);
    }
    if (r.get(Value)) |v| return v;
    return resultOf(vm, r);
}

/// A method's result as a script's value. The result is in the call's own
/// storage, which is gone once the call returns: a value is copied out, as
/// `valueOf` copies, and only what a pointer leads to - the host's memory,
/// which stays - is handed over as a handle into it.
fn resultOf(vm: *Vm, r: reflect.Value) Error!Value {
    var at = r;
    while (at.type.kind == .optional) at = at.unwrap() orelse return .null;
    const t = at.type;
    if (t.kind == .pointer and t.info.pointer.size == .one) return toFlux(vm, at, .null);
    return valueOf(vm, at);
}

pub fn format(w: *std.Io.Writer, h: *object.Handle) std.Io.Writer.Error!void {
    const now = current(h) orelse return w.print("<{s}, gone>", .{h.value.type.name.slice()});
    try w.print("{f}", .{now});
}
