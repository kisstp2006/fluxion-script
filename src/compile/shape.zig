// SPDX-License-Identifier: BSD-2-Clause

//! What code compiled against a module relies on, written as text: each
//! variable's type, each function's signature, each struct's fields in
//! order, each enum's members. Compiled code reads fields by position and
//! skips checks it has already made, so a reload that changes any of these
//! cannot let code from before it run on. One that adds, removes or only
//! rewrites bodies can.

const std = @import("std");

const diag = @import("../diag.zig");
const types = @import("types.zig");
const Type = types.Type;
const Compiler = @import("Compiler.zig");
const Error = Compiler.Error;

const Writer = std.Io.Writer;

/// Every declaration's shape, into the module's compile info.
pub fn record(c: *Compiler) Error!void {
    const a = c.pool.allocator();
    for (c.globals.keys(), c.globals.values()) |name, g| {
        var out: Writer.Allocating = .init(a);
        declaration(c, g, &out.writer) catch return error.OutOfMemory;
        try c.info.globals.put(a, try a.dupe(u8, name), .{
            .index = g.index,
            .kind = g.kind,
            .span = g.span,
            .shape = out.written(),
            .folded = g.kind == .constant and g.value != null,
        });
    }
    for (c.structs.items) |s| try methods(c, s.info.name, s.info.methods);
    for (c.enums.items) |e| try methods(c, e.info.name, e.info.methods);
}

fn methods(c: *Compiler, owner: []const u8, table: std.StringArrayHashMapUnmanaged(types.Method)) Error!void {
    const a = c.pool.allocator();
    for (table.keys(), table.values()) |name, m| {
        var out: Writer.Allocating = .init(a);
        signature(c, m.sig, &out.writer) catch return error.OutOfMemory;
        try c.info.members.put(a, try std.fmt.allocPrint(a, "{s}.{s}", .{ owner, name }), out.written());
    }
}

fn declaration(c: *Compiler, g: Compiler.Global, w: *Writer) Writer.Error!void {
    switch (g.kind) {
        .variable, .constant => {
            try w.writeAll(if (g.kind == .variable) "var " else "const ");
            try typeText(c, g.type, w);
        },
        .function => try signature(c, c.pool.signatureOf(g.type).?, w),
        .@"struct" => {
            const s = c.pool.structOf(c.pool.metaOf(g.type).?).?;
            try w.writeAll("struct ");
            if (s.parent) |p| try qualified(c, p.file, p.name, w) else try w.writeByte('-');
            for (s.fields.items) |f| {
                try w.print(" {s}:", .{f.name});
                if (f.signal) |sig| {
                    try w.writeAll("signal ");
                    try signature(c, sig, w);
                } else try typeText(c, f.type, w);
            }
        },
        .@"enum" => {
            const e = c.pool.enumOf(c.pool.metaOf(g.type).?).?;
            try w.writeAll("enum");
            for (e.members) |m| try w.print(" {s}", .{m});
        },
        .import => if (c.pool.moduleOf(g.type)) |m| try w.print("import {s}", .{m.name}) else try w.writeAll("import"),
    }
}

fn signature(c: *Compiler, sig: *const types.Signature, w: *Writer) Writer.Error!void {
    try w.writeAll("fn(");
    for (sig.params, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        if (i == 0 and sig.has_self) {
            try w.writeAll("self");
            continue;
        }
        try typeText(c, p.type, w);
        if (p.has_default) try w.writeByte('=');
    }
    try w.writeAll(") ");
    try typeText(c, sig.ret, w);
    if (sig.coroutine) try w.writeAll(" await");
}

/// A type as `Pool.write` names it, but a struct or an enum with the file
/// it is declared in: two files may each have an `Enemy`.
fn typeText(c: *Compiler, t: Type, w: *Writer) Writer.Error!void {
    const info = c.pool.info(t) orelse return c.pool.write(t, w);
    switch (info) {
        .list => |e| {
            try w.writeByte('[');
            try typeText(c, e, w);
            try w.writeByte(']');
        },
        .map => |kv| {
            try w.writeByte('[');
            try typeText(c, kv.key, w);
            try w.writeAll(": ");
            try typeText(c, kv.value, w);
            try w.writeByte(']');
        },
        .optional => |x| {
            try w.writeByte('?');
            try typeText(c, x, w);
        },
        .error_union => |x| {
            try w.writeByte('!');
            try typeText(c, x, w);
        },
        .function => |sig| try signature(c, sig, w),
        .@"struct" => |s| try qualified(c, s.file, s.name, w),
        .@"enum" => |e| try qualified(c, e.file, e.name, w),
        .module => |m| try w.print("module {s}", .{m.name}),
        .meta => |x| {
            try w.writeAll("type ");
            try typeText(c, x, w);
        },
    }
}

fn qualified(c: *Compiler, file: diag.FileId, name: []const u8, w: *Writer) Writer.Error!void {
    try w.print("{s}:{s}", .{ c.vm.sources.name(file), name });
}
