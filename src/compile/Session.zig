// SPDX-License-Identifier: BSD-2-Clause

//! What outlives one module's compile: the types, and what each compiled
//! module exports, for the modules that import it later.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");

const Session = @This();

pool: types.Pool,
modules: std.StringHashMapUnmanaged(*types.Module) = .empty,
loading: std.StringHashMapUnmanaged(void) = .empty,
/// Set by an editor's language service, to be told what each name means.
recorder: ?*@import("Recorder.zig") = null,
/// The host's enums as the compiler has them: see `host.enumOf`.
host_enums: std.ArrayList(*types.Enum) = .empty,

pub fn create(gpa: Allocator) Allocator.Error!*Session {
    const s = try gpa.create(Session);
    s.* = .{ .pool = .init(gpa) };
    return s;
}

pub fn destroy(s: *Session, gpa: Allocator) void {
    s.modules.deinit(gpa);
    s.loading.deinit(gpa);
    s.host_enums.deinit(gpa);
    s.pool.deinit();
    gpa.destroy(s);
}
