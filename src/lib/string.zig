// SPDX-License-Identifier: BSD-2-Clause

//! String methods. Indexes count characters, as `len` does; an ASCII string
//! is indexed directly, anything else is walked.

const std = @import("std");

const Vm = @import("../vm/Vm.zig");
const Value = @import("../vm/value.zig").Value;
const object = @import("../vm/object.zig");
const make = @import("../vm/make.zig");
const types = @import("../vm/types.zig");
const native = @import("native.zig");
const String = object.String;
const Error = native.Error;

pub fn install(vm: *Vm) std.mem.Allocator.Error!void {
    const m = struct {
        fn def(v: *Vm, name: []const u8, f: native.Fn, min: u8, max: ?u8) !void {
            try native.method(v, .string, name, f, min, max);
        }
    };
    try m.def(vm, "is_empty", isEmpty, 1, 1);
    try m.def(vm, "contains", contains, 2, 2);
    try m.def(vm, "starts_with", startsWith, 2, 2);
    try m.def(vm, "ends_with", endsWith, 2, 2);
    try m.def(vm, "find", find, 2, 2);
    try m.def(vm, "count", count, 2, 2);
    try m.def(vm, "replace", replace, 3, 3);
    try m.def(vm, "split", split, 1, 2);
    try m.def(vm, "lines", lines, 1, 1);
    try m.def(vm, "trim", trim, 1, 1);
    try m.def(vm, "trim_start", trimStart, 1, 1);
    try m.def(vm, "trim_end", trimEnd, 1, 1);
    try m.def(vm, "upper", upper, 1, 1);
    try m.def(vm, "lower", lower, 1, 1);
    try m.def(vm, "repeat", repeat, 2, 2);
    try m.def(vm, "chars", chars, 1, 1);
    try m.def(vm, "bytes", bytesFn, 1, 1);
    try m.def(vm, "pad_start", padStart, 2, 3);
    try m.def(vm, "pad_end", padEnd, 2, 3);
    try m.def(vm, "code", code, 1, 2);
    try m.def(vm, "reversed", reversed, 1, 1);
}

fn byteOffset(s: *const String, char_index: usize) usize {
    if (s.isAscii()) return @min(char_index, s.len);
    const b = s.bytes();
    var chars_seen: usize = 0;
    var i: usize = 0;
    while (i < b.len) : (i += 1) {
        if (b[i] & 0xC0 == 0x80) continue;
        if (chars_seen == char_index) return i;
        chars_seen += 1;
    }
    return b.len;
}

fn charIndex(s: *const String, byte: usize) usize {
    if (s.isAscii()) return byte;
    return @import("../vm/strings.zig").countChars(s.bytes()[0..byte]);
}

pub fn charAt(vm: *Vm, s: *String, index: Value) Error!Value {
    if (index.tag != .int) return vm.fail("a string index is an int, not {s}", .{types.typeName(index)});
    const n = index.asInt();
    const at: i64 = if (n < 0) n + s.chars else n;
    if (at < 0 or at >= s.chars) return vm.fail("index {d} is out of bounds for a string of length {d}", .{ n, s.chars });
    const start = byteOffset(s, @intCast(at));
    const len = std.unicode.utf8ByteSequenceLength(s.bytes()[start]) catch 1;
    return vm.string(s.bytes()[start..@min(s.len, start + len)]);
}

pub fn sliceChars(vm: *Vm, s: *String, from: usize, to: usize) Error!Value {
    return vm.string(s.bytes()[byteOffset(s, from)..byteOffset(s, to)]);
}

fn self(args: []Value) *String {
    return args[0].as(String);
}

fn isEmpty(_: *Vm, args: []Value) Error!Value {
    return .boolean(self(args).len == 0);
}

fn contains(vm: *Vm, args: []Value) Error!Value {
    return .boolean(std.mem.indexOf(u8, self(args).bytes(), try native.bytes(vm, args, 1)) != null);
}

fn startsWith(vm: *Vm, args: []Value) Error!Value {
    return .boolean(std.mem.startsWith(u8, self(args).bytes(), try native.bytes(vm, args, 1)));
}

fn endsWith(vm: *Vm, args: []Value) Error!Value {
    return .boolean(std.mem.endsWith(u8, self(args).bytes(), try native.bytes(vm, args, 1)));
}

fn find(vm: *Vm, args: []Value) Error!Value {
    const s = self(args);
    const at = std.mem.indexOf(u8, s.bytes(), try native.bytes(vm, args, 1)) orelse return .null;
    return .int(@intCast(charIndex(s, at)));
}

fn count(vm: *Vm, args: []Value) Error!Value {
    const needle = try native.bytes(vm, args, 1);
    if (needle.len == 0) return vm.fail("count() of an empty string", .{});
    return .int(@intCast(std.mem.count(u8, self(args).bytes(), needle)));
}

fn replace(vm: *Vm, args: []Value) Error!Value {
    const s = self(args).bytes();
    const old = try native.bytes(vm, args, 1);
    const new = try native.bytes(vm, args, 2);
    if (old.len == 0) return vm.fail("replace() of an empty string", .{});
    const out = try std.mem.replaceOwned(u8, vm.gpa, s, old, new);
    defer vm.gpa.free(out);
    return vm.string(out);
}

fn pieces(vm: *Vm, list: *object.List, iter: anytype) Error!void {
    var it = iter;
    while (it.next()) |piece| {
        const v = try vm.string(piece);
        try list.items.append(vm.gpa, v);
        vm.heap.barrier(&list.obj, v);
    }
}

fn split(vm: *Vm, args: []Value) Error!Value {
    const s = self(args).bytes();
    const list = try make.list(vm, 0, .string);
    const lv: Value = .fromObj(.list, &list.obj);
    try vm.pushRoot(lv);
    defer vm.popRoot();
    if (args.len == 1) {
        try pieces(vm, list, std.mem.tokenizeAny(u8, s, " \t\r\n"));
    } else {
        const sep = try native.bytes(vm, args, 1);
        if (sep.len == 0) return vm.fail("split() by an empty string; use chars() for the characters", .{});
        try pieces(vm, list, std.mem.splitSequence(u8, s, sep));
    }
    return lv;
}

fn lines(vm: *Vm, args: []Value) Error!Value {
    const s = self(args).bytes();
    const list = try make.list(vm, 0, .string);
    const lv: Value = .fromObj(.list, &list.obj);
    try vm.pushRoot(lv);
    defer vm.popRoot();
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| {
        if (it.index == null and line.len == 0) break;
        const v = try vm.string(std.mem.trimEnd(u8, line, "\r"));
        try list.items.append(vm.gpa, v);
        vm.heap.barrier(&list.obj, v);
    }
    return lv;
}

const whitespace = " \t\r\n";

fn trim(vm: *Vm, args: []Value) Error!Value {
    return vm.string(std.mem.trim(u8, self(args).bytes(), whitespace));
}

fn trimStart(vm: *Vm, args: []Value) Error!Value {
    return vm.string(std.mem.trimStart(u8, self(args).bytes(), whitespace));
}

fn trimEnd(vm: *Vm, args: []Value) Error!Value {
    return vm.string(std.mem.trimEnd(u8, self(args).bytes(), whitespace));
}

fn mapAscii(vm: *Vm, s: []const u8, comptime f: fn (u8) u8) Error!Value {
    const out = try vm.gpa.alloc(u8, s.len);
    defer vm.gpa.free(out);
    for (s, out) |c, *o| o.* = f(c);
    return vm.string(out);
}

fn upper(vm: *Vm, args: []Value) Error!Value {
    return mapAscii(vm, self(args).bytes(), std.ascii.toUpper);
}

fn lower(vm: *Vm, args: []Value) Error!Value {
    return mapAscii(vm, self(args).bytes(), std.ascii.toLower);
}

fn repeat(vm: *Vm, args: []Value) Error!Value {
    return @import("../vm/ops.zig").arith(vm, .mul, args[0], .int(try native.int(vm, args, 1)));
}

fn chars(vm: *Vm, args: []Value) Error!Value {
    const s = self(args).bytes();
    const list = try make.list(vm, self(args).chars, .string);
    const lv: Value = .fromObj(.list, &list.obj);
    try vm.pushRoot(lv);
    defer vm.popRoot();
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const v = try vm.string(s[i..@min(s.len, i + len)]);
        list.items.appendAssumeCapacity(v);
        vm.heap.barrier(&list.obj, v);
        i += len;
    }
    return lv;
}

fn bytesFn(vm: *Vm, args: []Value) Error!Value {
    const s = self(args).bytes();
    const list = try make.list(vm, s.len, .int);
    for (s) |c| list.items.appendAssumeCapacity(.int(c));
    return .fromObj(.list, &list.obj);
}

fn pad(vm: *Vm, args: []Value, at_start: bool) Error!Value {
    const s = self(args);
    const width = try native.int(vm, args, 1);
    const fill = if (args.len > 2) try native.bytes(vm, args, 2) else " ";
    if (fill.len == 0) return vm.fail("padding with an empty string", .{});
    if (width <= s.chars) return args[0];
    const missing: usize = @intCast(width - s.chars);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.gpa);
    if (!at_start) try out.appendSlice(vm.gpa, s.bytes());
    for (0..missing) |_| try out.appendSlice(vm.gpa, fill);
    if (at_start) try out.appendSlice(vm.gpa, s.bytes());
    return vm.string(out.items);
}

fn padStart(vm: *Vm, args: []Value) Error!Value {
    return pad(vm, args, true);
}

fn padEnd(vm: *Vm, args: []Value) Error!Value {
    return pad(vm, args, false);
}

fn code(vm: *Vm, args: []Value) Error!Value {
    const s = self(args);
    const index: i64 = if (args.len > 1) try native.int(vm, args, 1) else 0;
    if (index < 0 or index >= s.chars) return vm.fail("index {d} is out of bounds for a string of length {d}", .{ index, s.chars });
    const start = byteOffset(s, @intCast(index));
    const len = std.unicode.utf8ByteSequenceLength(s.bytes()[start]) catch 1;
    const cp = std.unicode.utf8Decode(s.bytes()[start..@min(s.len, start + len)]) catch s.bytes()[start];
    return .int(cp);
}

fn reversed(vm: *Vm, args: []Value) Error!Value {
    const s = self(args).bytes();
    const out = try vm.gpa.alloc(u8, s.len);
    defer vm.gpa.free(out);
    var i: usize = 0;
    var o: usize = s.len;
    while (i < s.len) {
        const len = @min(s.len - i, std.unicode.utf8ByteSequenceLength(s[i]) catch 1);
        o -= len;
        @memcpy(out[o .. o + len], s[i .. i + len]);
        i += len;
    }
    return vm.string(out);
}
