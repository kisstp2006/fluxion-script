// SPDX-License-Identifier: BSD-2-Clause

//! Which tasks exist, and which are waiting for a time to come.

const std = @import("std");
const Allocator = std.mem.Allocator;

const object = @import("object.zig");
const Task = object.Task;
const Heap = @import("heap.zig").Heap;

pub const Scheduler = struct {
    /// Every task alive, so the collector can mark their registers again at
    /// the end of a mark. Not a root: a task nothing else holds is garbage.
    all: std.ArrayList(*Task) = .empty,
    /// Waiting for a time, earliest first.
    timers: std.ArrayList(*Task) = .empty,
    time: f64 = 0,

    pub fn deinit(s: *Scheduler, gpa: Allocator) void {
        s.all.deinit(gpa);
        s.timers.deinit(gpa);
    }

    pub fn track(s: *Scheduler, gpa: Allocator, t: *Task) Allocator.Error!void {
        t.slot = @intCast(s.all.items.len);
        try s.all.append(gpa, t);
    }

    pub fn forget(s: *Scheduler, t: *Task) void {
        const i = t.slot;
        if (i < s.all.items.len and s.all.items[i] == t) {
            const last = s.all.pop().?;
            if (last != t) {
                s.all.items[i] = last;
                last.slot = i;
            }
        }
        s.cancelTimer(t);
    }

    pub fn sleep(s: *Scheduler, gpa: Allocator, t: *Task, until: f64) Allocator.Error!void {
        t.wake_at = until;
        var at: usize = s.timers.items.len;
        while (at > 0 and s.timers.items[at - 1].wake_at > until) at -= 1;
        try s.timers.insert(gpa, at, t);
    }

    pub fn cancelTimer(s: *Scheduler, t: *Task) void {
        for (s.timers.items, 0..) |x, i| if (x == t) {
            _ = s.timers.orderedRemove(i);
            return;
        };
    }

    /// The first task whose time has come, taken off the list.
    pub fn due(s: *Scheduler) ?*Task {
        if (s.timers.items.len == 0) return null;
        if (s.timers.items[0].wake_at > s.time) return null;
        return s.timers.orderedRemove(0);
    }

    pub fn mark(s: *Scheduler, h: *Heap) void {
        for (s.timers.items) |t| h.mark(&t.obj);
    }
};
