// SPDX-License-Identifier: BSD-2-Clause

//! Signals, as GDScript has them: `signal died(by: ?Actor);` in a struct,
//! `self.died.connect(f)`, `self.died.emit(x)`, and `await self.died`.

const std = @import("std");

const Vm = @import("../vm/Vm.zig");
const Value = @import("../vm/value.zig").Value;
const object = @import("../vm/object.zig");
const make = @import("../vm/make.zig");
const call = @import("../vm/call.zig");
const ops = @import("../vm/ops.zig");
const native = @import("native.zig");
const Signal = object.Signal;
const Error = native.Error;

pub fn install(vm: *Vm) std.mem.Allocator.Error!void {
    try native.method(vm, .signal, "connect", connect, 2, 2);
    try native.method(vm, .signal, "once", once, 2, 2);
    try native.method(vm, .signal, "disconnect", disconnect, 2, 2);
    try native.method(vm, .signal, "emit", emit, 1, null);
    try native.method(vm, .signal, "is_connected", isConnected, 2, 2);
    try native.method(vm, .signal, "connections", connections, 1, 1);
}

/// A new instance's signals, one of its own for each `signal` its struct
/// declares.
pub fn fill(vm: *Vm, inst: *object.Instance) Error!void {
    for (inst.class.fields, 0..) |f, i| {
        if (!f.is_signal) continue;
        const s = try make.signal(vm, f.name, @intCast(f.default.asInt()));
        const v: Value = .fromObj(.signal, &s.obj);
        inst.fields()[i] = v;
        vm.heap.barrier(&inst.obj, v);
    }
}

fn self(args: []Value) *Signal {
    return args[0].as(Signal);
}

fn add(vm: *Vm, args: []Value, is_once: bool) Error!Value {
    const s = self(args);
    const target = try native.callable(vm, args, 1);
    try s.connections.append(vm.gpa, .{ .target = target, .once = is_once });
    vm.heap.barrier(&s.obj, target);
    return .null;
}

fn connect(vm: *Vm, args: []Value) Error!Value {
    return add(vm, args, false);
}

fn once(vm: *Vm, args: []Value) Error!Value {
    return add(vm, args, true);
}

fn same(a: Value, b: Value) bool {
    if (a.tag == .method and b.tag == .method) {
        const x = a.as(object.Method);
        const y = b.as(object.Method);
        return ops.equal(x.receiver, y.receiver) and x.function.raw == y.function.raw;
    }
    return a.tag == b.tag and a.raw == b.raw;
}

fn disconnect(_: *Vm, args: []Value) Error!Value {
    const s = self(args);
    for (s.connections.items, 0..) |c, i| if (same(c.target, args[1])) {
        _ = s.connections.orderedRemove(i);
        return .true;
    };
    return .false;
}

fn isConnected(_: *Vm, args: []Value) Error!Value {
    for (self(args).connections.items) |c| if (same(c.target, args[1])) return .true;
    return .false;
}

fn connections(_: *Vm, args: []Value) Error!Value {
    return .int(@intCast(self(args).connections.items.len));
}

fn emit(vm: *Vm, args: []Value) Error!Value {
    const s = self(args);
    const payload = args[1..];
    const snapshot = try vm.gpa.dupe(object.Connection, s.connections.items);
    defer vm.gpa.free(snapshot);
    const list = try make.list(vm, snapshot.len, .any);
    const keep: Value = .fromObj(.list, &list.obj);
    for (snapshot) |c| list.items.appendAssumeCapacity(c.target);
    try vm.pushRoot(keep);
    defer vm.popRoot();
    var removed = false;
    for (snapshot) |c| {
        if (c.once) removed = true;
        _ = try call.call(vm, c.target, payload);
    }
    if (removed) {
        var i: usize = 0;
        while (i < s.connections.items.len) {
            const c = s.connections.items[i];
            var fired = false;
            for (snapshot) |x| if (x.once and same(x.target, c.target)) {
                fired = true;
            };
            if (fired and c.once) _ = s.connections.orderedRemove(i) else i += 1;
        }
    }
    if (s.waiters.items.len > 0) {
        const result: Value = switch (payload.len) {
            0 => .null,
            1 => payload[0],
            else => blk: {
                const l = try make.list(vm, payload.len, .any);
                l.items.appendSliceAssumeCapacity(payload);
                break :blk .fromObj(.list, &l.obj);
            },
        };
        try vm.pushRoot(result);
        defer vm.popRoot();
        const waiting = try make.list(vm, s.waiters.items.len, .any);
        const held: Value = .fromObj(.list, &waiting.obj);
        for (s.waiters.items) |t| waiting.items.appendAssumeCapacity(.fromObj(.task, &t.obj));
        try vm.pushRoot(held);
        defer vm.popRoot();
        s.waiters.clearRetainingCapacity();
        for (waiting.items.items) |t| try call.resumeTask(vm, t.as(object.Task), result);
    }
    return .null;
}
