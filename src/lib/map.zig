// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

const Vm = @import("../vm/Vm.zig");
const Value = @import("../vm/value.zig").Value;
const object = @import("../vm/object.zig");
const make = @import("../vm/make.zig");
const access = @import("../vm/access.zig");
const native = @import("native.zig");
const Map = object.Map;
const Error = native.Error;

pub fn install(vm: *Vm) std.mem.Allocator.Error!void {
    const methods = .{
        .{ "get", get, 2, 3 },           .{ "has", has, 2, 2 },
        .{ "contains", has, 2, 2 },      .{ "remove", remove, 2, 2 },
        .{ "keys", keys, 1, 1 },         .{ "values", values, 1, 1 },
        .{ "clear", clear, 1, 1 },       .{ "is_empty", isEmpty, 1, 1 },
        .{ "copy", copy, 1, 1 },         .{ "merge", merge, 2, 2 },
        .{ "set", set, 3, 3 },
    };
    inline for (methods) |m| try native.method(vm, .map, m[0], m[1], m[2], m[3]);
}

fn self(args: []Value) *Map {
    return args[0].as(Map);
}

fn get(_: *Vm, args: []Value) Error!Value {
    return self(args).table.get(args[1]) orelse (if (args.len > 2) args[2] else .null);
}

fn has(_: *Vm, args: []Value) Error!Value {
    return .boolean(self(args).table.indexOf(args[1]) != null);
}

fn remove(_: *Vm, args: []Value) Error!Value {
    return .boolean(self(args).table.remove(args[1]));
}

fn set(vm: *Vm, args: []Value) Error!Value {
    try access.setIndex(vm, args[0], args[1], args[2]);
    return .null;
}

fn collect(vm: *Vm, m: *Map, want_keys: bool) Error!Value {
    const out = try make.list(vm, m.table.count(), if (want_keys) m.key else m.value);
    var it = m.table.iterator();
    while (it.next()) |e| out.items.appendAssumeCapacity(if (want_keys) e.key else e.value);
    return .fromObj(.list, &out.obj);
}

fn keys(vm: *Vm, args: []Value) Error!Value {
    return collect(vm, self(args), true);
}

fn values(vm: *Vm, args: []Value) Error!Value {
    return collect(vm, self(args), false);
}

fn clear(_: *Vm, args: []Value) Error!Value {
    self(args).table.clear();
    return .null;
}

fn isEmpty(_: *Vm, args: []Value) Error!Value {
    return .boolean(self(args).table.count() == 0);
}

fn copy(vm: *Vm, args: []Value) Error!Value {
    const src = self(args);
    const out = try make.map(vm, src.key, src.value);
    const ov: Value = .fromObj(.map, &out.obj);
    try vm.pushRoot(ov);
    defer vm.popRoot();
    var it = src.table.iterator();
    while (it.next()) |e| out.table.put(vm.gpa, e.key, e.value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NanKey => unreachable,
    };
    return ov;
}

fn merge(vm: *Vm, args: []Value) Error!Value {
    const other = try native.map(vm, args, 1);
    var i: usize = 0;
    while (i < other.table.entries.items.len) : (i += 1) {
        const e = other.table.entries.items[i];
        if (e.key.tag == .undefined) continue;
        try access.setIndex(vm, args[0], e.key, e.value);
    }
    return .null;
}
