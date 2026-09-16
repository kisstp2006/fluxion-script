// SPDX-License-Identifier: BSD-2-Clause

//! `const os = @import("os");`: files, the command line and the clock, for
//! a host that lets its scripts have them. `flux run` does; a game decides
//! for itself, since a mod with file access can read the player's disk.

const std = @import("std");

const Vm = @import("../vm/Vm.zig");
const Value = @import("../vm/value.zig").Value;
const object = @import("../vm/object.zig");
const make = @import("../vm/make.zig");
const native = @import("native.zig");
const Error = native.Error;

pub const Host = struct {
    io: std.Io,
    args: []const []const u8,
    start: std.Io.Timestamp,
    exit_code: ?u8 = null,
    /// Where `read_line` reads from; standard input when null.
    input: ?*std.Io.Reader = null,
    /// Standard input, kept from one `read_line` to the next, since each
    /// reads past the line it gives. Streaming: stdin may be a pipe, and a
    /// positional reader on a file starts at its first line every time.
    stdin: ?std.Io.File.Reader = null,
    stdin_buffer: [4096]u8 = undefined,

    fn lines(h: *Host) *std.Io.Reader {
        if (h.input) |r| return r;
        if (h.stdin == null) h.stdin = std.Io.File.stdin().readerStreaming(h.io, &h.stdin_buffer);
        return &h.stdin.?.interface;
    }
};

fn host(vm: *Vm) *Host {
    return @ptrCast(@alignCast(vm.os_host.?));
}

pub fn install(vm: *Vm, h: *Host) std.mem.Allocator.Error!void {
    vm.os_host = h;
    vm.heap.paused += 1;
    defer vm.heap.paused -= 1;
    const m = try make.module(vm, try vm.intern("os"));
    m.state = .ready;
    m.ran = true;
    const args = try make.list(vm, h.args.len, .string);
    for (h.args) |a| args.items.appendAssumeCapacity(try vm.string(a));
    try native.member(vm, m, "args", .fromObj(.list, &args.obj));
    const functions = .{
        .{ "read_file", readFile, 1, 1 },   .{ "write_file", writeFile, 2, 2 },
        .{ "exists", exists, 1, 1 },        .{ "list_dir", listDir, 1, 1 },
        .{ "time", time, 0, 0 },            .{ "exit", exit, 1, 1 },
        .{ "read_line", readLine, 0, 0 },
    };
    inline for (functions) |f| try native.function(vm, m, f[0], f[1], f[2], f[3]);
    try vm.native_modules.put(vm.gpa, try vm.gpa.dupe(u8, "os"), m);
}

fn failed(vm: *Vm, err: anyerror, path: []const u8) Error!Value {
    var buf: [512]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "{s}: {s}", .{ path, @errorName(err) }) catch path;
    return make.errorText(vm, @errorName(err), message);
}

fn readFile(vm: *Vm, args: []Value) Error!Value {
    const path = try native.bytes(vm, args, 0);
    const bytes = std.Io.Dir.cwd().readFileAlloc(host(vm).io, path, vm.gpa, .limited(256 << 20)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failed(vm, err, path),
    };
    defer vm.gpa.free(bytes);
    return vm.string(bytes);
}

fn writeFile(vm: *Vm, args: []Value) Error!Value {
    const path = try native.bytes(vm, args, 0);
    const text = try native.bytes(vm, args, 1);
    std.Io.Dir.cwd().writeFile(host(vm).io, .{ .sub_path = path, .data = text }) catch |err| return failed(vm, err, path);
    return .null;
}

fn exists(vm: *Vm, args: []Value) Error!Value {
    const path = try native.bytes(vm, args, 0);
    std.Io.Dir.cwd().access(host(vm).io, path, .{}) catch return .false;
    return .true;
}

fn listDir(vm: *Vm, args: []Value) Error!Value {
    const path = try native.bytes(vm, args, 0);
    const io = host(vm).io;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| return failed(vm, err, path);
    defer dir.close(io);
    const list = try make.list(vm, 0, .string);
    const lv: Value = .fromObj(.list, &list.obj);
    try vm.pushRoot(lv);
    defer vm.popRoot();
    var it = dir.iterate();
    while (it.next(io) catch |err| return failed(vm, err, path)) |entry| {
        const v = try vm.string(entry.name);
        try list.items.append(vm.gpa, v);
        vm.heap.barrier(&list.obj, v);
    }
    return lv;
}

fn time(vm: *Vm, _: []Value) Error!Value {
    const h = host(vm);
    const ns = h.start.durationTo(std.Io.Timestamp.now(h.io, .awake)).nanoseconds;
    return .float(@as(f64, @floatFromInt(ns)) / std.time.ns_per_s);
}

/// Whether a script called `os.exit`: the panic that unwinds it is how it
/// stops, not a mistake to report.
pub fn exiting(vm: *Vm) bool {
    const h: *Host = @ptrCast(@alignCast(vm.os_host orelse return false));
    return h.exit_code != null;
}

fn exit(vm: *Vm, args: []Value) Error!Value {
    const code = try native.int(vm, args, 0);
    host(vm).exit_code = @intCast(std.math.clamp(code, 0, 255));
    return vm.fail("exit", .{});
}

fn readLine(vm: *Vm, _: []Value) Error!Value {
    const in = host(vm).lines();
    var line: std.Io.Writer.Allocating = .init(vm.gpa);
    defer line.deinit();
    const n = in.streamDelimiterEnding(&line.writer, '\n') catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.ReadFailed => return .null,
    };
    // The break is left in the reader, unless the input ended first.
    if (in.bufferedLen() > 0) in.toss(1) else if (n == 0) return .null;
    return vm.string(std.mem.trimEnd(u8, line.written(), "\r"));
}

test "read_line gives each line once, the last without its break, then null" {
    const testing = std.testing;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const vm = try Vm.create(testing.allocator, .{ .out = &out.writer });
    defer vm.destroy();
    // Through a buffer of 64, as stdin is through one of 4096: a line may be
    // longer than the buffer.
    var source: std.Io.Reader = .fixed("alpha\r\nbeta\n\n" ++ "x" ** 5000 ++ "\ngamma");
    var buffer: [64]u8 = undefined;
    var input = source.limited(.unlimited, &buffer);
    var h: Host = .{ .io = testing.io, .args = &.{}, .start = std.Io.Timestamp.now(testing.io, .awake), .input = &input.interface };
    try install(vm, &h);
    _ = try vm.load("t.flux",
        \\const os = @import("os");
        \\while (os.read_line()) |line| print(if (line.len > 9) f"{line.len} long" else f"[{line}]");
        \\print("done");
    );
    try testing.expectEqualStrings("[alpha]\n[beta]\n[]\n5000 long\n[gamma]\ndone\n", out.written());
}
