// SPDX-License-Identifier: BSD-2-Clause

//! `const url = @import("url");`: text put into a URL and taken out of one.
//! `encode` keeps only what a URL never changes - letters, digits and
//! `-_.~` - and writes every other byte as `%XX`, so a value goes into a
//! query as it is.

const std = @import("std");

const Vm = @import("../vm/Vm.zig");
const Value = @import("../vm/value.zig").Value;
const make = @import("../vm/make.zig");
const format = @import("../vm/format.zig");
const native = @import("native.zig");
const Error = native.Error;

pub fn install(vm: *Vm) std.mem.Allocator.Error!void {
    const m = try make.module(vm, try vm.intern("url"));
    try vm.native_modules.put(vm.gpa, try vm.gpa.dupe(u8, "url"), m);
    m.state = .ready;
    try native.function(vm, m, "encode", encodeFn, 1, 1);
    try native.function(vm, m, "decode", decodeFn, 1, 1);
    try native.function(vm, m, "query", queryFn, 1, 1);
}

fn encodeFn(vm: *Vm, args: []Value) Error!Value {
    var out: std.Io.Writer.Allocating = .init(vm.gpa);
    defer out.deinit();
    encode(&out.writer, try native.bytes(vm, args, 0)) catch return error.OutOfMemory;
    return vm.string(out.written());
}

/// `%XX` back into the byte it stands for; the rest, `+` too, as it is.
fn decodeFn(vm: *Vm, args: []Value) Error!Value {
    const text = try native.bytes(vm, args, 0);
    const out = try vm.gpa.alloc(u8, text.len);
    defer vm.gpa.free(out);
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (n += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |byte| {
                out[n] = byte;
                i += 3;
                continue;
            } else |_| {}
        }
        out[n] = text[i];
        i += 1;
    }
    return vm.string(out[0..n]);
}

/// A map as a query - `a=1&b=two%20words` - its keys in order, so the same
/// map always gives the same text, as a signed request needs.
fn queryFn(vm: *Vm, args: []Value) Error!Value {
    const m = try native.map(vm, args, 0);
    const Pair = struct { key: []const u8, value: []const u8 };
    var arena: std.heap.ArenaAllocator = .init(vm.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var pairs: std.ArrayList(Pair) = .empty;
    var it = m.table.iterator();
    while (it.next()) |e| {
        try pairs.append(a, .{ .key = try shown(a, e.key), .value = try shown(a, e.value) });
    }
    std.sort.pdq(Pair, pairs.items, {}, struct {
        fn less(_: void, x: Pair, y: Pair) bool {
            return std.mem.lessThan(u8, x.key, y.key);
        }
    }.less);
    var out: std.Io.Writer.Allocating = .init(vm.gpa);
    defer out.deinit();
    const w = &out.writer;
    for (pairs.items, 0..) |p, i| {
        if (i > 0) w.writeByte('&') catch return error.OutOfMemory;
        encode(w, p.key) catch return error.OutOfMemory;
        w.writeByte('=') catch return error.OutOfMemory;
        encode(w, p.value) catch return error.OutOfMemory;
    }
    return vm.string(out.written());
}

/// A value as `print` writes it, a string without its quotes.
fn shown(a: std.mem.Allocator, v: Value) std.mem.Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    format.value(&out.writer, v, false, 0) catch return error.OutOfMemory;
    return out.written();
}

pub fn encode(w: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    for (bytes) |b| {
        if (std.ascii.isAlphanumeric(b) or b == '-' or b == '_' or b == '.' or b == '~') {
            try w.writeByte(b);
        } else {
            try w.print("%{X:0>2}", .{b});
        }
    }
}
