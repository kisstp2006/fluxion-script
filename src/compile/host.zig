// SPDX-License-Identifier: BSD-2-Clause

//! What the compiler knows of a value the host gives - `app`, `self.entity`,
//! what a call of the host's gives back - by the host's reflected type: its
//! fields to read, and its methods, with their parameters. A call of one of
//! them is checked as a script function's is: how many arguments - the last
//! ones may be left out where the method gives them defaults - and those a
//! script can give only one way, a number, a string, a flag.
//!
//! The value itself stays `any` to everything else. A host's value has
//! members its type does not list - a component's signals, the words it
//! keeps beside it - and takes values its host converts, a path for a
//! texture; neither is the compiler's to refuse.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const reflect = @import("fluxion_reflect");
const Vm = @import("../vm/Vm.zig");
const Value = @import("../vm/value.zig").Value;
const object = @import("../vm/object.zig");
const bridge = @import("../reflect.zig");
const types = @import("types.zig");
const Type = types.Type;

pub const Host = struct {
    type: *const reflect.Type,
    /// Certainly of this type, so a call on it is checked. A variable's,
    /// which may be given another value, is offered and not checked.
    sure: bool = true,
};

/// The host's type of a handle, as its value was made.
pub fn ofValue(v: Value) ?*const reflect.Type {
    if (v.tag != .handle) return null;
    return v.as(object.Handle).value.type;
}

/// What the host said a global it gives is: declared, where the scripts are
/// only compiled, or the type of the handle it defined.
pub fn ofGlobal(vm: *const Vm, name: []const u8, v: Value) ?Host {
    if (vm.global_types.get(name)) |t| return .{ .type = t };
    return .{ .type = ofValue(v) orelse return null };
}

/// A value of the host's type `t` as a script is handed it: of what type to
/// the compiler, and of what type of the host's to know its members by.
pub const Seen = struct {
    type: Type = .any,
    host: ?*const reflect.Type = null,
};

pub fn seen(vm: *const Vm, t: *const reflect.Type) Seen {
    if (bridge.hostType(vm, t)) |h| return .{ .host = h.script };
    if (t.is(Value) or t.is(*Vm)) return .{};
    return switch (t.kind) {
        .bool => .{ .type = .bool },
        .int => .{ .type = .int },
        .float => .{ .type = .float },
        // What may be null, or an error, is the compiler's `any`: a script
        // that did not ask before is not refused now. Its members are known.
        .optional, .error_union => .{ .host = seen(vm, t.child() orelse return .{}).host },
        .pointer => if (t.isString()) .{ .type = .string } else if (t.info.pointer.size == .one) seen(vm, t.info.pointer.child) else .{},
        .slice, .array => if (t.isString()) .{ .type = .string } else .{},
        .@"struct" => switch (bridge.vectorLength(t) orelse 0) {
            2 => .{ .type = .vec2 },
            3 => .{ .type = .vec3 },
            else => .{ .host = t },
        },
        .@"union", .@"opaque" => .{ .host = t },
        else => .{},
    };
}

/// What an argument of the host's type `t` must be, where a script can give
/// it only one way; `any` where the host takes more than one.
fn wanted(vm: *const Vm, t: *const reflect.Type) Type {
    if (bridge.hostType(vm, t) != null) return .any;
    return switch (t.kind) {
        .bool => .bool,
        .int => .int,
        .float => .float,
        .pointer, .slice, .array => if (t.isString()) .string else .any,
        else => .any,
    };
}

/// The host's type `t` written as a script sees it: `int`, `string`,
/// `?Rect2`, the host's name for a type of its own.
pub fn write(vm: *const Vm, w: *Writer, t: *const reflect.Type) Writer.Error!void {
    if (bridge.hostType(vm, t)) |h| return w.writeAll(nameOf(h.script orelse t));
    if (t.is(Value)) return w.writeAll("any");
    switch (t.kind) {
        .bool => try w.writeAll("bool"),
        .int => try w.writeAll("int"),
        .float => try w.writeAll("float"),
        .optional => {
            try w.writeByte('?');
            try write(vm, w, t.child().?);
        },
        .error_union => {
            try w.writeByte('!');
            try write(vm, w, t.child().?);
        },
        .pointer => if (t.isString()) try w.writeAll("string") else if (t.info.pointer.size == .one) try write(vm, w, t.info.pointer.child) else try w.writeAll("list"),
        .slice, .array => if (t.isString()) try w.writeAll("string") else {
            try w.writeByte('[');
            try write(vm, w, t.child().?);
            try w.writeByte(']');
        },
        .@"struct" => switch (bridge.vectorLength(t) orelse 0) {
            2 => try w.writeAll("vec2"),
            3 => try w.writeAll("vec3"),
            else => try w.writeAll(nameOf(t)),
        },
        .@"enum" => try w.writeAll("string"),
        else => try w.writeAll(nameOf(t)),
    }
}

/// A type's own name, without the file it is in.
pub fn nameOf(t: *const reflect.Type) []const u8 {
    const full = t.name.slice();
    const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[dot + 1 ..];
}

/// The field `name` of the host's type `t` a script reads, where the type
/// lists it.
pub fn field(t: *const reflect.Type, name: []const u8) ?*const reflect.Field {
    if (t.kind != .@"struct" and t.kind != .@"union") return null;
    return t.field(name);
}

pub fn method(t: *const reflect.Type, name: []const u8) ?*const reflect.Method {
    return t.method(name);
}

/// A method's parameters a script gives: those after `self`, the VM calling
/// it aside.
pub fn given(m: *const reflect.Method, owner: *const reflect.Type) []const reflect.Param {
    const params = m.type.info.function.params.slice();
    return if (m.takesSelf(owner)) params[1..] else params;
}

/// The method `m` of `owner` as a signature the compiler checks a call by
/// and an editor shows, made in `arena`.
pub fn signature(vm: *const Vm, arena: Allocator, m: *const reflect.Method, owner: *const reflect.Type) Allocator.Error!*types.Signature {
    const all = given(m, owner);
    var shown: std.ArrayList(types.Param) = .empty;
    const names = m.paramNames();
    const defaults = m.defaultArgs();
    const first_default = all.len - @min(defaults.len, all.len);
    var visible: usize = 0;
    for (all) |p| {
        if (!p.type.is(*Vm)) visible += 1;
    }
    var seen_visible: usize = 0;
    for (all, 0..) |p, i| {
        if (p.type.is(*Vm)) continue;
        defer seen_visible += 1;
        // The names cover every parameter after `self`, or those a script
        // gives.
        const name = if (names) |n| (if (n.len == all.len) n[i] else if (n.len == visible and seen_visible < n.len) n[seen_visible] else "") else "";
        var text: Writer.Allocating = .init(arena);
        write(vm, &text.writer, p.type) catch return error.OutOfMemory;
        const has_default = i >= first_default;
        try shown.append(arena, .{
            .name = if (name.len > 0) name else try std.fmt.allocPrint(arena, "arg{d}", .{seen_visible + 1}),
            .type = wanted(vm, p.type),
            .has_default = has_default,
            .default_text = if (has_default) try defaultText(arena, defaults[i - first_default]) else null,
            .type_text = text.written(),
        });
    }
    const ret = m.type.info.function.return_type;
    var ret_text: Writer.Allocating = .init(arena);
    if (ret.kind != .void) write(vm, &ret_text.writer, ret) catch return error.OutOfMemory;
    const sig = try arena.create(types.Signature);
    sig.* = .{ .params = shown.items, .ret = seen(vm, ret).type, .ret_text = ret_text.written() };
    return sig;
}

/// A default as it would be written: `""`, `1.0`, `false`, `"linear"`.
fn defaultText(arena: Allocator, d: reflect.attr.Defaults.Default) Allocator.Error![]const u8 {
    const v: reflect.Value = .initConst(d.type, d.value);
    const t = d.type;
    switch (t.kind) {
        .bool => return if (v.toBool() orelse false) "true" else "false",
        .int => return std.fmt.allocPrint(arena, "{d}", .{v.toInt(i64) orelse 0}),
        .float => {
            const x = v.toFloat(f64) orelse 0;
            if (x == @trunc(x) and @abs(x) < 1e15) return std.fmt.allocPrint(arena, "{d}.0", .{x});
            return std.fmt.allocPrint(arena, "{d}", .{x});
        },
        .@"enum" => if (v.wideInt()) |n| if (t.memberOf(@bitCast(@as(i64, @truncate(n))))) |member| {
            return std.fmt.allocPrint(arena, "\"{s}\"", .{member.name.slice()});
        },
        else => if (t.isString()) if (v.toString()) |s| return std.fmt.allocPrint(arena, "\"{s}\"", .{s}),
    }
    return "...";
}

/// How a host's method is shown: `fn AnimatedSprite2D.play(name: string =
/// "", custom_speed: float = 1.0) bool`.
pub fn methodDetail(vm: *const Vm, arena: Allocator, m: *const reflect.Method, owner: *const reflect.Type) Allocator.Error![]const u8 {
    const sig = try signature(vm, arena, m, owner);
    var out: Writer.Allocating = .init(arena);
    writeSignature(&out.writer, nameOf(owner), m.name.slice(), sig) catch return error.OutOfMemory;
    return out.written();
}

pub fn writeSignature(w: *Writer, owner: []const u8, name: []const u8, sig: *const types.Signature) Writer.Error!void {
    try w.print("fn {s}.{s}(", .{ owner, name });
    for (sig.params, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("{s}: {s}", .{ p.name, p.type_text orelse "any" });
        if (p.default_text) |d| try w.print(" = {s}", .{d});
    }
    try w.writeByte(')');
    if (sig.ret_text) |r| if (r.len > 0) try w.print(" {s}", .{r});
}

/// How a host's field is shown: `AnimatedSprite2D.frame: int`.
pub fn fieldDetail(vm: *const Vm, arena: Allocator, f: *const reflect.Field, owner: *const reflect.Type) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    out.writer.print("{s}.{s}: ", .{ nameOf(owner), f.name.slice() }) catch return error.OutOfMemory;
    write(vm, &out.writer, f.type) catch return error.OutOfMemory;
    return out.written();
}

/// What the host said of a member: its `attr.Doc`.
pub fn docOf(attributes: anytype) ?[]const u8 {
    const d = attributes.attribute(reflect.attr.Doc) orelse return null;
    return d.text;
}

/// Whether a field is kept out of a person's view: `attr.Hidden`.
pub fn hidden(f: *const reflect.Field) bool {
    return f.attribute(reflect.attr.Hidden) != null;
}
