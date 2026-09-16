// SPDX-License-Identifier: BSD-2-Clause

//! The types the compiler knows an expression to have. A handle is four
//! bytes; lists, maps, optionals and functions of each shape are made once.

const std = @import("std");
const Allocator = std.mem.Allocator;

const object = @import("../vm/object.zig");
const rt = @import("../vm/types.zig");
const diag = @import("../diag.zig");

pub const Type = enum(u32) {
    /// Something already reported as wrong: accepted everywhere, so one
    /// mistake is one message.
    unknown,
    any,
    void,
    null,
    bool,
    int,
    float,
    string,
    vec2,
    vec3,
    color,
    /// `return`, `break`, `panic(...)`: no value, and nothing after it runs.
    never,
    @"error",
    task,
    signal,
    _,

    pub const first_pool = 64;
};

pub const Param = struct {
    name: []const u8,
    type: Type,
    has_default: bool,
};

pub const Signature = struct {
    params: []const Param,
    ret: Type,
    has_self: bool = false,
    coroutine: bool = false,

    pub fn required(s: *const Signature) usize {
        var n: usize = 0;
        for (s.params) |p| {
            if (p.has_default) break;
            n += 1;
        }
        return n;
    }
};

pub const Field = struct {
    name: []const u8,
    type: Type,
    slot: u32,
    is_const: bool,
    is_signal: bool,
    span: diag.Span,
    file: diag.FileId,
    signal: ?*const Signature = null,
};

pub const Method = struct {
    name: []const u8,
    sig: *Signature,
    closure: ?*object.Closure = null,
    span: diag.Span,
    file: diag.FileId,
};

pub const Constant = struct {
    name: []const u8,
    type: Type,
    value: ?@import("../vm/value.zig").Value,
    span: diag.Span,
};

pub const Struct = struct {
    name: []const u8,
    file: diag.FileId,
    span: diag.Span,
    parent: ?*Struct = null,
    fields: std.ArrayList(Field) = .empty,
    methods: std.StringArrayHashMapUnmanaged(Method) = .empty,
    consts: std.StringArrayHashMapUnmanaged(Constant) = .empty,
    class: *object.Class,
    self_type: Type = .unknown,
    resolved: bool = false,

    pub fn field(s: *const Struct, name: []const u8) ?*const Field {
        for (s.fields.items) |*f| if (std.mem.eql(u8, f.name, name)) return f;
        return null;
    }

    pub fn method(s: *const Struct, name: []const u8) ?*const Method {
        var at: ?*const Struct = s;
        while (at) |x| : (at = x.parent) if (x.methods.getPtr(name)) |m| return m;
        return null;
    }

    pub fn constant(s: *const Struct, name: []const u8) ?*const Constant {
        var at: ?*const Struct = s;
        while (at) |x| : (at = x.parent) if (x.consts.getPtr(name)) |c| return c;
        return null;
    }

    pub fn extends(s: *const Struct, other: *const Struct) bool {
        var at: ?*const Struct = s;
        while (at) |x| : (at = x.parent) if (x == other) return true;
        return false;
    }
};

pub const Enum = struct {
    name: []const u8,
    file: diag.FileId,
    span: diag.Span,
    members: []const []const u8,
    /// Where each member is named.
    spans: []const diag.Span = &.{},
    methods: std.StringArrayHashMapUnmanaged(Method) = .empty,
    type_obj: *object.EnumType,
    self_type: Type = .unknown,

    pub fn index(e: *const Enum, name: []const u8) ?u32 {
        for (e.members, 0..) |m, i| if (std.mem.eql(u8, m, name)) return @intCast(i);
        return null;
    }
};

pub const Export = struct {
    type: Type,
    global: u32,
    value: ?@import("../vm/value.zig").Value,
    is_const: bool,
};

pub const GlobalKind = enum { variable, constant, function, @"struct", @"enum", import };

/// A declaration as a reload compares it with the one before.
pub const Global = struct {
    index: u32,
    kind: GlobalKind,
    span: diag.Span,
    /// What code compiled against it relies on: see `shape.zig`.
    shape: []const u8,
    /// A constant the compiler knows the value of, folded into code.
    folded: bool,
};

pub const Module = struct {
    name: []const u8,
    exports: std.StringArrayHashMapUnmanaged(Export) = .empty,
    object: *object.Module,
    /// Every declaration, those starting with `_` too.
    globals: std.StringArrayHashMapUnmanaged(Global) = .empty,
    /// Each method's shape, under `Struct.method`.
    members: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
};

pub const Info = union(enum) {
    list: Type,
    map: struct { key: Type, value: Type },
    optional: Type,
    error_union: Type,
    function: *const Signature,
    @"struct": *Struct,
    @"enum": *Enum,
    module: *Module,
    /// A type named where a value goes: `Player` in `Player.init()`.
    meta: Type,
};

pub const Pool = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    infos: std.ArrayList(Info) = .empty,

    pub fn init(gpa: Allocator) Pool {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(p: *Pool) void {
        p.infos.deinit(p.gpa);
        p.arena.deinit();
    }

    pub fn allocator(p: *Pool) Allocator {
        return p.arena.allocator();
    }

    pub fn info(p: *const Pool, t: Type) ?Info {
        const n = @intFromEnum(t);
        if (n < Type.first_pool) return null;
        return p.infos.items[n - Type.first_pool];
    }

    fn sameInfo(a: Info, b: Info) bool {
        return switch (a) {
            .list => |x| b == .list and b.list == x,
            .map => |x| b == .map and b.map.key == x.key and b.map.value == x.value,
            .optional => |x| b == .optional and b.optional == x,
            .error_union => |x| b == .error_union and b.error_union == x,
            .meta => |x| b == .meta and b.meta == x,
            .@"struct" => |x| b == .@"struct" and b.@"struct" == x,
            .@"enum" => |x| b == .@"enum" and b.@"enum" == x,
            .module => |x| b == .module and b.module == x,
            .function => |x| b == .function and sameSignature(x, b.function),
        };
    }

    fn sameSignature(a: *const Signature, b: *const Signature) bool {
        if (a.ret != b.ret or a.params.len != b.params.len or a.has_self != b.has_self or a.coroutine != b.coroutine) return false;
        for (a.params, b.params) |x, y| if (x.type != y.type or x.has_default != y.has_default) return false;
        return true;
    }

    pub fn intern(p: *Pool, i: Info) Allocator.Error!Type {
        for (p.infos.items, 0..) |existing, n| {
            if (sameInfo(existing, i)) return @enumFromInt(Type.first_pool + n);
        }
        try p.infos.append(p.gpa, i);
        return @enumFromInt(Type.first_pool + p.infos.items.len - 1);
    }

    pub fn list(p: *Pool, elem: Type) Allocator.Error!Type {
        return p.intern(.{ .list = elem });
    }

    pub fn map(p: *Pool, key: Type, value: Type) Allocator.Error!Type {
        return p.intern(.{ .map = .{ .key = key, .value = value } });
    }

    pub fn optional(p: *Pool, child: Type) Allocator.Error!Type {
        if (child == .any or child == .null or child == .unknown) return child;
        if (p.info(child)) |i| if (i == .optional) return child;
        return p.intern(.{ .optional = child });
    }

    pub fn errorUnion(p: *Pool, child: Type) Allocator.Error!Type {
        if (child == .any or child == .unknown) return child;
        if (p.info(child)) |i| if (i == .error_union) return child;
        return p.intern(.{ .error_union = child });
    }

    pub fn function(p: *Pool, sig: *const Signature) Allocator.Error!Type {
        return p.intern(.{ .function = sig });
    }

    pub fn meta(p: *Pool, t: Type) Allocator.Error!Type {
        return p.intern(.{ .meta = t });
    }

    pub fn isOptional(p: *const Pool, t: Type) ?Type {
        const i = p.info(t) orelse return null;
        return if (i == .optional) i.optional else null;
    }

    pub fn isErrorUnion(p: *const Pool, t: Type) ?Type {
        const i = p.info(t) orelse return null;
        return if (i == .error_union) i.error_union else null;
    }

    pub fn structOf(p: *const Pool, t: Type) ?*Struct {
        const i = p.info(t) orelse return null;
        return if (i == .@"struct") i.@"struct" else null;
    }

    pub fn enumOf(p: *const Pool, t: Type) ?*Enum {
        const i = p.info(t) orelse return null;
        return if (i == .@"enum") i.@"enum" else null;
    }

    pub fn listOf(p: *const Pool, t: Type) ?Type {
        const i = p.info(t) orelse return null;
        return if (i == .list) i.list else null;
    }

    pub fn mapOf(p: *const Pool, t: Type) ?struct { key: Type, value: Type } {
        const i = p.info(t) orelse return null;
        return if (i == .map) .{ .key = i.map.key, .value = i.map.value } else null;
    }

    pub fn signatureOf(p: *const Pool, t: Type) ?*const Signature {
        const i = p.info(t) orelse return null;
        return if (i == .function) i.function else null;
    }

    pub fn metaOf(p: *const Pool, t: Type) ?Type {
        const i = p.info(t) orelse return null;
        return if (i == .meta) i.meta else null;
    }

    pub fn moduleOf(p: *const Pool, t: Type) ?*Module {
        const i = p.info(t) orelse return null;
        return if (i == .module) i.module else null;
    }

    /// Whether a value of type `t` may be null.
    pub fn nullable(p: *const Pool, t: Type) bool {
        return t == .any or t == .null or t == .unknown or p.isOptional(t) != null;
    }

    pub fn isDynamic(t: Type) bool {
        return t == .any or t == .unknown;
    }

    pub fn write(p: *const Pool, t: Type, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (t) {
            .unknown => try w.writeAll("?"),
            .never => try w.writeAll("noreturn"),
            .@"error" => try w.writeAll("error"),
            .any, .void, .null, .bool, .int, .float, .string, .vec2, .vec3, .color, .task, .signal => try w.writeAll(@tagName(t)),
            _ => switch (p.info(t).?) {
                .list => |e| {
                    try w.writeByte('[');
                    try p.write(e, w);
                    try w.writeByte(']');
                },
                .map => |kv| {
                    try w.writeByte('[');
                    try p.write(kv.key, w);
                    try w.writeAll(": ");
                    try p.write(kv.value, w);
                    try w.writeByte(']');
                },
                .optional => |c| {
                    try w.writeByte('?');
                    try p.write(c, w);
                },
                .error_union => |c| {
                    try w.writeByte('!');
                    try p.write(c, w);
                },
                .function => |s| {
                    try w.writeAll("fn(");
                    for (s.params, 0..) |param, i| {
                        if (i > 0) try w.writeAll(", ");
                        try p.write(param.type, w);
                    }
                    try w.writeByte(')');
                    if (s.ret != .void) {
                        try w.writeByte(' ');
                        try p.write(s.ret, w);
                    }
                    if (s.coroutine) try w.writeAll(" (awaits)");
                },
                .@"struct" => |s| try w.writeAll(s.name),
                .@"enum" => |e| try w.writeAll(e.name),
                .module => |m| try w.print("module {s}", .{m.name}),
                .meta => |x| {
                    try w.writeAll("type ");
                    try p.write(x, w);
                },
            },
        }
    }

    /// The type's name, in a buffer the pool owns until it is freed.
    pub fn name(p: *Pool, t: Type) []const u8 {
        var out: std.Io.Writer.Allocating = .init(p.allocator());
        p.write(t, &out.writer) catch return "?";
        return out.written();
    }

    /// The run-time check a value must pass to be stored as `t`.
    pub fn check(p: *Pool, checks: *rt.Table, gpa: Allocator, t: Type) Allocator.Error!rt.Check {
        return switch (t) {
            .unknown, .any, .void, .never => .any,
            .null => .null,
            .bool => .bool,
            .int => .int,
            .float => .float,
            .string => .string,
            .vec2 => .vec2,
            .vec3 => .vec3,
            .color => .color,
            .@"error" => .@"error",
            .task => .task,
            .signal => .signal,
            _ => switch (p.info(t).?) {
                .list => |e| try checks.add(gpa, .{ .list_of = try p.check(checks, gpa, e) }),
                .map => |kv| try checks.add(gpa, .{ .map_of = .{ .key = try p.check(checks, gpa, kv.key), .value = try p.check(checks, gpa, kv.value) } }),
                .optional => |c| try checks.add(gpa, .{ .optional = try p.check(checks, gpa, c) }),
                .error_union => |c| try checks.add(gpa, .{ .error_union = try p.check(checks, gpa, c) }),
                .function => .function,
                .@"struct" => |s| try checks.add(gpa, .{ .class = s.class }),
                .@"enum" => |e| try checks.add(gpa, .{ .enum_type = e.type_obj }),
                .module, .meta => .any,
            },
        };
    }
};
