// SPDX-License-Identifier: BSD-2-Clause

//! What the natives share: defining them, and reading their arguments with
//! a message that names the function and the argument when one is wrong.

const std = @import("std");

const Vm = @import("../vm/Vm.zig");
const Value = @import("../vm/value.zig").Value;
const object = @import("../vm/object.zig");
const make = @import("../vm/make.zig");
const types = @import("../vm/types.zig");

pub const Error = Vm.Error;
pub const Fn = object.NativeFn;

/// Natives are named by the interned string they are filed under, so a
/// name made at run time lives exactly as long as the native.
pub fn define(vm: *Vm, name: []const u8, func: Fn, min: u8, max: ?u8) std.mem.Allocator.Error!void {
    vm.heap.paused += 1;
    defer vm.heap.paused -= 1;
    const key = try vm.intern(name);
    const n = try make.native(vm, key.bytes(), func, min, max);
    try vm.prelude.put(vm.gpa, key, .fromObj(.native, &n.obj));
}

/// A method of a builtin type: the receiver is the first argument, and
/// `min`/`max` count it.
pub fn method(vm: *Vm, kind: Vm.BuiltinType, name: []const u8, func: Fn, min: u8, max: ?u8) std.mem.Allocator.Error!void {
    vm.heap.paused += 1;
    defer vm.heap.paused -= 1;
    const key = try vm.intern(name);
    const n = try make.native(vm, key.bytes(), func, min, max);
    try vm.methods.getPtr(kind).put(vm.gpa, key, .fromObj(.native, &n.obj));
}

pub fn member(vm: *Vm, m: *object.Module, name: []const u8, v: Value) std.mem.Allocator.Error!void {
    const key = try vm.intern(name);
    try m.lookup.put(vm.gpa, key, @intCast(m.globals.items.len));
    try m.globals.append(vm.gpa, v);
    try m.names.append(vm.gpa, key);
}

pub fn function(vm: *Vm, m: *object.Module, name: []const u8, func: Fn, min: u8, max: ?u8) std.mem.Allocator.Error!void {
    vm.heap.paused += 1;
    defer vm.heap.paused -= 1;
    const key = try vm.intern(name);
    const n = try make.native(vm, key.bytes(), func, min, max);
    try member(vm, m, name, .fromObj(.native, &n.obj));
}

fn current(vm: *Vm) []const u8 {
    return if (vm.current_native) |n| n.name else "this function";
}

pub fn wrong(vm: *Vm, index: usize, wanted: []const u8, got: Value) Error {
    @branchHint(.cold);
    return vm.fail("argument {d} of `{s}` must be {s}, not {s}", .{ index + 1, current(vm), wanted, types.typeName(got) });
}

pub fn int(vm: *Vm, args: []const Value, i: usize) Error!i64 {
    const v = args[i];
    if (v.tag == .int) return v.asInt();
    return wrong(vm, i, "an int", v);
}

pub fn float(vm: *Vm, args: []const Value, i: usize) Error!f64 {
    return args[i].toFloat() orelse wrong(vm, i, "a number", args[i]);
}

pub fn boolean(vm: *Vm, args: []const Value, i: usize) Error!bool {
    if (args[i].tag == .bool) return args[i].asBool();
    return wrong(vm, i, "a bool", args[i]);
}

pub fn string(vm: *Vm, args: []const Value, i: usize) Error!*object.String {
    if (args[i].tag == .string) return args[i].as(object.String);
    return wrong(vm, i, "a string", args[i]);
}

pub fn bytes(vm: *Vm, args: []const Value, i: usize) Error![]const u8 {
    return (try string(vm, args, i)).bytes();
}

pub fn list(vm: *Vm, args: []const Value, i: usize) Error!*object.List {
    if (args[i].tag == .list) return args[i].as(object.List);
    return wrong(vm, i, "a list", args[i]);
}

pub fn map(vm: *Vm, args: []const Value, i: usize) Error!*object.Map {
    if (args[i].tag == .map) return args[i].as(object.Map);
    return wrong(vm, i, "a map", args[i]);
}

pub fn callable(vm: *Vm, args: []const Value, i: usize) Error!Value {
    return switch (args[i].tag) {
        .function, .native, .method => args[i],
        else => wrong(vm, i, "a function", args[i]),
    };
}

pub fn vec2(vm: *Vm, args: []const Value, i: usize) Error![2]f32 {
    if (args[i].tag == .vec2) return args[i].asVec2();
    return wrong(vm, i, "a vec2", args[i]);
}

pub fn vec3(vm: *Vm, args: []const Value, i: usize) Error![3]f32 {
    if (args[i].tag == .vec3) return args[i].asVec3();
    return wrong(vm, i, "a vec3", args[i]);
}

pub fn optional(args: []const Value, i: usize) ?Value {
    return if (i < args.len) args[i] else null;
}
