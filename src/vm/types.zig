// SPDX-License-Identifier: BSD-2-Clause

//! What a value must be when it crosses from untyped code into a typed
//! variable, field, parameter or list: a `Check`, four bytes, tested in a
//! few instructions.

const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Tag = value_mod.Tag;
const object = @import("object.zig");
const reflect = @import("fluxion_reflect");
const bridge = @import("../reflect.zig");

pub const Check = enum(u32) {
    any,
    int,
    float,
    bool,
    string,
    vec2,
    vec3,
    color,
    list,
    map,
    function,
    task,
    signal,
    @"error",
    null,
    type,
    _,

    pub const first_table = 32;

    pub fn fromTable(index: usize) Check {
        return @enumFromInt(first_table + index);
    }

    pub fn tableIndex(c: Check) ?usize {
        const n = @intFromEnum(c);
        return if (n >= first_table) n - first_table else null;
    }
};

pub const Info = union(enum) {
    optional: Check,
    list_of: Check,
    map_of: struct { key: Check, value: Check },
    class: *object.Class,
    enum_type: *object.EnumType,
    error_union: Check,
    function: void,
    /// A value of the host's type: see `bridge.isOf`.
    host: *const reflect.Type,
};

pub const Table = struct {
    items: std.ArrayList(Info) = .empty,

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.items.deinit(gpa);
    }

    pub fn add(t: *Table, gpa: Allocator, info: Info) Allocator.Error!Check {
        for (t.items.items, 0..) |existing, i| {
            if (std.meta.eql(existing, info)) return .fromTable(i);
        }
        try t.items.append(gpa, info);
        return .fromTable(t.items.items.len - 1);
    }

    pub fn get(t: *const Table, c: Check) ?Info {
        const i = c.tableIndex() orelse return null;
        return t.items.items[i];
    }

    /// Whether `v` may be stored where `c` is wanted. Ints pass where
    /// floats are wanted; `coerce` widens them.
    pub fn accepts(t: *const Table, c: Check, v: Value) bool {
        return switch (c) {
            .any => true,
            .int => v.tag == .int,
            .float => v.tag == .float or v.tag == .int,
            .bool => v.tag == .bool,
            .string => v.tag == .string,
            .vec2 => v.tag == .vec2,
            .vec3 => v.tag == .vec3,
            .color => v.tag == .color,
            .list => v.tag == .list,
            .map => v.tag == .map,
            .function => v.tag == .function or v.tag == .native or v.tag == .method,
            .task => v.tag == .task,
            .signal => v.tag == .signal,
            .@"error" => v.tag == .@"error",
            .null => v.tag == .null,
            .type => v.tag == .class or v.tag == .enum_type or v.tag == .host_type,
            _ => switch (t.get(c).?) {
                .optional => |inner| v.tag == .null or t.accepts(inner, v),
                .error_union => |inner| v.tag == .@"error" or t.accepts(inner, v),
                .list_of => |elem| v.tag == .list and v.as(object.List).elem == elem,
                .map_of => |kv| v.tag == .map and v.as(object.Map).key == kv.key and v.as(object.Map).value == kv.value,
                .class => |class| v.tag == .instance and v.as(object.Instance).class.isSubclassOf(class),
                .enum_type => |e| v.tag == .enum_value and v.obj() == &e.obj,
                .function => v.tag == .function or v.tag == .native or v.tag == .method,
                .host => |host| bridge.isOf(v, host),
            },
        };
    }

    /// `v` as `c` stores it: an int where a float is wanted becomes a float.
    pub fn coerce(t: *const Table, c: Check, v: Value) ?Value {
        if (!t.accepts(c, v)) return null;
        if (v.tag == .int and wantsFloat(t, c)) return .float(@floatFromInt(v.asInt()));
        return v;
    }

    fn wantsFloat(t: *const Table, c: Check) bool {
        return switch (c) {
            .float => true,
            _ => switch (t.get(c).?) {
                .optional, .error_union => |inner| inner == .float,
                else => false,
            },
            else => false,
        };
    }

    pub fn name(t: *const Table, c: Check, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (c) {
            .any, .int, .float, .bool, .string, .vec2, .vec3, .color, .list, .map, .task, .signal, .@"error", .null, .type => try w.writeAll(@tagName(c)),
            .function => try w.writeAll("fn"),
            _ => switch (t.get(c).?) {
                .optional => |inner| {
                    try w.writeByte('?');
                    try t.name(inner, w);
                },
                .error_union => |inner| {
                    try w.writeByte('!');
                    try t.name(inner, w);
                },
                .list_of => |elem| {
                    try w.writeByte('[');
                    try t.name(elem, w);
                    try w.writeByte(']');
                },
                .map_of => |kv| {
                    try w.writeByte('[');
                    try t.name(kv.key, w);
                    try w.writeAll(": ");
                    try t.name(kv.value, w);
                    try w.writeByte(']');
                },
                .class => |class| try w.writeAll(class.name.bytes()),
                .enum_type => |e| try w.writeAll(e.name.bytes()),
                .function => try w.writeAll("fn"),
                .host => |host| try w.writeAll(bridge.nameOf(host)),
            },
        }
    }
};

/// The name a value's own type goes by, for "expected int, got string".
pub fn typeName(v: Value) []const u8 {
    return switch (v.tag) {
        .instance => v.as(object.Instance).class.name.bytes(),
        .enum_value => object.EnumType.from(v.obj()).name.bytes(),
        .function, .native, .method => "fn",
        .class, .enum_type, .host_type => "type",
        .handle => bridge.nameOf(bridge.heldType(v.as(object.Handle))),
        .@"error" => "error",
        .undefined => "an uninitialised variable",
        else => @tagName(v.tag),
    };
}

pub fn tagCheck(tag: Tag) Check {
    return switch (tag) {
        .int => .int,
        .float => .float,
        .bool => .bool,
        .string => .string,
        .vec2 => .vec2,
        .vec3 => .vec3,
        .color => .color,
        .list => .list,
        .map => .map,
        .function, .native, .method => .function,
        .task => .task,
        .signal => .signal,
        .@"error" => .@"error",
        .null => .null,
        else => .any,
    };
}
