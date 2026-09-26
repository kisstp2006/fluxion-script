// SPDX-License-Identifier: BSD-2-Clause

//! The C API of `include/fluxion_script.h`. Its functions are exported, so
//! they are in a binary once something reaches this file:
//! `comptime { _ = flux.c; }`.

const std = @import("std");
const builtin = @import("builtin");

const Vm = @import("vm/Vm.zig");
const Value = @import("vm/value.zig").Value;
const object = @import("vm/object.zig");
const make = @import("vm/make.zig");
const access = @import("vm/access.zig");
const format = @import("vm/format.zig");
const native = @import("lib/native.zig");
const api = @import("api.zig");

const Status = enum(c_int) { ok = 0, compile_error = 1, panic = 2, out_of_memory = 3, not_found = 4, busy = 5 };

const WriteFn = *const fn (user: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void;
const NativeFn = *const fn (vm: *CVm, args: [*]const Value, nargs: usize, result: *Value, user: ?*anyopaque) callconv(.c) Status;

/// What a `flux_vm *` points at: the VM, and what the C side needs beside
/// it - where `print` goes, and the text `flux_error` hands out.
const CVm = struct {
    vm: *Vm,
    write: ?WriteFn = null,
    write_user: ?*anyopaque = null,
    writer: std.Io.Writer,
    error_text: std.ArrayList(u8) = .empty,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *CVm = @alignCast(@fieldParentPtr("writer", w));
        const write = self.write orelse {
            var n: usize = 0;
            for (data[0 .. data.len - 1]) |d| n += d.len;
            return n + data[data.len - 1].len * splat;
        };
        if (w.end > 0) {
            write(self.write_user, w.buffer.ptr, w.end);
            w.end = 0;
        }
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            write(self.write_user, d.ptr, d.len);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| write(self.write_user, last.ptr, last.len);
        return n + last.len * splat;
    }
};

/// What the library allocates with: libc's when the program links it, as
/// a C program's own allocations are; on WebAssembly the module's memory;
/// else Zig's allocator for many threads.
const gpa = if (builtin.link_libc)
    std.heap.c_allocator
else if (builtin.cpu.arch.isWasm())
    std.heap.wasm_allocator
else
    std.heap.smp_allocator;

fn statusOf(err: anyerror) Status {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.CompileFailed => .compile_error,
        error.Panic => .panic,
        error.Busy => .busy,
        else => .panic,
    };
}

export fn flux_vm_create() ?*CVm {
    const c = gpa.create(CVm) catch return null;
    c.* = .{ .vm = undefined, .writer = .{ .vtable = &.{ .drain = CVm.drain }, .buffer = &.{} } };
    c.vm = Vm.create(gpa, .{ .out = &c.writer }) catch {
        gpa.destroy(c);
        return null;
    };
    c.vm.host = c;
    return c;
}

export fn flux_vm_destroy(c: *CVm) void {
    c.vm.destroy();
    c.error_text.deinit(gpa);
    gpa.destroy(c);
}

export fn flux_vm_set_output(c: *CVm, write: ?WriteFn, user: ?*anyopaque) void {
    c.write = write;
    c.write_user = user;
}

export fn flux_load(c: *CVm, name: [*:0]const u8, source: [*]const u8, len: usize, out: ?**object.Module) Status {
    c.vm.clearPanic();
    const m = c.vm.load(std.mem.span(name), source[0..len]) catch |err| return statusOf(err);
    if (out) |o| o.* = m;
    return .ok;
}

export fn flux_reload(c: *CVm, m: *object.Module, source: [*]const u8, len: usize) Status {
    c.vm.clearPanic();
    _ = c.vm.reload(m, source[0..len]) catch |err| return statusOf(err);
    return .ok;
}

export fn flux_error(c: *CVm, len: ?*usize) [*:0]const u8 {
    c.error_text.clearRetainingCapacity();
    var out: std.Io.Writer.Allocating = .fromArrayList(gpa, &c.error_text);
    if (c.vm.panic != null) {
        c.vm.writePanic(&out.writer, .{}) catch {};
    } else if (c.vm.diagnostics.items.items.len > 0) {
        c.vm.writeDiagnostics(&out.writer, .{}) catch {};
    }
    out.writer.writeByte(0) catch {};
    c.error_text = out.toArrayList();
    if (c.error_text.items.len == 0) return "";
    if (len) |l| l.* = c.error_text.items.len - 1;
    return @ptrCast(c.error_text.items.ptr);
}

export fn flux_get(c: *CVm, m: *object.Module, name: [*:0]const u8, out: *Value) Status {
    out.* = c.vm.get(m, std.mem.span(name)) orelse return .not_found;
    return .ok;
}

export fn flux_call(c: *CVm, callee: Value, args: ?[*]const Value, nargs: usize, result: ?*Value) Status {
    c.vm.clearPanic();
    const list: []const Value = if (args) |a| a[0..nargs] else &.{};
    const r = c.vm.call(callee, list) catch |err| return statusOf(err);
    if (result) |p| p.* = r;
    return .ok;
}

export fn flux_update(c: *CVm, dt: f64) Status {
    c.vm.update(dt) catch |err| return statusOf(err);
    return .ok;
}

export fn flux_hold(c: *CVm, v: Value) Status {
    c.vm.hold(v) catch return .out_of_memory;
    return .ok;
}

export fn flux_release(c: *CVm, v: Value) void {
    c.vm.release(v);
}

fn trampoline(vm: *Vm, args: []Value) Vm.Error!Value {
    const n = vm.current_native.?;
    const f: NativeFn = @ptrCast(@alignCast(n.data.?));
    const c: *CVm = @ptrCast(@alignCast(vm.host.?));
    var result: Value = .null;
    return switch (f(c, args.ptr, args.len, &result, n.user)) {
        .ok => result,
        .panic => if (vm.panic != null) error.Panic else vm.fail("`{s}` failed", .{n.name}),
        .out_of_memory => error.OutOfMemory,
        else => vm.fail("`{s}` failed", .{n.name}),
    };
}

export fn flux_define(c: *CVm, name: [*:0]const u8, f: NativeFn, min_args: c_int, max_args: c_int, user: ?*anyopaque) Status {
    const vm = c.vm;
    const text = std.mem.span(name);
    native.define(vm, text, trampoline, @intCast(std.math.clamp(min_args, 0, 255)), if (max_args < 0) null else @intCast(@min(max_args, 255))) catch return .out_of_memory;
    const key = vm.interned.find(text, @import("vm/strings.zig").hashBytes(text)).?;
    const n = vm.prelude.get(key).?.as(object.Native);
    n.data = @ptrCast(f);
    n.user = user;
    return .ok;
}

export fn flux_fail(c: *CVm, message: [*:0]const u8) Status {
    _ = c.vm.fail("{s}", .{std.mem.span(message)}) catch {};
    return .panic;
}

export fn flux_null() Value {
    return .null;
}

export fn flux_bool(b: bool) Value {
    return .boolean(b);
}

export fn flux_int(i: i64) Value {
    return .int(i);
}

export fn flux_float(f: f64) Value {
    return .float(f);
}

export fn flux_vec2(x: f32, y: f32) Value {
    return .vec2(x, y);
}

export fn flux_vec3(x: f32, y: f32, z: f32) Value {
    return .vec3(x, y, z);
}

export fn flux_string(c: *CVm, bytes: [*]const u8, len: usize, out: *Value) Status {
    out.* = c.vm.string(bytes[0..len]) catch return .out_of_memory;
    return .ok;
}

export fn flux_type_of(v: Value) c_int {
    return switch (v.tag) {
        .null, .bool, .int, .float, .vec2, .vec3 => @intCast(@intFromEnum(v.tag)),
        .enum_value => 6,
        .string => 8,
        .list => 9,
        .map => 10,
        .@"error" => 20,
        .instance => 11,
        .function, .native, .method => 12,
        else => 255,
    };
}

export fn flux_as_bool(v: Value) bool {
    return v.tag == .bool and v.raw != 0;
}

export fn flux_as_int(v: Value) i64 {
    return switch (v.tag) {
        .int => v.asInt(),
        .float => if (std.math.isFinite(v.asFloat()) and @abs(v.asFloat()) < 9.2e18) @intFromFloat(v.asFloat()) else 0,
        else => 0,
    };
}

export fn flux_as_float(v: Value) f64 {
    return v.toFloat() orelse 0;
}

export fn flux_as_vec2(v: Value, out: *[2]f32) void {
    out.* = if (v.tag == .vec2 or v.tag == .vec3) v.asVec2() else .{ 0, 0 };
}

export fn flux_as_vec3(v: Value, out: *[3]f32) void {
    out.* = if (v.tag == .vec3) v.asVec3() else if (v.tag == .vec2) .{ v.asVec2()[0], v.asVec2()[1], 0 } else .{ 0, 0, 0 };
}

export fn flux_as_string(v: Value, len: ?*usize) ?[*:0]const u8 {
    if (v.tag != .string) return null;
    const s = v.as(object.String);
    if (len) |l| l.* = s.len;
    return @ptrCast(s.bytes().ptr);
}

export fn flux_list_len(v: Value) usize {
    return if (v.tag == .list) v.as(object.List).items.items.len else 0;
}

export fn flux_list_get(v: Value, index: usize) Value {
    if (v.tag != .list) return .null;
    const items = v.as(object.List).items.items;
    return if (index < items.len) items[index] else .null;
}

export fn flux_list_push(c: *CVm, list: Value, item: Value) Status {
    if (list.tag != .list) return .not_found;
    const l = list.as(object.List);
    const stored = c.vm.checks.coerce(l.elem, item) orelse return flux_fail(c, "the list does not take that type");
    l.items.append(gpa, stored) catch return .out_of_memory;
    c.vm.heap.barrier(&l.obj, stored);
    return .ok;
}

export fn flux_field(c: *CVm, obj: Value, name: [*:0]const u8, out: *Value) Status {
    const vm = c.vm;
    const text = std.mem.span(name);
    if (obj.tag == .map) {
        const key = vm.string(text) catch return .out_of_memory;
        out.* = obj.as(object.Map).table.get(key) orelse return .not_found;
        return .ok;
    }
    const key = vm.intern(text) catch return .out_of_memory;
    out.* = access.getProperty(vm, obj, key, null) catch |err| {
        vm.clearPanic();
        return if (err == error.OutOfMemory) .out_of_memory else .not_found;
    };
    return .ok;
}

export fn flux_set_field(c: *CVm, obj: Value, name: [*:0]const u8, v: Value) Status {
    const vm = c.vm;
    const text = std.mem.span(name);
    if (obj.tag == .map) {
        const key = vm.string(text) catch return .out_of_memory;
        access.setIndex(vm, obj, key, v) catch |err| return statusOf(err);
        return .ok;
    }
    var target = obj;
    const key = vm.intern(text) catch return .out_of_memory;
    access.setProperty(vm, &target, key, v, null) catch |err| return statusOf(err);
    return .ok;
}

export fn flux_to_string(v: Value, buffer: ?[*]u8, size: usize) usize {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    format.value(&counter.writer, v, false, 0) catch {};
    const total: usize = @intCast(counter.fullCount());
    if (buffer) |b| if (size > 0) {
        var w: std.Io.Writer = .fixed(b[0 .. size - 1]);
        format.value(&w, v, false, 0) catch {};
        b[w.end] = 0;
    };
    return total;
}

comptime {
    std.debug.assert(@sizeOf(Value) == 16);
}
