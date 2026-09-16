// SPDX-License-Identifier: BSD-2-Clause

//! A line of execution: its frames and the registers they work in.
//!
//! Registers live in chunks that never move once made. A call whose frame
//! does not fit in what is left of a chunk starts the next one and copies
//! its arguments there, so a pointer to a register - an open captured
//! variable, a native's arguments - stays good for as long as the frame.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Value = @import("value.zig").Value;
const object = @import("object.zig");

pub const Frame = struct {
    closure: *object.Closure,
    /// The code this frame runs. A reload gives the closure new code for
    /// its next call; a frame already running keeps what it started with.
    proto: *object.Proto,
    ip: [*]const u32,
    base: [*]Value,
    result: *Value,
    chunk: u32,
    args: u8,
    /// Returning from this frame ends the `run` that pushed it.
    boundary: bool,
};

pub const Chunk = struct {
    values: []Value,
    top: usize = 0,
};

pub const Fiber = struct {
    chunks: std.ArrayList(Chunk) = .empty,
    current: u32 = 0,
    /// The address just past the current chunk's registers: whether a
    /// call's frame fits is one comparison.
    end: usize = 0,
    frames: std.ArrayList(Frame) = .empty,
    open: ?*object.Upvalue = null,
    first_size: usize,

    pub const default_chunk = 1024;

    pub fn init(first_size: usize) Fiber {
        return .{ .first_size = first_size };
    }

    pub fn deinit(f: *Fiber, gpa: Allocator) void {
        for (f.chunks.items) |c| gpa.free(c.values);
        f.chunks.deinit(gpa);
        f.frames.deinit(gpa);
        f.* = undefined;
    }

    fn use(f: *Fiber, i: u32) void {
        f.current = i;
        const values = f.chunks.items[i].values;
        f.end = @intFromPtr(values.ptr + values.len);
    }

    fn newChunk(f: *Fiber, gpa: Allocator, wanted: usize) Allocator.Error!void {
        const next = f.current + 1;
        if (f.chunks.items.len == 0) {
            const size = @max(f.first_size, wanted);
            const values = try gpa.alloc(Value, size);
            @memset(values, .null);
            errdefer gpa.free(values);
            try f.chunks.append(gpa, .{ .values = values });
            f.use(0);
            return;
        }
        if (next < f.chunks.items.len and f.chunks.items[next].values.len >= wanted) {
            f.use(next);
            f.chunks.items[next].top = 0;
            return;
        }
        if (next < f.chunks.items.len) {
            gpa.free(f.chunks.items[next].values);
            f.chunks.items[next].values = &.{};
        } else {
            try f.chunks.append(gpa, .{ .values = &.{} });
        }
        const previous = f.chunks.items[f.current].values.len;
        const size = @max(wanted, @min(previous * 2, 64 * 1024));
        const values = try gpa.alloc(Value, size);
        @memset(values, .null);
        f.chunks.items[next] = .{ .values = values };
        f.use(next);
    }

    /// Where registers are free: past the top frame's, or at the start.
    pub fn free(f: *Fiber, gpa: Allocator, wanted: usize) Allocator.Error![*]Value {
        if (f.chunks.items.len == 0) try f.newChunk(gpa, wanted);
        const chunk = &f.chunks.items[f.current];
        const at = f.topIndex();
        if (at + wanted <= chunk.values.len) return chunk.values.ptr + at;
        chunk.top = at;
        try f.newChunk(gpa, wanted);
        return f.chunks.items[f.current].values.ptr;
    }

    /// The index in the current chunk just past the top frame's registers.
    pub fn topIndex(f: *const Fiber) usize {
        if (f.frames.items.len == 0) return f.chunks.items[f.current].top;
        const top = f.frames.items[f.frames.items.len - 1];
        if (top.chunk != f.current) return f.chunks.items[f.current].top;
        const start = @intFromPtr(f.chunks.items[f.current].values.ptr);
        return (@intFromPtr(top.base) - start) / @sizeOf(Value) + top.proto.regs;
    }

    /// Room for a frame of `regs` registers whose first `args` are already
    /// at `base`, in the current chunk. Moves them to a fresh chunk if this
    /// one is too short, and says where the frame starts.
    pub inline fn place(f: *Fiber, gpa: Allocator, base: [*]Value, args: usize, regs: usize) Allocator.Error![*]Value {
        if (@intFromPtr(base) + regs * @sizeOf(Value) <= f.end) return base;
        return f.placeFresh(gpa, base, args, regs);
    }

    fn placeFresh(f: *Fiber, gpa: Allocator, base: [*]Value, args: usize, regs: usize) Allocator.Error![*]Value {
        @branchHint(.cold);
        const chunk = &f.chunks.items[f.current];
        chunk.top = (@intFromPtr(base) - @intFromPtr(chunk.values.ptr)) / @sizeOf(Value);
        try f.newChunk(gpa, regs);
        const fresh = f.chunks.items[f.current].values.ptr;
        @memcpy(fresh[0..args], base[0..args]);
        return fresh;
    }

    /// Back to the chunk of the frame now on top, after a return.
    pub inline fn popped(f: *Fiber) void {
        if (f.frames.items.len == 0) {
            if (f.chunks.items.len > 0) {
                f.use(0);
                f.chunks.items[0].top = 0;
            } else f.current = 0;
            return;
        }
        const c = f.frames.items[f.frames.items.len - 1].chunk;
        if (c != f.current) f.use(c);
    }

    pub fn depth(f: *const Fiber) usize {
        return f.frames.items.len;
    }

    /// Every register in use, chunk by chunk, for the collector.
    pub fn live(f: *const Fiber, visit: anytype) void {
        var it = f.used();
        while (it.next()) |values| for (values) |v| visit.value(v);
    }

    pub const Used = struct {
        fiber: *const Fiber,
        chunk: usize = 0,

        pub fn next(it: *Used) ?[]Value {
            const f = it.fiber;
            if (f.chunks.items.len == 0 or it.chunk > f.current) return null;
            const c = f.chunks.items[it.chunk];
            const end = if (it.chunk == f.current) f.topIndex() else c.top;
            it.chunk += 1;
            return c.values[0..@min(end, c.values.len)];
        }
    };

    /// The registers in use, a chunk at a time, to read or change.
    pub fn used(f: *const Fiber) Used {
        return .{ .fiber = f };
    }

    /// Nulls every register past the live ones, so a later frame never finds
    /// a value the collector has freed.
    pub fn clearDead(f: *Fiber) void {
        if (f.chunks.items.len == 0) return;
        for (f.chunks.items, 0..) |c, i| {
            const end: usize = if (i < f.current) c.top else if (i == f.current) f.topIndex() else 0;
            if (end < c.values.len) @memset(c.values[end..], .null);
        }
    }
};
