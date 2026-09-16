// SPDX-License-Identifier: BSD-2-Clause

//! `const json = @import("json");`: JSON through fluxion-json, into and out
//! of Flux values.

const std = @import("std");
const fjson = @import("fluxion_json");

const Vm = @import("../vm/Vm.zig");
const Value = @import("../vm/value.zig").Value;
const object = @import("../vm/object.zig");
const make = @import("../vm/make.zig");
const format = @import("../vm/format.zig");
const native = @import("native.zig");
const Error = native.Error;

pub fn install(vm: *Vm) std.mem.Allocator.Error!void {
    const m = try make.module(vm, try vm.intern("json"));
    try vm.native_modules.put(vm.gpa, try vm.gpa.dupe(u8, "json"), m);
    m.state = .ready;
    try native.function(vm, m, "parse", parse, 1, 1);
    try native.function(vm, m, "stringify", stringify, 1, 2);
}

fn parse(vm: *Vm, args: []Value) Error!Value {
    const source = try native.bytes(vm, args, 0);
    var diagnostics: fjson.Diagnostics = .{};
    var doc = fjson.parse(vm.gpa, source, .{ .diagnostics = &diagnostics }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            var buf: [512]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            w.print("{f}", .{diagnostics}) catch {};
            return make.errorText(vm, "InvalidJson", w.buffered());
        },
    };
    defer doc.deinit();
    return toFlux(vm, doc.root, 0);
}

fn toFlux(vm: *Vm, v: fjson.Value, depth: u32) Error!Value {
    if (depth > 512) return vm.fail("the JSON is nested too deeply", .{});
    switch (v) {
        .null => return .null,
        .bool => |b| return .boolean(b),
        .int => |i| return .int(i),
        .float => |f| return .float(f),
        .string => |s| return vm.string(s),
        .array => |a| {
            const l = try make.list(vm, a.items().len, .any);
            const lv: Value = .fromObj(.list, &l.obj);
            try vm.pushRoot(lv);
            defer vm.popRoot();
            for (a.items()) |item| {
                const x = try toFlux(vm, item, depth + 1);
                l.items.appendAssumeCapacity(x);
                vm.heap.barrier(&l.obj, x);
            }
            return lv;
        },
        .object => |o| {
            const m = try make.map(vm, .any, .any);
            const mv: Value = .fromObj(.map, &m.obj);
            try vm.pushRoot(mv);
            defer vm.popRoot();
            for (o.keys()) |key| {
                const k = try vm.string(key);
                try vm.pushRoot(k);
                defer vm.popRoot();
                const x = try toFlux(vm, o.get(key), depth + 1);
                m.table.put(vm.gpa, k, x) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.NanKey => unreachable,
                };
                vm.heap.barrier(&m.obj, k);
                vm.heap.barrier(&m.obj, x);
            }
            return mv;
        },
    }
}

const Failure = error{ Unsupported, TooDeep } || fjson.Writer.Error;

fn emit(w: *fjson.Writer, v: Value, depth: u32, what: *[]const u8) Failure!void {
    if (depth > 256) return error.TooDeep;
    switch (v.tag) {
        .null => try w.writeNull(),
        .bool => try w.writeBool(v.asBool()),
        .int => try w.writeInt(v.asInt()),
        .float => try w.writeFloat(v.asFloat()),
        .string => try w.writeString(v.as(object.String).bytes()),
        .vec2, .vec3 => {
            try w.beginArray();
            const n: usize = if (v.tag == .vec2) 2 else 3;
            const xyz = v.asVec3();
            for (0..n) |i| try w.writeFloat(if (v.tag == .vec2) v.asVec2()[i] else xyz[i]);
            try w.endArray();
        },
        .color => {
            try w.beginArray();
            for (v.as(object.Color).rgba) |c| try w.writeFloat(c);
            try w.endArray();
        },
        .enum_value => try w.writeString(object.EnumType.from(v.obj()).members[v.extra].bytes()),
        .list => {
            try w.beginArray();
            for (v.as(object.List).items.items) |item| try emit(w, item, depth + 1, what);
            try w.endArray();
        },
        .map => {
            try w.beginObject();
            var it = v.as(object.Map).table.iterator();
            var buf: [64]u8 = undefined;
            while (it.next()) |e| {
                const key = if (e.key.tag == .string) e.key.as(object.String).bytes() else blk: {
                    var fixed: std.Io.Writer = .fixed(&buf);
                    format.value(&fixed, e.key, false, 0) catch {};
                    break :blk fixed.buffered();
                };
                try w.key(key);
                try emit(w, e.value, depth + 1, what);
            }
            try w.endObject();
        },
        .instance => {
            const inst = v.as(object.Instance);
            try w.beginObject();
            for (inst.class.fields, inst.fields()) |f, x| {
                if (f.is_signal or f.host) continue;
                try w.key(f.name.bytes());
                try emit(w, x, depth + 1, what);
            }
            try w.endObject();
        },
        .@"error" => try w.writeString(v.as(object.ErrorValue).name.bytes()),
        else => {
            what.* = @import("../vm/types.zig").typeName(v);
            return error.Unsupported;
        },
    }
}

fn stringify(vm: *Vm, args: []Value) Error!Value {
    const indent: u8 = if (args.len > 1) @intCast(std.math.clamp(try native.int(vm, args, 1), 0, 16)) else 0;
    var out: std.Io.Writer.Allocating = .init(vm.gpa);
    defer out.deinit();
    var w: fjson.Writer = .init(&out.writer, .{ .indent = indent });
    var what: []const u8 = "";
    emit(&w, args[0], 0, &what) catch |err| switch (err) {
        error.Unsupported => return vm.fail("json.stringify() cannot write {s}", .{what}),
        error.TooDeep => return vm.fail("json.stringify(): the value is nested too deeply, or holds itself", .{}),
        else => return error.OutOfMemory,
    };
    return vm.string(out.written());
}
