// SPDX-License-Identifier: BSD-2-Clause

//! What every enum has beside what it declares: its members as a list and
//! found by name or value, and a member's name.

const std = @import("std");

const Vm = @import("../vm/Vm.zig");
const Value = @import("../vm/value.zig").Value;
const object = @import("../vm/object.zig");
const make = @import("../vm/make.zig");
const native = @import("native.zig");
const Error = native.Error;
const EnumType = object.EnumType;

pub fn install(vm: *Vm) std.mem.Allocator.Error!void {
    try native.method(vm, .enum_value, "name", name, 1, 1);
    try native.method(vm, .enum_type, "members", members, 1, 1);
    try native.method(vm, .enum_type, "from_name", fromName, 2, 2);
    try native.method(vm, .enum_type, "from_int", fromInt, 2, 2);
}

fn name(_: *Vm, args: []Value) Error!Value {
    const member = args[0];
    return .fromObj(.string, &EnumType.from(member.obj()).members[member.extra].obj);
}

fn members(vm: *Vm, args: []Value) Error!Value {
    const e = args[0].as(EnumType);
    const out = try make.list(vm, e.members.len, try vm.checks.add(vm.gpa, .{ .enum_type = e }));
    for (0..e.members.len) |i| out.items.appendAssumeCapacity(.enumValue(&e.obj, @intCast(i)));
    return .fromObj(.list, &out.obj);
}

fn fromName(vm: *Vm, args: []Value) Error!Value {
    const e = args[0].as(EnumType);
    if (args[1].tag != .string) return vm.fail("{s}.from_name takes a string", .{e.name.bytes()});
    const wanted = args[1].as(object.String).bytes();
    for (e.members, 0..) |m, i| if (std.mem.eql(u8, m.bytes(), wanted)) return .enumValue(&e.obj, @intCast(i));
    return .null;
}

fn fromInt(vm: *Vm, args: []Value) Error!Value {
    const e = args[0].as(EnumType);
    if (args[1].tag != .int) return vm.fail("{s}.from_int takes an int", .{e.name.bytes()});
    const wanted = args[1].asInt();
    for (e.values, 0..) |v, i| if (v == wanted) return .enumValue(&e.obj, @intCast(i));
    return .null;
}
