// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

const Vm = @import("../vm/Vm.zig");
const Value = @import("../vm/value.zig").Value;
const object = @import("../vm/object.zig");
const make = @import("../vm/make.zig");
const ops = @import("../vm/ops.zig");
const access = @import("../vm/access.zig");
const format = @import("../vm/format.zig");
const call = @import("../vm/call.zig");
const native = @import("native.zig");
const List = object.List;
const Error = native.Error;

pub fn install(vm: *Vm) std.mem.Allocator.Error!void {
    const methods = .{
        .{ "push", push, 2, 2 },         .{ "append", push, 2, 2 },
        .{ "pop", pop, 1, 1 },           .{ "insert", insert, 3, 3 },
        .{ "remove", remove, 2, 2 },     .{ "remove_value", removeValue, 2, 2 },
        .{ "clear", clear, 1, 1 },       .{ "contains", contains, 2, 2 },
        .{ "index_of", indexOf, 2, 2 },  .{ "reverse", reverse, 1, 1 },
        .{ "reversed", reversed, 1, 1 }, .{ "sort", sort, 1, 1 },
        .{ "sort_by", sortBy, 2, 2 },    .{ "map", mapFn, 2, 2 },
        .{ "filter", filter, 2, 2 },     .{ "reduce", reduce, 3, 3 },
        .{ "any", any, 2, 2 },           .{ "all", all, 2, 2 },
        .{ "find", find, 2, 2 },         .{ "first", first, 1, 1 },
        .{ "last", last, 1, 1 },         .{ "is_empty", isEmpty, 1, 1 },
        .{ "copy", copy, 1, 1 },         .{ "extend", extend, 2, 2 },
        .{ "join", join, 1, 2 },         .{ "sum", sum, 1, 1 },
        .{ "count", count, 2, 2 },
    };
    inline for (methods) |m| try native.method(vm, .list, m[0], m[1], m[2], m[3]);
}

fn self(args: []Value) *List {
    return args[0].as(List);
}

fn store(vm: *Vm, l: *List, v: Value) Error!Value {
    return vm.checks.coerce(l.elem, v) orelse access.wrongType(vm, l.elem, v, "the list's element");
}

fn push(vm: *Vm, args: []Value) Error!Value {
    const l = self(args);
    const v = try store(vm, l, args[1]);
    try l.items.append(vm.gpa, v);
    vm.heap.barrier(&l.obj, v);
    return .null;
}

fn pop(_: *Vm, args: []Value) Error!Value {
    return self(args).items.pop() orelse .null;
}

fn position(vm: *Vm, l: *List, v: Value, inclusive_end: bool) Error!usize {
    if (v.tag != .int) return native.wrong(vm, 1, "an int", v);
    const len = l.items.items.len;
    const n = v.asInt();
    const at: i64 = if (n < 0) n + @as(i64, @intCast(len)) else n;
    const limit = if (inclusive_end) len + 1 else len;
    if (at < 0 or at >= limit) return vm.fail("index {d} is out of bounds for a list of length {d}", .{ n, len });
    return @intCast(at);
}

fn insert(vm: *Vm, args: []Value) Error!Value {
    const l = self(args);
    const at = try position(vm, l, args[1], true);
    const v = try store(vm, l, args[2]);
    try l.items.insert(vm.gpa, at, v);
    vm.heap.barrier(&l.obj, v);
    return .null;
}

fn remove(vm: *Vm, args: []Value) Error!Value {
    const l = self(args);
    return l.items.orderedRemove(try position(vm, l, args[1], false));
}

fn removeValue(_: *Vm, args: []Value) Error!Value {
    const l = self(args);
    for (l.items.items, 0..) |v, i| if (ops.equal(v, args[1])) {
        _ = l.items.orderedRemove(i);
        return .true;
    };
    return .false;
}

fn clear(_: *Vm, args: []Value) Error!Value {
    self(args).items.clearRetainingCapacity();
    return .null;
}

fn contains(_: *Vm, args: []Value) Error!Value {
    for (self(args).items.items) |v| if (ops.equal(v, args[1])) return .true;
    return .false;
}

fn indexOf(_: *Vm, args: []Value) Error!Value {
    for (self(args).items.items, 0..) |v, i| if (ops.equal(v, args[1])) return .int(@intCast(i));
    return .null;
}

fn reverse(_: *Vm, args: []Value) Error!Value {
    std.mem.reverse(Value, self(args).items.items);
    return .null;
}

fn copyOf(vm: *Vm, l: *List) Error!*List {
    const out = try make.list(vm, l.items.items.len, l.elem);
    out.items.appendSliceAssumeCapacity(l.items.items);
    return out;
}

fn reversed(vm: *Vm, args: []Value) Error!Value {
    const out = try copyOf(vm, self(args));
    std.mem.reverse(Value, out.items.items);
    return .fromObj(.list, &out.obj);
}

fn copy(vm: *Vm, args: []Value) Error!Value {
    return .fromObj(.list, &(try copyOf(vm, self(args))).obj);
}

const Sorter = struct {
    vm: *Vm,
    by: ?Value,
    failed: bool = false,

    fn less(s: *Sorter, a: Value, b: Value) bool {
        if (s.failed) return false;
        if (s.by) |f| {
            const r = call.call(s.vm, f, &.{ a, b }) catch {
                s.failed = true;
                return false;
            };
            if (r.tag != .bool) {
                s.failed = true;
                _ = s.vm.fail("a sort_by function returns a bool: whether its first argument goes first", .{}) catch {};
                return false;
            }
            return r.asBool();
        }
        return ops.compare(s.vm, .lt, a, b) catch {
            s.failed = true;
            return false;
        };
    }
};

/// Sorted in a copy nothing else can reach, so a comparison that changes
/// the list cannot pull the ground from under the sort; stable, as a game
/// sorting sprites by layer expects.
fn sortWith(vm: *Vm, l: *List, by: ?Value) Error!Value {
    const scratch = try copyOf(vm, l);
    try vm.pushRoot(.fromObj(.list, &scratch.obj));
    defer vm.popRoot();
    var sorter: Sorter = .{ .vm = vm, .by = by };
    std.sort.block(Value, scratch.items.items, &sorter, Sorter.less);
    if (sorter.failed) return if (vm.panic != null) error.Panic else vm.fail("the list could not be sorted", .{});
    if (l.items.items.len != scratch.items.items.len) return vm.fail("the list was changed while it was being sorted", .{});
    @memcpy(l.items.items, scratch.items.items);
    return .null;
}

fn sort(vm: *Vm, args: []Value) Error!Value {
    return sortWith(vm, self(args), null);
}

fn sortBy(vm: *Vm, args: []Value) Error!Value {
    return sortWith(vm, self(args), try native.callable(vm, args, 1));
}

fn mapFn(vm: *Vm, args: []Value) Error!Value {
    const l = self(args);
    const f = try native.callable(vm, args, 1);
    const out = try make.list(vm, l.items.items.len, .any);
    const ov: Value = .fromObj(.list, &out.obj);
    try vm.pushRoot(ov);
    defer vm.popRoot();
    var i: usize = 0;
    while (i < l.items.items.len) : (i += 1) {
        const v = try call.call(vm, f, &.{l.items.items[i]});
        try out.items.append(vm.gpa, v);
        vm.heap.barrier(&out.obj, v);
    }
    return ov;
}

fn predicate(vm: *Vm, f: Value, v: Value) Error!bool {
    const r = try call.call(vm, f, &.{v});
    if (r.tag != .bool) return vm.fail("the function given to `{s}` must return a bool, not {s}", .{ if (vm.current_native) |n| n.name else "it", @import("../vm/types.zig").typeName(r) });
    return r.asBool();
}

fn filter(vm: *Vm, args: []Value) Error!Value {
    const l = self(args);
    const f = try native.callable(vm, args, 1);
    const out = try make.list(vm, 0, l.elem);
    const ov: Value = .fromObj(.list, &out.obj);
    try vm.pushRoot(ov);
    defer vm.popRoot();
    var i: usize = 0;
    while (i < l.items.items.len) : (i += 1) {
        const v = l.items.items[i];
        if (try predicate(vm, f, v)) {
            try out.items.append(vm.gpa, v);
            vm.heap.barrier(&out.obj, v);
        }
    }
    return ov;
}

fn reduce(vm: *Vm, args: []Value) Error!Value {
    const l = self(args);
    const f = try native.callable(vm, args, 1);
    var acc = args[2];
    var i: usize = 0;
    while (i < l.items.items.len) : (i += 1) {
        try vm.pushRoot(acc);
        defer vm.popRoot();
        acc = try call.call(vm, f, &.{ acc, l.items.items[i] });
    }
    return acc;
}

fn any(vm: *Vm, args: []Value) Error!Value {
    const l = self(args);
    const f = try native.callable(vm, args, 1);
    var i: usize = 0;
    while (i < l.items.items.len) : (i += 1) if (try predicate(vm, f, l.items.items[i])) return .true;
    return .false;
}

fn all(vm: *Vm, args: []Value) Error!Value {
    const l = self(args);
    const f = try native.callable(vm, args, 1);
    var i: usize = 0;
    while (i < l.items.items.len) : (i += 1) if (!try predicate(vm, f, l.items.items[i])) return .false;
    return .true;
}

fn find(vm: *Vm, args: []Value) Error!Value {
    const l = self(args);
    const f = try native.callable(vm, args, 1);
    var i: usize = 0;
    while (i < l.items.items.len) : (i += 1) {
        const v = l.items.items[i];
        if (try predicate(vm, f, v)) return v;
    }
    return .null;
}

fn first(_: *Vm, args: []Value) Error!Value {
    const items = self(args).items.items;
    return if (items.len > 0) items[0] else .null;
}

fn last(_: *Vm, args: []Value) Error!Value {
    const items = self(args).items.items;
    return if (items.len > 0) items[items.len - 1] else .null;
}

fn isEmpty(_: *Vm, args: []Value) Error!Value {
    return .boolean(self(args).items.items.len == 0);
}

fn extend(vm: *Vm, args: []Value) Error!Value {
    const l = self(args);
    const other = try native.list(vm, args, 1);
    const extra = other.items.items;
    try l.items.ensureUnusedCapacity(vm.gpa, extra.len);
    for (0..extra.len) |i| {
        const v = try store(vm, l, other.items.items[i]);
        l.items.appendAssumeCapacity(v);
        vm.heap.barrier(&l.obj, v);
    }
    return .null;
}

fn join(vm: *Vm, args: []Value) Error!Value {
    const sep = if (args.len > 1) try native.bytes(vm, args, 1) else "";
    var out: std.Io.Writer.Allocating = .init(vm.gpa);
    defer out.deinit();
    for (self(args).items.items, 0..) |v, i| {
        if (i > 0) out.writer.writeAll(sep) catch return error.OutOfMemory;
        format.value(&out.writer, v, false, 0) catch return error.OutOfMemory;
    }
    return vm.string(out.written());
}

fn sum(vm: *Vm, args: []Value) Error!Value {
    var acc: Value = if (self(args).elem == .float) .float(0) else .int(0);
    for (self(args).items.items) |v| acc = try ops.arith(vm, .add, acc, v);
    return acc;
}

fn count(_: *Vm, args: []Value) Error!Value {
    var n: i64 = 0;
    for (self(args).items.items) |v| n += @intFromBool(ops.equal(v, args[1]));
    return .int(n);
}
