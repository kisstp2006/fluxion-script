// SPDX-License-Identifier: BSD-2-Clause

//! The collector: incremental mark and sweep, three colours and two whites.
//!
//! Marking is done a slice at a time, paid for by allocation, so a game
//! never stops for the whole heap. A black object that is given a white
//! one goes back on the grey list (`barrier`), and the registers, which no
//! barrier watches, are marked again in one step at the end of the mark.
//! Sweeping frees what is still the old white, also a slice at a time;
//! objects made meanwhile are the new white and are left alone.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Value = @import("value.zig").Value;
const object = @import("object.zig");
const Obj = object.Obj;

pub const white0: u8 = 1;
pub const white1: u8 = 2;
pub const black: u8 = 4;
const whites = white0 | white1;

pub const Phase = enum { idle, mark, sweep };

pub const Options = struct {
    /// A new cycle starts when the heap has grown by this percentage of
    /// what was alive after the last one.
    pause: u32 = 200,
    /// Work done per allocated byte, in percent: higher finishes a cycle
    /// sooner and pauses longer each step.
    step_multiplier: u32 = 200,
    /// Collect everything on every allocation: slow, and the way to find a
    /// value that is not rooted.
    stress: bool = false,
    /// Check after every mark that no black object holds a white one.
    verify: bool = false,
    incremental: bool = true,
};

pub const Heap = struct {
    gpa: Allocator,
    objects: ?*Obj = null,
    bytes: usize = 0,
    threshold: usize = 1 << 20,
    debt: isize = 0,
    phase: Phase = .idle,
    white: u8 = white0,
    gray: std.ArrayList(*Obj) = .empty,
    sweep_prev: ?*?*Obj = null,
    paused: u32 = 0,
    options: Options = .{},
    cycles: u64 = 0,
    live_after: usize = 0,

    pub fn otherWhite(h: *const Heap) u8 {
        return h.white ^ whites;
    }

    pub inline fn isWhite(o: *const Obj) bool {
        return o.color & whites != 0;
    }

    pub inline fn isBlack(o: *const Obj) bool {
        return o.color & black != 0;
    }

    /// Links a freshly made object in, the current white.
    pub fn link(h: *Heap, o: *Obj, kind: object.Kind) void {
        o.* = .{ .next = h.objects, .kind = kind, .color = h.white };
        h.objects = o;
    }

    /// Marks an object reachable: grey until its children are.
    pub inline fn mark(h: *Heap, o: *Obj) void {
        if (!isWhite(o)) return;
        o.color = 0;
        h.gray.appendAssumeCapacity(o);
    }

    pub inline fn markValue(h: *Heap, v: Value) void {
        if (v.tag.isObject()) h.mark(v.obj()) else if (v.tag == .enum_value) h.mark(v.obj());
    }

    /// A black `container` now holds `v`: grey it again, so the rest of the
    /// mark sees what it holds.
    pub inline fn barrier(h: *Heap, container: *Obj, v: Value) void {
        if (h.phase != .mark) return;
        if (!isBlack(container)) return;
        if (!(v.tag.isObject() or v.tag == .enum_value)) return;
        if (!isWhite(v.obj())) return;
        container.color = 0;
        h.gray.appendAssumeCapacity(container);
    }

    pub inline fn barrierObj(h: *Heap, container: *Obj, child: *Obj) void {
        if (h.phase != .mark) return;
        if (!isBlack(container) or !isWhite(child)) return;
        container.color = 0;
        h.gray.appendAssumeCapacity(container);
    }

    /// Room on the grey list for every object there is, so marking and the
    /// barrier never allocate. Called for each new object.
    pub fn reserveGray(h: *Heap, objects: usize) Allocator.Error!void {
        if (h.gray.capacity >= objects + 8) return;
        try h.gray.ensureTotalCapacity(h.gpa, @max(objects + 8, h.gray.capacity * 2));
    }
};

test "colours" {
    var o: Obj = .{ .next = null, .kind = .string, .color = white0 };
    try std.testing.expect(Heap.isWhite(&o));
    o.color = black;
    try std.testing.expect(Heap.isBlack(&o) and !Heap.isWhite(&o));
}
