// SPDX-License-Identifier: BSD-2-Clause

//! Every kind of heap object, made.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Vm = @import("Vm.zig");
const Value = @import("value.zig").Value;
const object = @import("object.zig");
const types = @import("types.zig");
const Fiber = @import("fiber.zig").Fiber;

pub fn list(vm: *Vm, capacity: usize, elem: types.Check) Allocator.Error!*object.List {
    const l = try vm.alloc(object.List, .list, 0);
    l.items = .empty;
    l.elem = elem;
    if (capacity > 0) {
        try vm.pushRoot(.fromObj(.list, &l.obj));
        defer vm.popRoot();
        try l.items.ensureTotalCapacity(vm.gpa, capacity);
    }
    return l;
}

pub fn listValue(vm: *Vm, capacity: usize) Allocator.Error!Value {
    return .fromObj(.list, &(try list(vm, capacity, .any)).obj);
}

pub fn map(vm: *Vm, key: types.Check, value: types.Check) Allocator.Error!*object.Map {
    const m = try vm.alloc(object.Map, .map, 0);
    m.* = .{ .obj = m.obj, .key = key, .value = value };
    return m;
}

pub fn mapValue(vm: *Vm) Allocator.Error!Value {
    return .fromObj(.map, &(try map(vm, .any, .any)).obj);
}

pub fn instance(vm: *Vm, cls: *object.Class) Allocator.Error!*object.Instance {
    const count = cls.fields.len;
    // At least one field's room, which a reload may need to say where the
    // fields went.
    const i = try vm.alloc(object.Instance, .instance, @max(count, 1) * @sizeOf(Value));
    i.class = cls;
    i.count = @intCast(count);
    for (cls.fields, i.fields()) |f, *slot| slot.* = f.default;
    return i;
}

pub fn proto(vm: *Vm, name: *object.String) Allocator.Error!*object.Proto {
    const p = try vm.alloc(object.Proto, .proto, 0);
    p.* = .{ .obj = p.obj, .name = name };
    return p;
}

pub fn closure(vm: *Vm, p: *object.Proto) Allocator.Error!*object.Closure {
    const count = p.upvals.len;
    const c = try vm.alloc(object.Closure, .closure, count * @sizeOf(*object.Upvalue));
    c.proto = p;
    c.count = @intCast(count);
    return c;
}

pub fn upvalue(vm: *Vm, location: *Value, frame: u32, reg: u32) Allocator.Error!*object.Upvalue {
    const u = try vm.alloc(object.Upvalue, .upvalue, 0);
    u.* = .{ .obj = u.obj, .location = location, .frame = frame, .reg = reg };
    return u;
}

pub fn native(vm: *Vm, name: []const u8, func: object.NativeFn, min: u8, max: ?u8) Allocator.Error!*object.Native {
    const n = try vm.alloc(object.Native, .native, 0);
    n.* = .{ .obj = n.obj, .func = func, .name = name, .min = min, .max = max };
    return n;
}

pub fn method(vm: *Vm, receiver: Value, function: Value) Allocator.Error!*object.Method {
    const m = try vm.alloc(object.Method, .method, 0);
    m.* = .{ .obj = m.obj, .receiver = receiver, .function = function };
    return m;
}

pub fn class(vm: *Vm, name: *object.String) Allocator.Error!*object.Class {
    const c = try vm.alloc(object.Class, .class, 0);
    c.* = .{ .obj = c.obj, .name = name };
    return c;
}

pub fn enumType(vm: *Vm, name: *object.String) Allocator.Error!*object.EnumType {
    const e = try vm.alloc(object.EnumType, .enum_type, 0);
    e.* = .{ .obj = e.obj, .name = name };
    return e;
}

pub fn module(vm: *Vm, name: *object.String) Allocator.Error!*object.Module {
    const m = try vm.alloc(object.Module, .module, 0);
    m.* = .{ .obj = m.obj, .name = name };
    return m;
}

/// Both strings must already be held somewhere the collector sees; the
/// allocation here may collect anything that is not.
pub fn errorValue(vm: *Vm, name: *object.String, message: ?*object.String) Allocator.Error!Value {
    try vm.pushRoot(.fromObj(.string, &name.obj));
    defer vm.popRoot();
    if (message) |m| try vm.pushRoot(.fromObj(.string, &m.obj));
    defer if (message != null) vm.popRoot();
    const e = try vm.alloc(object.ErrorValue, .error_value, 0);
    e.* = .{ .obj = e.obj, .name = name, .message = message };
    return .fromObj(.@"error", &e.obj);
}

/// `error.Name("message")` from Zig text, each string kept alive while the
/// next is made.
pub fn errorText(vm: *Vm, name: []const u8, message: ?[]const u8) Allocator.Error!Value {
    const n = try vm.intern(name);
    try vm.pushRoot(.fromObj(.string, &n.obj));
    defer vm.popRoot();
    const m = if (message) |text| try vm.newString(text) else null;
    return errorValue(vm, n, m);
}

pub fn signal(vm: *Vm, name: *object.String, params: u8) Allocator.Error!*object.Signal {
    const s = try vm.alloc(object.Signal, .signal, 0);
    s.* = .{ .obj = s.obj, .name = name, .params = params };
    return s;
}

pub fn task(vm: *Vm) Allocator.Error!*object.Task {
    const t = try vm.alloc(object.Task, .task, 0);
    t.* = .{ .obj = t.obj, .fiber = .init(128) };
    try vm.pushRoot(.fromObj(.task, &t.obj));
    defer vm.popRoot();
    try vm.scheduler.track(vm.gpa, t);
    return t;
}

pub fn color(vm: *Vm, rgba: [4]f32) Allocator.Error!Value {
    const c = try vm.alloc(object.Color, .color, 0);
    c.* = .{ .obj = c.obj, .rgba = rgba };
    return .fromObj(.color, &c.obj);
}
