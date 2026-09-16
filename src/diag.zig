// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const render = @import("diag/render.zig");
pub const Sources = @import("diag/Sources.zig");

pub const Span = struct {
    start: u32,
    end: u32,

    pub const empty: Span = .{ .start = 0, .end = 0 };

    pub fn to(a: Span, b: Span) Span {
        return .{ .start = @min(a.start, b.start), .end = @max(a.end, b.end) };
    }

    pub fn at(offset: u32) Span {
        return .{ .start = offset, .end = offset };
    }
};

pub const FileId = enum(u32) {
    none = std.math.maxInt(u32),
    _,
};

pub const Location = struct {
    file: FileId,
    span: Span,
};

pub const Severity = enum {
    @"error",
    warning,
    note,

    pub fn word(severity: Severity) []const u8 {
        return @tagName(severity);
    }
};

pub const Label = struct {
    at: Location,
    message: []const u8,
    primary: bool,
};

pub const Diagnostic = struct {
    severity: Severity,
    message: []const u8,
    labels: std.ArrayList(Label) = .empty,
    notes: std.ArrayList([]const u8) = .empty,
    help: ?[]const u8 = null,

    pub fn primary(d: *const Diagnostic) ?Location {
        for (d.labels.items) |l| if (l.primary) return l.at;
        return null;
    }
};

pub const Diagnostics = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Diagnostic) = .empty,
    errors: u32 = 0,
    warnings: u32 = 0,
    max_errors: u32 = 100,

    pub fn init(gpa: Allocator) Diagnostics {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *Diagnostics) Allocator {
        return self.arena.allocator();
    }

    pub fn failed(self: *const Diagnostics) bool {
        return self.errors > 0;
    }

    pub fn full(self: *const Diagnostics) bool {
        return self.errors >= self.max_errors;
    }

    pub const Handle = struct {
        list: *Diagnostics,
        index: usize,

        fn get(h: Handle) *Diagnostic {
            return &h.list.items.items[h.index];
        }

        pub fn label(h: Handle, at: Location, comptime fmt: []const u8, args: anytype) Allocator.Error!Handle {
            const a = h.list.allocator();
            try h.get().labels.append(a, .{ .at = at, .message = try std.fmt.allocPrint(a, fmt, args), .primary = false });
            return h;
        }

        pub fn note(h: Handle, comptime fmt: []const u8, args: anytype) Allocator.Error!Handle {
            const a = h.list.allocator();
            try h.get().notes.append(a, try std.fmt.allocPrint(a, fmt, args));
            return h;
        }

        pub fn help(h: Handle, comptime fmt: []const u8, args: anytype) Allocator.Error!Handle {
            h.get().help = try std.fmt.allocPrint(h.list.allocator(), fmt, args);
            return h;
        }

        /// What the caret under the primary span says.
        pub fn text(h: Handle, comptime fmt: []const u8, args: anytype) Allocator.Error!Handle {
            const d = h.get();
            for (d.labels.items) |*l| if (l.primary) {
                l.message = try std.fmt.allocPrint(h.list.allocator(), fmt, args);
                break;
            };
            return h;
        }
    };

    pub fn add(
        self: *Diagnostics,
        severity: Severity,
        at: Location,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!Handle {
        const a = self.allocator();
        var d: Diagnostic = .{ .severity = severity, .message = try std.fmt.allocPrint(a, fmt, args) };
        try d.labels.append(a, .{ .at = at, .message = "", .primary = true });
        try self.items.append(a, d);
        switch (severity) {
            .@"error" => self.errors += 1,
            .warning => self.warnings += 1,
            .note => {},
        }
        return .{ .list = self, .index = self.items.items.len - 1 };
    }

    pub fn err(self: *Diagnostics, at: Location, comptime fmt: []const u8, args: anytype) Allocator.Error!Handle {
        return self.add(.@"error", at, fmt, args);
    }

    pub fn warn(self: *Diagnostics, at: Location, comptime fmt: []const u8, args: anytype) Allocator.Error!Handle {
        return self.add(.warning, at, fmt, args);
    }
};

test {
    _ = render;
    _ = Sources;
}
