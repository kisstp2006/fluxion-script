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
    const h = try vm.alloc(object.Handle, .handle, 0);
    h.* = .{ .obj = h.obj, .value = rv, .owner = owner };
    return .fromObj(.handle, &h.obj);
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
/// anything else a handle into it.
pub fn toFlux(vm: *Vm, rv: reflect.Value, owner: Value) Error!Value {
    const t = rv.type;
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
            return toFlux(vm, inner, owner);
        },
        .pointer => {
            if (t.isString()) if (rv.toString()) |s| return vm.string(s);
            if (t.info.pointer.size == .one) {
                const pointee = rv.deref() catch return .null;
                return toFlux(vm, pointee, owner);
            }
            return handleOf(vm, rv, owner);
        },
        .slice, .array => {
            if (t.isString()) if (rv.toString()) |s| return vm.string(s);
            return handleOf(vm, rv, owner);
        },
        .@"struct" => {
            if (vectorLength(t)) |n| {
                if (n == 2) return .vec2(floatField(rv, 0), floatField(rv, 1));
                return .vec3(floatField(rv, 0), floatField(rv, 1), floatField(rv, 2));
            }
            return handleOf(vm, rv, owner);
        },
        else => return handleOf(vm, rv, owner),
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
                rv.copyFrom(v.as(object.Handle).value) catch |err| return check(vm, err, t, v);
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
                rv.copyFrom(v.as(object.Handle).value) catch |err| return check(vm, err, t, v);
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
    const rv = target(h.as(object.Handle).value);
    if (std.mem.eql(u8, name, "len") and (rv.type.kind == .slice or rv.type.kind == .array)) {
        return .int(@intCast(rv.len() catch 0));
    }
    const f = rv.field(name) catch return noField(vm, rv.type, name);
    return toFlux(vm, f, h);
}

pub fn set(vm: *Vm, h: Value, name: []const u8, v: Value) Error!void {
    const rv = target(h.as(object.Handle).value);
    const f = rv.field(name) catch return noField(vm, rv.type, name);
    return fromFlux(vm, f, v);
}

pub fn index(vm: *Vm, h: Value, i: Value) Error!Value {
    const rv = target(h.as(object.Handle).value);
    if (i.tag != .int) return vm.fail("an index is an int, not {s}", .{types.typeName(i)});
    const n = rv.len() catch return vm.fail("{s} cannot be indexed", .{rv.type.name.slice()});
    const at = i.asInt();
    if (at < 0 or at >= n) return vm.fail("index {d} is out of bounds for length {d}", .{ at, n });
    const item = rv.index(@intCast(at)) catch return vm.fail("{s} cannot be indexed", .{rv.type.name.slice()});
    return toFlux(vm, item, h);
}

/// The native that calls reflected method `m` on the handle it is given
/// first, made once per method.
pub fn method(vm: *Vm, h: Value, name: []const u8) Error!?Value {
    const rv = target(h.as(object.Handle).value);
    const m = rv.type.method(name) orelse return null;
    const gop = try vm.reflect_methods.getOrPut(vm.gpa, m);
    if (!gop.found_existing) {
        const n = make.native(vm, m.name.slice(), callMethod, 1, null) catch |err| {
            _ = vm.reflect_methods.remove(m);
            return err;
        };
        n.data = m;
        gop.value_ptr.* = n;
    }
    return .fromObj(.native, &gop.value_ptr.*.obj);
}

const max_args = 16;

fn callMethod(vm: *Vm, args: []Value) Error!Value {
    const n = vm.current_native.?;
    const m: *const reflect.Method = @ptrCast(@alignCast(n.data.?));
    const f = m.type.info.function;
    const params = f.params.slice();
    if (args.len == 0 or args[0].tag != .handle) return vm.fail("`{s}` is called on the value it belongs to", .{m.name.slice()});
    if (args.len != params.len) return vm.fail("`{s}` takes {d} argument{s}, and was given {d}", .{ m.name.slice(), params.len - 1, if (params.len == 2) "" else "s", args.len - 1 });
    if (params.len > max_args) return vm.fail("`{s}` takes too many arguments to call from a script", .{m.name.slice()});
    var storage: [max_args][64]u8 align(16) = undefined;
    var values: [max_args]reflect.Value = undefined;
    values[0] = target(args[0].as(object.Handle).value);
    for (params[1..], args[1..], 1..) |p, a, i| {
        if (a.tag == .handle and (p.type.kind == .pointer or p.type.kind == .@"struct")) {
            values[i] = target(a.as(object.Handle).value);
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
    reflect.call(m, values[0..args.len], result) catch |err| return vm.fail("`{s}` could not be called: {s}", .{ m.name.slice(), @errorName(err) });
    const r = result orelse return .null;
    if (ret.kind == .error_union) {
        const held = r.unwrap() orelse return make.errorText(vm, r.errorName() orelse "Error", null);
        return toFlux(vm, held, .null);
    }
    return toFlux(vm, r, .null);
}

pub fn format(w: *std.Io.Writer, h: *object.Handle) std.Io.Writer.Error!void {
    try w.print("{f}", .{h.value});
}
