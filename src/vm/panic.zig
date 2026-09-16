// SPDX-License-Identifier: BSD-2-Clause

//! A runtime error: its message, and where every frame of the task was.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Vm = @import("Vm.zig");
const object = @import("object.zig");
const Fiber = @import("fiber.zig").Fiber;
const diag = @import("../diag.zig");

pub fn functionName(gpa: Allocator, p: *const object.Proto) Allocator.Error![]u8 {
    if (p.class) |c| return std.fmt.allocPrint(gpa, "{s}.{s}", .{ c.name.bytes(), p.name.bytes() });
    return gpa.dupe(u8, p.name.bytes());
}

/// Where a frame is: the instruction it is running, or for a frame below
/// the top, the call it is waiting on.
pub fn spanOf(frame: *const @import("fiber.zig").Frame, top: bool) diag.Span {
    const p = frame.proto;
    const start = @intFromPtr(p.code.ptr);
    var index = (@intFromPtr(frame.ip) - start) / 4;
    if (!top and index > 0) index -= 1;
    if (index >= p.spans.len) return if (p.spans.len > 0) p.spans[p.spans.len - 1] else .empty;
    return p.spans[index];
}

pub fn raise(vm: *Vm, message: []u8) Allocator.Error!void {
    errdefer vm.gpa.free(message);
    if (vm.panic != null) {
        vm.gpa.free(message);
        return;
    }
    const f: *Fiber = vm.fiber;
    var trace: std.ArrayList(Vm.TraceFrame) = .empty;
    errdefer {
        for (trace.items) |t| vm.gpa.free(t.function);
        trace.deinit(vm.gpa);
    }
    if (vm.current_native) |n| {
        try trace.append(vm.gpa, .{ .function = try vm.gpa.dupe(u8, n.name), .file = .none, .span = .empty });
    }
    var i = f.frames.items.len;
    while (i > 0) {
        i -= 1;
        const frame = &f.frames.items[i];
        const top = i == f.frames.items.len - 1 and vm.current_native == null;
        try trace.append(vm.gpa, .{
            .function = try functionName(vm.gpa, frame.proto),
            .file = frame.proto.file,
            .span = spanOf(frame, top),
        });
    }
    const first = for (trace.items) |t| {
        if (t.file != .none) break t;
    } else null;
    vm.panic = .{
        .message = message,
        .trace = try trace.toOwnedSlice(vm.gpa),
        .file = if (first) |t| t.file else .none,
        .span = if (first) |t| t.span else .empty,
    };
}

/// A panic as text: the message, the line it happened on, and the frames.
pub fn render(w: *std.Io.Writer, vm: *Vm, p: *const Vm.Panic, options: diag.render.Options) std.Io.Writer.Error!void {
    var list: diag.Diagnostics = .init(vm.gpa);
    defer list.deinit();
    if (p.file != .none) {
        const h = list.err(.{ .file = p.file, .span = p.span }, "{s}", .{p.message}) catch return error.WriteFailed;
        _ = h;
        try diag.render.diagnostic(w, &vm.sources, &list.items.items[0], options);
    } else {
        try w.print("error: {s}\n", .{p.message});
    }
    if (p.trace.len == 0) return;
    try w.writeAll("stack trace, most recent call first:\n");
    for (p.trace) |t| {
        if (t.file == .none) {
            try w.print("    in {s} (native)\n", .{t.function});
            continue;
        }
        const pos = vm.sources.position(t.file, t.span.start);
        try w.print("    in {s} at {s}:{d}:{d}\n", .{ t.function, vm.sources.name(t.file), pos.line, pos.column });
    }
}
