// SPDX-License-Identifier: BSD-2-Clause

//! A compiled module as bytes, and a module again from them: what a program
//! ships instead of its scripts' source.
//!
//! An image holds what `compile` made - the module's prototypes with their
//! code and constants, its structs, enums and functions, its variables - and
//! none of the source: no comments, no layout, and, saved without `lines`,
//! not even where a line began. Loading one is `compile` without the
//! compiler: nothing is parsed or checked again, and the module is ready to
//! `run`. `compile` itself knows an image by its first four bytes and loads
//! it, so a host that hands scripts' bytes to the VM needs to know nothing.
//!
//! **What the module does not own it names.** A struct, an enum or a
//! function of another module is written as that module's name and the name
//! it has there; what the host put in the prelude, by its name there; one of
//! the host's types, by its reflected name, which is the same in every
//! build. Loading finds each again, in a VM set up the way the saving one
//! was, and a thing it cannot find is an error that names it. The modules an
//! image imports are loaded first: those already in the VM as they are, the
//! rest through the loader, which must give images too.
//!
//! **A check is written as what it checks**, not as the saving VM's number
//! for it, and made again in the loading VM's table; the code's numbers for
//! checks and for the host's types are rewritten on the way out and back.
//!
//! **An image runs only on the instruction set it was made for.** The
//! header carries a hash of the opcodes' names, so a VM whose instructions
//! have moved refuses it rather than run one instruction as another.
//!
//! **An image is trusted like code.** Loading checks that the image holds
//! together - every object, check and type it refers to is one it has - but
//! not that its code is code the compiler could have made. Load images this
//! program made, or ones that came to it signed.
//!
//! ```
//! FXSC           four bytes
//! version        one byte: the container's own
//! code           eight bytes: the hash of the instruction set
//! flags          one byte: whether the lines were kept
//! name           the name the module was compiled under
//! imports        the names of the modules it imports
//! lines          each line's length in bytes, when kept
//! host types     the host's types it names: each one's id and name
//! objects        every object it owns or refers to, each its kind and bytes
//! checks         every check its code and its objects use
//! globals        its variables, each a name and a value
//! main           the object that is its top level
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

const reflect = @import("fluxion_reflect");

const diag = @import("diag.zig");
const Vm = @import("vm/Vm.zig");
const Value = @import("vm/value.zig").Value;
const object = @import("vm/object.zig");
const make = @import("vm/make.zig");
const code = @import("vm/code.zig");
const types = @import("vm/types.zig");
const bridge = @import("reflect.zig");

pub const magic = "FXSC";

/// The container's own version. It changes when the layout above does.
pub const format_version: u8 = 1;

/// The instruction set an image's code is written in, as a number: a hash of
/// the opcodes' names in their order. Moving, adding or renaming an opcode
/// changes it, and an image made before refuses to load after.
pub const code_version: u64 = blk: {
    @setEvalBranchQuota(20_000);
    var hash = std.hash.Wyhash.init(0);
    for (@typeInfo(code.Op).@"enum".fields) |field| {
        hash.update(field.name);
        hash.update(";");
    }
    break :blk hash.final();
};

pub const SaveOptions = struct {
    /// Keep where each instruction came from, so an error names its line, and
    /// the names of parameters and signals' parameters. Without it an error
    /// names only the function it was in.
    lines: bool = true,
};

/// `error.Unsaveable` when the module holds something no other VM could find
/// again - a closure over a variable, a value the host made that has no name
/// - and `vm.diagnostics` says what.
pub const SaveError = error{ OutOfMemory, Unsaveable };

/// `error.CompileFailed` for an image that cannot be loaded here, with the
/// reason in `vm.diagnostics`, as a compile's.
pub const LoadError = error{ OutOfMemory, CompileFailed };

/// Whether `bytes` are an image rather than source.
pub fn isImage(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, magic);
}

const Flags = packed struct(u8) {
    lines: bool,
    unused: u7 = 0,
};

/// What an entry in the objects list is.
const Kind = enum(u8) {
    // Owned by the module, and written out whole.
    string,
    proto,
    closure,
    class,
    enum_type,
    list,
    map,
    color,
    error_value,
    this_module,
    // Somewhere else, and named.
    module,
    prelude,
    global,
    static,
    method,
    enum_method,
    host_enum,
};

/// How a value is written: its tag's byte.
const ValueTag = enum(u8) {
    null,
    false,
    true,
    int,
    float,
    vec2,
    vec3,
    undefined,
    enum_value,
    host_type,
    object,
};

/// How a check in the table is written.
const CheckKind = enum(u8) {
    optional,
    list_of,
    map_of,
    class,
    enum_type,
    error_union,
    function,
    host,
};

// -------------------------------------------------------------------------
// Bytes
// -------------------------------------------------------------------------

const Out = struct {
    gpa: Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn deinit(o: *Out) void {
        o.bytes.deinit(o.gpa);
    }

    fn byte(o: *Out, b: u8) Allocator.Error!void {
        try o.bytes.append(o.gpa, b);
    }

    fn uint(o: *Out, n: u64) Allocator.Error!void {
        var left = n;
        while (left >= 0x80) : (left >>= 7) try o.byte(@as(u8, @truncate(left)) | 0x80);
        try o.byte(@truncate(left));
    }

    fn int(o: *Out, n: i64) Allocator.Error!void {
        try o.uint(@bitCast((n << 1) ^ (n >> 63)));
    }

    fn fixed(o: *Out, comptime T: type, n: T) Allocator.Error!void {
        var buffer: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buffer, n, .little);
        try o.bytes.appendSlice(o.gpa, &buffer);
    }

    fn blob(o: *Out, b: []const u8) Allocator.Error!void {
        try o.uint(b.len);
        try o.bytes.appendSlice(o.gpa, b);
    }
};

const In = struct {
    bytes: []const u8,
    at: usize = 0,

    const Error = error{Damaged};

    fn byte(i: *In) Error!u8 {
        if (i.at >= i.bytes.len) return error.Damaged;
        defer i.at += 1;
        return i.bytes[i.at];
    }

    fn uint(i: *In) Error!u64 {
        var n: u64 = 0;
        var shift: u7 = 0;
        while (shift < 64) : (shift += 7) {
            const b = try i.byte();
            n |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) return n;
        }
        return error.Damaged;
    }

    fn int(i: *In) Error!i64 {
        const n = try i.uint();
        return @bitCast((n >> 1) ^ (0 -% (n & 1)));
    }

    fn fixed(i: *In, comptime T: type) Error!T {
        const b = try i.take(@sizeOf(T));
        return std.mem.readInt(T, b[0..@sizeOf(T)], .little);
    }

    fn take(i: *In, n: usize) Error![]const u8 {
        if (n > i.bytes.len - i.at) return error.Damaged;
        defer i.at += n;
        return i.bytes[i.at..][0..n];
    }

    fn blob(i: *In) Error![]const u8 {
        return i.take(try i.count());
    }

    /// A length, bounded by what is left: no count can promise more items
    /// than there are bytes to hold them.
    fn count(i: *In) Error!usize {
        const n = try i.uint();
        if (n > i.bytes.len - i.at) return error.Damaged;
        return @intCast(n);
    }

    fn flag(i: *In) Error!bool {
        return switch (try i.byte()) {
            0 => false,
            1 => true,
            else => error.Damaged,
        };
    }
};

// -------------------------------------------------------------------------
// Saving
// -------------------------------------------------------------------------

/// `module` as an image. The caller frees it.
pub fn save(vm: *Vm, module: *object.Module, gpa: Allocator, options: SaveOptions) SaveError![]u8 {
    // Nothing the image names may go while it is written: what is interned
    // for it is held by nothing else.
    vm.heap.paused += 1;
    defer vm.heap.paused -= 1;
    var s: Saver = .{ .vm = vm, .gpa = gpa, .module = module, .options = options };
    defer s.deinit();
    return s.run() catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unsaveable => {
            if (s.why) |why| _ = try vm.diagnostics.err(.{ .file = module.file, .span = .empty }, "cannot save `{s}` compiled: {s}", .{ module.path, why });
            return error.Unsaveable;
        },
    };
}

/// Where something the module does not own is found by name.
const Ref = union(enum) {
    module: []const u8,
    prelude: *object.String,
    global: struct { owner: *object.Obj, name: *object.String },
    static: struct { owner: *object.Obj, name: *object.String },
    method: struct { owner: *object.Obj, name: *object.String },
    enum_method: struct { owner: *object.Obj, name: *object.String },
};

const Saver = struct {
    vm: *Vm,
    gpa: Allocator,
    module: *object.Module,
    options: SaveOptions,
    /// Every object met, by the number it is written under.
    ids: std.AutoHashMapUnmanaged(*object.Obj, u32) = .empty,
    queue: std.ArrayList(*object.Obj) = .empty,
    checks: Out = undefined,
    check_count: u32 = 0,
    check_ids: std.AutoHashMapUnmanaged(types.Check, u32) = .empty,
    host_types: std.ArrayList(*const reflect.Type) = .empty,
    /// Where each thing the module does not own can be found, built the
    /// first time one is met.
    names: ?std.AutoHashMapUnmanaged(*object.Obj, Ref) = null,
    known: ?Known = null,
    why: ?[]const u8 = null,
    why_buffer: [256]u8 = undefined,

    const Error = error{ OutOfMemory, Unsaveable };

    fn deinit(s: *Saver) void {
        s.ids.deinit(s.gpa);
        s.queue.deinit(s.gpa);
        s.check_ids.deinit(s.gpa);
        s.host_types.deinit(s.gpa);
        if (s.names) |*n| n.deinit(s.gpa);
        if (s.known) |*k| k.deinit(s.gpa);
    }

    fn fail(s: *Saver, comptime fmt: []const u8, args: anytype) Error {
        s.why = std.fmt.bufPrint(&s.why_buffer, fmt, args) catch s.why_buffer[0..];
        return error.Unsaveable;
    }

    fn run(s: *Saver) Error![]u8 {
        s.checks = .{ .gpa = s.gpa };
        defer s.checks.deinit();

        var globals: Out = .{ .gpa = s.gpa };
        defer globals.deinit();
        const module = s.module;
        try globals.uint(module.globals.items.len);
        for (module.names.items, module.globals.items) |name, v| {
            try globals.uint(try s.id(&name.obj));
            try s.value(&globals, v);
        }
        const main = module.main orelse return s.fail("it was never compiled whole", .{});
        // Its variables hold what running it gave them, which is not what
        // loading it again and running it would.
        if (module.ran) return s.fail("it has run already; an image is saved as compile left the module", .{});
        const main_id = try s.id(&main.obj);

        var objects: Out = .{ .gpa = s.gpa };
        defer objects.deinit();
        var piece: Out = .{ .gpa = s.gpa };
        defer piece.deinit();
        // Writing one object can meet more: they join the queue, and the loop
        // goes on until nothing new is met.
        var at: usize = 0;
        while (at < s.queue.items.len) : (at += 1) {
            piece.bytes.clearRetainingCapacity();
            const kind = try s.writeObject(&piece, s.queue.items[at]);
            try objects.byte(@intFromEnum(kind));
            try objects.blob(piece.bytes.items);
        }

        var out: Out = .{ .gpa = s.gpa };
        errdefer out.deinit();
        try out.bytes.appendSlice(s.gpa, magic);
        try out.byte(format_version);
        try out.fixed(u64, code_version);
        try out.byte(@bitCast(Flags{ .lines = s.options.lines }));
        try out.blob(module.path);

        try out.uint(module.imports.items.len);
        for (module.imports.items) |imported| try out.blob(try s.moduleName(imported));

        if (s.options.lines) {
            const text = if (s.vm.sources.get(module.file)) |f| f.text else "";
            try out.uint(std.mem.count(u8, text, "\n") + 1);
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| try out.uint(line.len);
        }

        try out.uint(s.host_types.items.len);
        for (s.host_types.items) |t| {
            try out.fixed(u64, t.id);
            try out.blob(t.name.slice());
        }

        try out.uint(s.queue.items.len);
        try out.bytes.appendSlice(s.gpa, objects.bytes.items);
        try out.uint(s.check_count);
        try out.bytes.appendSlice(s.gpa, s.checks.bytes.items);
        try out.bytes.appendSlice(s.gpa, globals.bytes.items);
        try out.uint(main_id);
        return out.bytes.toOwnedSlice(s.gpa);
    }

    /// The number `o` is written under, met now if it was not before.
    fn id(s: *Saver, o: *object.Obj) Error!u32 {
        const got = try s.ids.getOrPut(s.gpa, o);
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(s.queue.items.len);
            try s.queue.append(s.gpa, o);
        }
        return got.value_ptr.*;
    }

    fn optionalId(s: *Saver, out: *Out, o: ?*object.Obj) Error!void {
        if (o) |x| try out.uint(@as(u64, try s.id(x)) + 1) else try out.uint(0);
    }

    fn value(s: *Saver, out: *Out, v: Value) Error!void {
        switch (v.tag) {
            .null => try out.byte(@intFromEnum(ValueTag.null)),
            .bool => try out.byte(@intFromEnum(if (v.asBool()) ValueTag.true else ValueTag.false)),
            .int => {
                try out.byte(@intFromEnum(ValueTag.int));
                try out.int(v.asInt());
            },
            .float => {
                try out.byte(@intFromEnum(ValueTag.float));
                try out.fixed(u64, v.raw);
            },
            .vec2 => {
                try out.byte(@intFromEnum(ValueTag.vec2));
                try out.fixed(u64, v.raw);
            },
            .vec3 => {
                try out.byte(@intFromEnum(ValueTag.vec3));
                try out.fixed(u64, v.raw);
                try out.fixed(u32, v.extra);
            },
            .undefined => try out.byte(@intFromEnum(ValueTag.undefined)),
            .enum_value => {
                try out.byte(@intFromEnum(ValueTag.enum_value));
                try out.uint(try s.id(v.obj()));
                try out.uint(v.extra);
            },
            .host_type => {
                try out.byte(@intFromEnum(ValueTag.host_type));
                try out.uint(try s.hostType(v.asHostType()));
            },
            .string, .list, .map, .instance, .function, .native, .method, .class, .enum_type, .module, .task, .signal, .@"error", .color, .handle => {
                try out.byte(@intFromEnum(ValueTag.object));
                try out.uint(try s.id(v.obj()));
            },
            .range, _ => return s.fail("it holds a value that is not one a script keeps", .{}),
        }
    }

    /// Writes one object's bytes into `out`, and says what kind it is.
    fn writeObject(s: *Saver, out: *Out, o: *object.Obj) Error!Kind {
        switch (o.kind) {
            .string => {
                // The payload is the text: the entry's length is its length.
                try out.bytes.appendSlice(s.gpa, object.String.from(o).bytes());
                return .string;
            },
            .proto => {
                const p = object.Proto.from(o);
                if (p.module != s.module) return s.fail("it holds a function of another module that has no name", .{});
                try s.proto(out, p);
                return .proto;
            },
            .closure => {
                const c = object.Closure.from(o);
                if (c.proto.module == s.module) {
                    if (c.count != 0) return s.fail("it holds a function that has captured a variable", .{});
                    try out.uint(try s.id(&c.proto.obj));
                    return .closure;
                }
                return s.ref(out, o);
            },
            .class => {
                const c = object.Class.from(o);
                if (c.module != s.module) return s.ref(out, o);
                try s.class(out, c);
                return .class;
            },
            .enum_type => {
                const e = object.EnumType.from(o);
                if (e.host) |host| {
                    try out.uint(try s.hostType(host));
                    try out.blob(e.name.bytes());
                    return .host_enum;
                }
                if (e.module != s.module) return s.ref(out, o);
                try out.uint(try s.id(&e.name.obj));
                try out.uint(e.members.len);
                for (e.members, e.values) |m, n| {
                    try out.uint(try s.id(&m.obj));
                    try out.int(n);
                }
                try s.members(out, &e.methods);
                return .enum_type;
            },
            .list => {
                const l = object.List.from(o);
                try out.uint(try s.check(l.elem));
                try out.uint(l.items.items.len);
                for (l.items.items) |item| try s.value(out, item);
                return .list;
            },
            .map => {
                const m = object.Map.from(o);
                try out.uint(try s.check(m.key));
                try out.uint(try s.check(m.value));
                try out.uint(m.table.count());
                var it = m.table.iterator();
                while (it.next()) |e| {
                    try s.value(out, e.key);
                    try s.value(out, e.value);
                }
                return .map;
            },
            .color => {
                for (object.Color.from(o).rgba) |c| try out.fixed(u32, @bitCast(c));
                return .color;
            },
            .error_value => {
                const e = object.ErrorValue.from(o);
                try out.uint(try s.id(&e.name.obj));
                try s.optionalId(out, if (e.message) |m| &m.obj else null);
                return .error_value;
            },
            .module => {
                if (o == &s.module.obj) return .this_module;
                return s.ref(out, o);
            },
            else => return s.ref(out, o),
        }
    }

    fn proto(s: *Saver, out: *Out, p: *object.Proto) Error!void {
        try out.uint(try s.id(&p.name.obj));
        try out.byte(p.params);
        try out.byte(p.required);
        try out.byte(p.regs);
        try out.byte(@intFromBool(p.has_self));
        try out.byte(@intFromBool(p.coroutine));
        try out.uint(p.fast_entry);
        try out.uint(try s.check(p.returns));
        try out.uint(p.param_checks.len);
        for (p.param_checks) |c| try out.uint(try s.check(c));
        try out.uint(p.param_names.len);
        for (p.param_names, 0..) |n, i| {
            if (s.options.lines) {
                try out.uint(try s.id(&n.obj));
            } else {
                var buffer: [16]u8 = undefined;
                const kept = try s.vm.intern(std.fmt.bufPrint(&buffer, "_{d}", .{i}) catch unreachable);
                try out.uint(try s.id(&kept.obj));
            }
        }
        try s.optionalId(out, if (p.class) |c| &c.obj else null);

        // The code, with the saving VM's numbers for checks and host types
        // turned into the image's.
        try out.uint(p.code.len);
        var i: usize = 0;
        while (i < p.code.len) {
            const instr = code.Instr.of(p.code[i]);
            var word = instr;
            switch (instr.op) {
                .check, .check_param => word = .abx(instr.op, instr.a, @intCast(try s.check(@enumFromInt(instr.bx())))),
                .newmap => word = .abc(.newmap, instr.a, @intCast(try s.check(@enumFromInt(instr.b))), @intCast(try s.check(@enumFromInt(instr.c)))),
                .from_string => word = .abx(.from_string, instr.a, @intCast(try s.hostType(s.vm.options.host_types[instr.bx()].type))),
                else => {},
            }
            try out.fixed(u32, word.word());
            const width = code.width(instr.op);
            if (width == 2) {
                const second = p.code[i + 1];
                const kept: u32 = switch (instr.op) {
                    .is, .newlist => try s.check(@enumFromInt(second)),
                    else => second,
                };
                try out.fixed(u32, kept);
            }
            i += width;
        }

        if (s.options.lines) {
            try out.uint(p.spans.len);
            for (p.spans) |span| {
                try out.uint(span.start);
                try out.uint(span.end);
            }
            try out.uint(p.decl.start);
            try out.uint(p.decl.end);
        } else try out.uint(0);

        try out.uint(p.constants.len);
        for (p.constants) |k| try s.value(out, k);
        try out.uint(p.protos.len);
        for (p.protos) |inner| try out.uint(try s.id(&inner.obj));
        try out.uint(p.upvals.len);
        for (p.upvals) |u| {
            try out.byte(@intFromBool(u.from_parent_local));
            try out.byte(u.index);
        }
        try out.uint(p.caches.len);
    }

    fn class(s: *Saver, out: *Out, c: *object.Class) Error!void {
        try out.uint(try s.id(&c.name.obj));
        try s.optionalId(out, if (c.parent) |p| &p.obj else null);
        try s.optionalId(out, if (c.defaults) |d| &d.obj else null);
        try s.optionalId(out, if (c.annotations) |a| &a.obj else null);
        try out.byte(@intFromBool(c.has_signals));
        try out.uint(c.fields.len);
        for (c.fields) |f| {
            try out.uint(try s.id(&f.name.obj));
            try out.uint(try s.check(f.check));
            try s.value(out, f.default);
            try out.byte(@as(u8, @intFromBool(f.exported)) |
                @as(u8, @intFromBool(f.is_const)) << 1 |
                @as(u8, @intFromBool(f.is_signal)) << 2 |
                @as(u8, @intFromBool(f.computed)) << 3 |
                @as(u8, @intFromBool(f.host)) << 4);
            try s.optionalId(out, if (f.annotations) |a| &a.obj else null);
            const signature = if (s.options.lines) f.signature else null;
            if (signature) |text| {
                try out.byte(1);
                try out.blob(text);
            } else try out.byte(0);
        }
        try s.members(out, &c.methods);
        try s.members(out, &c.statics);
    }

    fn members(s: *Saver, out: *Out, table: *const std.AutoHashMapUnmanaged(*object.String, Value)) Error!void {
        try out.uint(table.count());
        var it = table.iterator();
        while (it.next()) |e| {
            try out.uint(try s.id(&e.key_ptr.*.obj));
            try s.value(out, e.value_ptr.*);
        }
    }

    /// Writes where `o` is found by name, and says what kind of name that is.
    fn ref(s: *Saver, out: *Out, o: *object.Obj) Error!Kind {
        const names = try s.nameIndex();
        const r = names.get(o) orelse return s.fail("it holds {s} that no other program could find by name", .{describe(o)});
        switch (r) {
            .module => |name| {
                try out.blob(name);
                return .module;
            },
            .prelude => |name| {
                try out.blob(name.bytes());
                return .prelude;
            },
            inline .global, .static, .method, .enum_method => |at, tag| {
                try out.uint(try s.id(at.owner));
                try out.blob(at.name.bytes());
                return @field(Kind, @tagName(tag));
            },
        }
    }

    fn moduleName(s: *Saver, m: *object.Module) Error![]const u8 {
        const names = try s.nameIndex();
        const r = names.get(&m.obj) orelse return s.fail("it imports a module that is not in the VM", .{});
        return r.module;
    }

    /// Where everything that has a name outside the module is found: the
    /// prelude, the host's modules, and every other module's variables,
    /// structs' members and enums' methods.
    fn nameIndex(s: *Saver) Error!*const std.AutoHashMapUnmanaged(*object.Obj, Ref) {
        if (s.names) |*n| return n;
        var names: std.AutoHashMapUnmanaged(*object.Obj, Ref) = .empty;
        errdefer names.deinit(s.gpa);
        const vm = s.vm;

        var prelude = vm.prelude.iterator();
        while (prelude.next()) |e| if (e.value_ptr.isObject()) {
            const got = try names.getOrPut(s.gpa, e.value_ptr.obj());
            if (!got.found_existing) got.value_ptr.* = .{ .prelude = e.key_ptr.* };
        };
        var natives = vm.native_modules.iterator();
        while (natives.next()) |e| try nameModule(s.gpa, &names, e.key_ptr.*, e.value_ptr.*);
        var modules = vm.modules.iterator();
        while (modules.next()) |e| if (e.value_ptr.* != s.module) try nameModule(s.gpa, &names, e.key_ptr.*, e.value_ptr.*);

        s.names = names;
        return &s.names.?;
    }

    fn nameModule(gpa: Allocator, names: *std.AutoHashMapUnmanaged(*object.Obj, Ref), name: []const u8, m: *object.Module) Allocator.Error!void {
        try names.put(gpa, &m.obj, .{ .module = name });
        for (m.names.items, m.globals.items) |global_name, v| {
            if (!v.isObject()) continue;
            const got = try names.getOrPut(gpa, v.obj());
            if (!got.found_existing) got.value_ptr.* = .{ .global = .{ .owner = &m.obj, .name = global_name } };
            switch (v.tag) {
                .class => {
                    const c = v.as(object.Class);
                    try nameMembers(gpa, names, &c.obj, &c.methods, .method);
                    try nameMembers(gpa, names, &c.obj, &c.statics, .static);
                },
                .enum_type => {
                    const e = v.as(object.EnumType);
                    try nameMembers(gpa, names, &e.obj, &e.methods, .enum_method);
                },
                else => {},
            }
        }
    }

    fn nameMembers(
        gpa: Allocator,
        names: *std.AutoHashMapUnmanaged(*object.Obj, Ref),
        owner: *object.Obj,
        table: *const std.AutoHashMapUnmanaged(*object.String, Value),
        comptime which: std.meta.Tag(Ref),
    ) Allocator.Error!void {
        var it = table.iterator();
        while (it.next()) |e| if (e.value_ptr.isObject()) {
            const got = try names.getOrPut(gpa, e.value_ptr.obj());
            if (!got.found_existing) got.value_ptr.* = @unionInit(Ref, @tagName(which), .{ .owner = owner, .name = e.key_ptr.* });
        };
    }

    /// The image's number for check `c`, written into the table the first
    /// time: whatever it is made of first, so the loader meets each part
    /// before the check that holds it.
    fn check(s: *Saver, c: types.Check) Error!u32 {
        if (c.tableIndex() == null) return @intFromEnum(c);
        if (s.check_ids.get(c)) |got| return got;
        const info = s.vm.checks.get(c).?;
        var entry: Out = .{ .gpa = s.gpa };
        defer entry.deinit();
        switch (info) {
            .optional => |inner| {
                try entry.byte(@intFromEnum(CheckKind.optional));
                try entry.uint(try s.check(inner));
            },
            .list_of => |inner| {
                try entry.byte(@intFromEnum(CheckKind.list_of));
                try entry.uint(try s.check(inner));
            },
            .map_of => |kv| {
                try entry.byte(@intFromEnum(CheckKind.map_of));
                try entry.uint(try s.check(kv.key));
                try entry.uint(try s.check(kv.value));
            },
            .class => |cls| {
                try entry.byte(@intFromEnum(CheckKind.class));
                try entry.uint(try s.id(&cls.obj));
            },
            .enum_type => |e| {
                try entry.byte(@intFromEnum(CheckKind.enum_type));
                try entry.uint(try s.id(&e.obj));
            },
            .error_union => |inner| {
                try entry.byte(@intFromEnum(CheckKind.error_union));
                try entry.uint(try s.check(inner));
            },
            .function => try entry.byte(@intFromEnum(CheckKind.function)),
            .host => |t| {
                try entry.byte(@intFromEnum(CheckKind.host));
                try entry.uint(try s.hostType(t));
            },
        }
        const got = types.Check.first_table + s.check_count;
        s.check_count += 1;
        try s.checks.bytes.appendSlice(s.gpa, entry.bytes.items);
        try s.check_ids.put(s.gpa, c, got);
        return got;
    }

    /// The image's number for one of the host's types. A type the loading
    /// VM could not find by the same walk the saving one does is refused
    /// now, while the module's author can hear why.
    fn hostType(s: *Saver, t: *const reflect.Type) Error!u32 {
        for (s.host_types.items, 0..) |known, i| if (known.same(t)) return @intCast(i);
        if (s.known == null) s.known = try Known.of(s.vm, s.gpa);
        if (s.known.?.get(t.id) == null) return s.fail("it names the host's type `{s}`, which the host has not declared", .{t.name.slice()});
        try s.host_types.append(s.gpa, t);
        return @intCast(s.host_types.items.len - 1);
    }
};

fn describe(o: *object.Obj) []const u8 {
    return switch (o.kind) {
        .native => "a native function",
        .handle => "a value of the host's",
        .instance => "a struct's instance",
        .method => "a bound method",
        .signal => "a signal",
        .task => "a task",
        .closure => "a function",
        .class => "a struct",
        .enum_type => "an enum",
        .module => "a module",
        else => "a value",
    };
}

// -------------------------------------------------------------------------
// The host's types
// -------------------------------------------------------------------------

/// Every one of the host's types a VM can reach from what it was told, by
/// id: the types it named and declared, and every type those are made of or
/// take and give.
const Known = struct {
    by_id: std.AutoHashMapUnmanaged(u64, *const reflect.Type) = .empty,

    fn deinit(k: *Known, gpa: Allocator) void {
        k.by_id.deinit(gpa);
    }

    fn get(k: *const Known, id: u64) ?*const reflect.Type {
        return k.by_id.get(id);
    }

    fn of(vm: *Vm, gpa: Allocator) Allocator.Error!Known {
        var k: Known = .{};
        errdefer k.deinit(gpa);
        for (vm.named_types.values()) |t| try k.walk(gpa, t);
        var globals = vm.global_types.valueIterator();
        while (globals.next()) |t| try k.walk(gpa, t.*);
        for (vm.options.host_types) |h| {
            try k.walk(gpa, h.type);
            if (h.script) |t| try k.walk(gpa, t);
        }
        for (vm.host_members.items) |m| if (m.type) |t| try k.walk(gpa, t);
        for (vm.members.items) |m| try k.walk(gpa, m.of);
        for (vm.extensions.items) |e| {
            try k.walk(gpa, e.of);
            try k.walk(gpa, e.by);
        }
        for (vm.open_types.items) |t| try k.walk(gpa, t);
        for (vm.hooks.items) |h| for (h.params) |p| try k.walk(gpa, p.type);
        for (vm.host_enums.items) |e| try k.walk(gpa, e.host.?);
        return k;
    }

    fn walk(k: *Known, gpa: Allocator, t: *const reflect.Type) Allocator.Error!void {
        const got = try k.by_id.getOrPut(gpa, t.id);
        if (got.found_existing) return;
        got.value_ptr.* = t;
        if (t.child()) |inner| try k.walk(gpa, inner);
        for (t.fields()) |f| try k.walk(gpa, f.type);
        if (t.kind == .@"union") if (t.info.@"union".tag) |tag| try k.walk(gpa, tag);
        for (t.methods.slice()) |*m| {
            const function = m.type.info.function;
            for (function.params.slice()) |p| try k.walk(gpa, p.type);
            try k.walk(gpa, function.return_type);
        }
    }
};

// -------------------------------------------------------------------------
// Loading
// -------------------------------------------------------------------------

/// The module in `bytes`, loaded under `name` - the name a loader gave it -
/// with the modules it imports, and ready to `run`. The reason it could not
/// be is in `vm.diagnostics`.
pub fn load(vm: *Vm, name: []const u8, bytes: []const u8) LoadError!*object.Module {
    var l: Loader = .{ .vm = vm, .name = name, .in = .{ .bytes = bytes } };
    defer l.deinit();
    vm.heap.paused += 1;
    defer vm.heap.paused -= 1;
    return l.run() catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CompileFailed => error.CompileFailed,
        error.Damaged => {
            _ = try vm.diagnostics.err(.{ .file = .none, .span = .empty }, "the compiled script `{s}` is damaged", .{name});
            return error.CompileFailed;
        },
    };
}

const Loader = struct {
    vm: *Vm,
    name: []const u8,
    in: In,
    kinds: []Kind = &.{},
    payloads: [][]const u8 = &.{},
    /// Every object as a value, but a prototype, which is no value.
    values: []Value = &.{},
    protos: []?*object.Proto = &.{},
    state: []State = &.{},
    host_types: []*const reflect.Type = &.{},
    checks: std.ArrayList(types.Check) = .empty,
    module: *object.Module = undefined,
    file: diag.FileId = .none,

    const Error = error{ OutOfMemory, CompileFailed, Damaged };
    const State = enum { waiting, resolving, done };

    fn deinit(l: *Loader) void {
        const gpa = l.vm.gpa;
        gpa.free(l.kinds);
        gpa.free(l.payloads);
        gpa.free(l.values);
        gpa.free(l.protos);
        gpa.free(l.state);
        gpa.free(l.host_types);
        l.checks.deinit(gpa);
    }

    fn fail(l: *Loader, comptime fmt: []const u8, args: anytype) Error {
        _ = try l.vm.diagnostics.err(.{ .file = .none, .span = .empty }, "cannot load the compiled script `{s}`: " ++ fmt, .{l.name} ++ args);
        return error.CompileFailed;
    }

    fn run(l: *Loader) Error!*object.Module {
        const vm = l.vm;
        const gpa = vm.gpa;
        const in = &l.in;

        if (!std.mem.eql(u8, try in.take(magic.len), magic)) return l.fail("it is not one", .{});
        if (try in.byte() != format_version) return l.fail("it was saved by another version of the language", .{});
        if (try in.fixed(u64) != code_version) return l.fail("it was compiled for another version of the language's instructions", .{});
        const flags: Flags = @bitCast(try in.byte());
        if (flags.unused != 0) return error.Damaged;
        _ = try in.blob(); // the name it was compiled under

        const import_count = try in.count();
        const imports = try gpa.alloc(*object.Module, import_count);
        defer gpa.free(imports);
        for (imports) |*m| m.* = try l.imported(try in.blob());

        // The lines, as a text of spaces and line breaks: every place the
        // code names is where it was, and none of the source is.
        var skeleton: std.ArrayList(u8) = .empty;
        defer skeleton.deinit(gpa);
        if (flags.lines) {
            const lines = try in.count();
            for (0..lines) |i| {
                if (i != 0) try skeleton.append(gpa, '\n');
                const len = try in.uint();
                if (len > 1 << 24) return error.Damaged;
                try skeleton.appendNTimes(gpa, ' ', @intCast(len));
            }
        }
        l.file = try vm.sources.add(l.name, skeleton.items);

        const host_count = try in.count();
        l.host_types = try gpa.alloc(*const reflect.Type, host_count);
        if (host_count != 0) {
            var known: Known = try .of(vm, gpa);
            defer known.deinit(gpa);
            for (l.host_types) |*t| {
                const id = try in.fixed(u64);
                const type_name = try in.blob();
                t.* = known.get(id) orelse return l.fail("it names the host's type `{s}`, which this program does not have", .{type_name});
            }
        }

        const object_count = try in.count();
        l.kinds = try gpa.alloc(Kind, object_count);
        l.payloads = try gpa.alloc([]const u8, object_count);
        l.values = try gpa.alloc(Value, object_count);
        @memset(l.values, .null);
        l.protos = try gpa.alloc(?*object.Proto, object_count);
        @memset(l.protos, null);
        l.state = try gpa.alloc(State, object_count);
        @memset(l.state, .waiting);
        for (l.kinds, l.payloads) |*kind, *payload| {
            kind.* = std.enums.fromInt(Kind, try in.byte()) orelse return error.Damaged;
            payload.* = try in.blob();
        }

        l.module = try make.module(vm, try vm.intern(l.name));
        l.module.path = try gpa.dupe(u8, l.name);
        l.module.file = l.file;
        try l.shells();

        const check_count = try in.count();
        try l.checks.ensureTotalCapacity(gpa, check_count);
        for (0..check_count) |_| try l.checks.append(gpa, try l.readCheckEntry());

        for (l.kinds, 0..) |kind, i| switch (kind) {
            .proto => try l.fillProto(i),
            .class => try l.fillClass(i),
            .enum_type => try l.fillEnum(i),
            .list => try l.fillList(i),
            .map => try l.fillMap(i),
            else => {},
        };

        const module = l.module;
        const global_count = try in.count();
        try module.globals.ensureTotalCapacity(gpa, global_count);
        try module.names.ensureTotalCapacity(gpa, global_count);
        for (0..global_count) |i| {
            const global_name = try l.stringAt(try in.uint());
            module.globals.appendAssumeCapacity(try l.readValue(in));
            module.names.appendAssumeCapacity(global_name);
            try module.lookup.put(gpa, global_name, @intCast(i));
        }
        module.main = try l.protoAt(try in.uint());
        if (in.at != in.bytes.len) return error.Damaged;

        try module.imports.appendSlice(gpa, imports);
        for (l.kinds, l.values) |kind, v| if (kind == .class) try vm.classes.append(gpa, v.as(object.Class));
        module.state = .ready;
        try vm.modules.put(gpa, module.path, module);
        return module;
    }

    /// The module an image imports: already in the VM, one of the host's,
    /// or another image the loader finds.
    fn imported(l: *Loader, name: []const u8) Error!*object.Module {
        const vm = l.vm;
        if (vm.native_modules.get(name)) |m| return m;
        if (vm.modules.get(name)) |m| return m;
        const loader = vm.options.loader orelse return l.fail("it imports `{s}`, and there is no loader to find it", .{name});
        const loaded = loader.load(loader.context, vm.gpa, l.name, name) catch |e|
            return l.fail("it imports `{s}`, which cannot be loaded: {s}", .{ name, @errorName(e) });
        defer vm.gpa.free(loaded.name);
        defer vm.gpa.free(loaded.source);
        if (vm.modules.get(loaded.name)) |m| return m;
        if (!isImage(loaded.source)) return l.fail("it imports `{s}`, which is not compiled", .{name});
        return load(vm, loaded.name, loaded.source) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.CompileFailed => l.fail("it imports `{s}`, which cannot be loaded either", .{name}),
        };
    }

    /// Every object made, empty where it holds others: strings first, then
    /// prototypes, then what is made of them, and every name found.
    fn shells(l: *Loader) Error!void {
        const vm = l.vm;
        for (l.kinds, l.payloads, l.values, l.state) |kind, payload, *v, *state| {
            if (kind != .string) continue;
            v.* = .fromObj(.string, &(try vm.intern(payload)).obj);
            state.* = .done;
        }
        for (l.kinds, l.payloads, l.protos, l.state) |kind, payload, *p, *state| {
            if (kind != .proto) continue;
            var in: In = .{ .bytes = payload };
            p.* = try make.proto(vm, try l.stringAt(try in.uint()));
            state.* = .done;
        }
        for (l.kinds, 0..) |_, i| try l.resolve(i);
    }

    /// Object `i` made, and whatever it needs made first.
    fn resolve(l: *Loader, i: usize) Error!void {
        switch (l.state[i]) {
            .done => return,
            .resolving => return error.Damaged,
            .waiting => {},
        }
        l.state[i] = .resolving;
        l.values[i] = try l.makeObject(i);
        l.state[i] = .done;
    }

    fn at(l: *Loader, id: u64) Error!Value {
        if (id >= l.values.len) return error.Damaged;
        try l.resolve(@intCast(id));
        return l.values[@intCast(id)];
    }

    fn makeObject(l: *Loader, i: usize) Error!Value {
        const vm = l.vm;
        var in: In = .{ .bytes = l.payloads[i] };
        switch (l.kinds[i]) {
            // Made before anything that could ask for them: one asked for
            // here is one the image has in the wrong place.
            .string, .proto => return error.Damaged,
            .closure => {
                const p = try l.protoAt(try in.uint());
                return .fromObj(.function, &(try make.closure(vm, p)).obj);
            },
            .class => return .fromObj(.class, &(try make.class(vm, try l.stringAt(try in.uint()))).obj),
            .enum_type => return .fromObj(.enum_type, &(try make.enumType(vm, try l.stringAt(try in.uint()))).obj),
            .list => return .fromObj(.list, &(try make.list(vm, 0, .any)).obj),
            .map => return .fromObj(.map, &(try make.map(vm, .any, .any)).obj),
            .color => {
                var rgba: [4]f32 = undefined;
                for (&rgba) |*c| c.* = @bitCast(try in.fixed(u32));
                return make.color(vm, rgba);
            },
            .error_value => {
                const error_name = try l.stringAt(try in.uint());
                const message = try in.uint();
                return make.errorValue(vm, error_name, if (message == 0) null else try l.stringAt(message - 1));
            },
            .this_module => return .fromObj(.module, &l.module.obj),
            .module => {
                const module_name = try in.blob();
                const m = vm.native_modules.get(module_name) orelse vm.modules.get(module_name) orelse
                    return l.fail("it refers to the module `{s}`, which is not loaded", .{module_name});
                return .fromObj(.module, &m.obj);
            },
            .prelude => {
                const global_name = try in.blob();
                const key = try vm.intern(global_name);
                return vm.prelude.get(key) orelse return l.fail("it uses `{s}`, which this program does not give scripts", .{global_name});
            },
            .global => {
                const owner = try l.at(try in.uint());
                const global_name = try in.blob();
                if (owner.tag != .module) return error.Damaged;
                const m = owner.as(object.Module);
                const key = try vm.intern(global_name);
                return m.get(key) orelse return l.fail("it uses `{s}` of `{s}`, which is not there", .{ global_name, m.path });
            },
            .static, .method => {
                const owner = try l.at(try in.uint());
                const member_name = try in.blob();
                if (owner.tag != .class) return error.Damaged;
                const c = owner.as(object.Class);
                const key = try vm.intern(member_name);
                const table = if (l.kinds[i] == .static) &c.statics else &c.methods;
                return table.get(key) orelse return l.fail("it uses `{s}.{s}`, which is not there", .{ c.name.bytes(), member_name });
            },
            .enum_method => {
                const owner = try l.at(try in.uint());
                const member_name = try in.blob();
                if (owner.tag != .enum_type) return error.Damaged;
                const e = owner.as(object.EnumType);
                return e.methods.get(try vm.intern(member_name)) orelse return l.fail("it uses `{s}.{s}`, which is not there", .{ e.name.bytes(), member_name });
            },
            .host_enum => {
                const t = try l.hostTypeAt(try in.uint());
                const enum_name = try in.blob();
                const e = bridge.enumNamed(vm, t, enum_name) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Panic => return l.fail("it names the host's enum `{s}`, which cannot be made", .{enum_name}),
                };
                return .fromObj(.enum_type, &e.obj);
            },
        }
    }

    fn stringAt(l: *Loader, id: u64) Error!*object.String {
        const v = try l.at(id);
        if (v.tag != .string) return error.Damaged;
        return v.as(object.String);
    }

    fn protoAt(l: *Loader, id: u64) Error!*object.Proto {
        if (id >= l.protos.len) return error.Damaged;
        return l.protos[@intCast(id)] orelse error.Damaged;
    }

    fn hostTypeAt(l: *Loader, index: u64) Error!*const reflect.Type {
        if (index >= l.host_types.len) return error.Damaged;
        return l.host_types[@intCast(index)];
    }

    fn checkAt(l: *Loader, id: u64) Error!types.Check {
        if (id < types.Check.first_table) {
            if (id > @intFromEnum(types.Check.type)) return error.Damaged;
            return @enumFromInt(id);
        }
        const index = id - types.Check.first_table;
        if (index >= l.checks.items.len) return error.Damaged;
        return l.checks.items[@intCast(index)];
    }

    fn readCheckEntry(l: *Loader) Error!types.Check {
        const in = &l.in;
        const info: types.Info = switch (std.enums.fromInt(CheckKind, try in.byte()) orelse return error.Damaged) {
            .optional => .{ .optional = try l.checkAt(try in.uint()) },
            .list_of => .{ .list_of = try l.checkAt(try in.uint()) },
            .map_of => .{ .map_of = .{ .key = try l.checkAt(try in.uint()), .value = try l.checkAt(try in.uint()) } },
            .class => blk: {
                const v = try l.at(try in.uint());
                if (v.tag != .class) return error.Damaged;
                break :blk .{ .class = v.as(object.Class) };
            },
            .enum_type => blk: {
                const v = try l.at(try in.uint());
                if (v.tag != .enum_type) return error.Damaged;
                break :blk .{ .enum_type = v.as(object.EnumType) };
            },
            .error_union => .{ .error_union = try l.checkAt(try in.uint()) },
            .function => .function,
            .host => .{ .host = try l.hostTypeAt(try in.uint()) },
        };
        return l.vm.checks.add(l.vm.gpa, info);
    }

    fn readValue(l: *Loader, in: *In) Error!Value {
        return switch (std.enums.fromInt(ValueTag, try in.byte()) orelse return error.Damaged) {
            .null => .null,
            .false => .false,
            .true => .true,
            .int => .int(try in.int()),
            .float => .{ .raw = try in.fixed(u64), .extra = 0, .tag = .float },
            .vec2 => .{ .raw = try in.fixed(u64), .extra = 0, .tag = .vec2 },
            .vec3 => .{ .raw = try in.fixed(u64), .extra = try in.fixed(u32), .tag = .vec3 },
            .undefined => .undef,
            .enum_value => blk: {
                const e = try l.at(try in.uint());
                if (e.tag != .enum_type) return error.Damaged;
                const index = try in.uint();
                if (index >= e.as(object.EnumType).members.len) return error.Damaged;
                break :blk .enumValue(e.obj(), @intCast(index));
            },
            .host_type => .hostType(try l.hostTypeAt(try in.uint())),
            .object => blk: {
                const id = try in.uint();
                // A prototype is code, never a value a script holds.
                if (id < l.kinds.len and l.kinds[@intCast(id)] == .proto) return error.Damaged;
                break :blk try l.at(id);
            },
        };
    }

    fn optionalAt(l: *Loader, in: *In) Error!?Value {
        const id = try in.uint();
        return if (id == 0) null else try l.at(id - 1);
    }

    fn fillProto(l: *Loader, i: usize) Error!void {
        const vm = l.vm;
        const gpa = vm.gpa;
        const p = l.protos[i].?;
        var in: In = .{ .bytes = l.payloads[i] };
        _ = try in.uint(); // the name, given when it was made
        p.params = try in.byte();
        p.required = try in.byte();
        p.regs = try in.byte();
        p.has_self = try in.flag();
        p.coroutine = try in.flag();
        p.fast_entry = std.math.cast(u32, try in.uint()) orelse return error.Damaged;
        if (p.required > p.params) return error.Damaged;
        p.returns = try l.checkAt(try in.uint());
        p.param_checks = try gpa.alloc(types.Check, try in.count());
        for (p.param_checks) |*c| c.* = try l.checkAt(try in.uint());
        p.param_names = try gpa.alloc(*object.String, try in.count());
        for (p.param_names) |*n| n.* = try l.stringAt(try in.uint());
        if (try l.optionalAt(&in)) |c| {
            if (c.tag != .class) return error.Damaged;
            p.class = c.as(object.Class);
        }
        p.module = l.module;
        p.file = l.file;

        const words = try in.count();
        p.code = try gpa.alloc(u32, words);
        var w: usize = 0;
        while (w < words) {
            const instr = code.Instr.of(try in.fixed(u32));
            const op = instr.op;
            if (std.enums.tagName(code.Op, op) == null) return error.Damaged;
            var word = instr;
            switch (op) {
                .check, .check_param => word = .abx(op, instr.a, std.math.cast(u16, @intFromEnum(try l.checkAt(instr.bx()))) orelse return l.fail("it checks more types than one function can", .{})),
                .newmap => word = .abc(.newmap, instr.a, std.math.cast(u8, @intFromEnum(try l.checkAt(instr.b))) orelse return l.fail("it checks more types than a map can", .{}), std.math.cast(u8, @intFromEnum(try l.checkAt(instr.c))) orelse return l.fail("it checks more types than a map can", .{})),
                .from_string => word = .abx(.from_string, instr.a, try l.hostTypeIndex(try l.hostTypeAt(instr.bx()))),
                else => {},
            }
            p.code[w] = word.word();
            const width = code.width(op);
            if (width == 2) {
                if (w + 1 >= words) return error.Damaged;
                const second = try in.fixed(u32);
                p.code[w + 1] = switch (op) {
                    .is, .newlist => @intFromEnum(try l.checkAt(second)),
                    else => second,
                };
            }
            w += width;
        }

        if (p.fast_entry > words) return error.Damaged;
        const span_count = try in.count();
        p.spans = try gpa.alloc(diag.Span, words);
        if (span_count == 0) {
            @memset(p.spans, .empty);
        } else {
            if (span_count != words) return error.Damaged;
            for (p.spans) |*span| span.* = .{ .start = try l.offset(&in), .end = try l.offset(&in) };
            p.decl = .{ .start = try l.offset(&in), .end = try l.offset(&in) };
        }

        p.constants = try gpa.alloc(Value, try in.count());
        for (p.constants) |*k| k.* = try l.readValue(&in);
        p.protos = try gpa.alloc(*object.Proto, try in.count());
        for (p.protos) |*inner| inner.* = try l.protoAt(try in.uint());
        p.upvals = try gpa.alloc(object.UpvalDesc, try in.count());
        for (p.upvals) |*u| u.* = .{ .from_parent_local = try in.flag(), .index = try in.byte() };
        const caches = try in.uint();
        if (caches > std.math.maxInt(u16) + 1) return error.Damaged;
        p.caches = try gpa.alloc(object.Cache, @intCast(caches));
        @memset(p.caches, .{});
        if (in.at != in.bytes.len) return error.Damaged;
    }

    /// A place in the lines, which must be one.
    fn offset(l: *Loader, in: *In) Error!u32 {
        const n = try in.uint();
        const len = if (l.vm.sources.get(l.file)) |f| f.text.len else 0;
        if (n > len) return error.Damaged;
        return @intCast(n);
    }

    /// Where the loading VM keeps `t` among the types it makes from strings.
    fn hostTypeIndex(l: *Loader, t: *const reflect.Type) Error!u16 {
        for (l.vm.options.host_types, 0..) |h, i| if (h.type.same(t)) return @intCast(i);
        return l.fail("it makes a `{s}` from a string, which this program does not", .{t.name.slice()});
    }

    fn fillClass(l: *Loader, i: usize) Error!void {
        const vm = l.vm;
        const gpa = vm.gpa;
        const c = l.values[i].as(object.Class);
        var in: In = .{ .bytes = l.payloads[i] };
        _ = try in.uint(); // the name, given when it was made
        c.module = l.module;
        if (try l.optionalAt(&in)) |parent| {
            if (parent.tag != .class) return error.Damaged;
            c.parent = parent.as(object.Class);
        }
        if (try l.optionalAt(&in)) |defaults| {
            if (defaults.tag != .function) return error.Damaged;
            c.defaults = defaults.as(object.Closure);
        }
        if (try l.optionalAt(&in)) |annotations| {
            if (annotations.tag != .map) return error.Damaged;
            c.annotations = annotations.as(object.Map);
        }
        c.has_signals = try in.flag();
        // The class takes the fields once every one is whole: the collector
        // frees what a field holds, and would free what a half-read one does
        // not.
        c.fields = fields: {
            const fields = try gpa.alloc(object.Field, try in.count());
            var filled: usize = 0;
            errdefer {
                for (fields[0..filled]) |f| if (f.signature) |text| gpa.free(text);
                gpa.free(fields);
            }
            for (fields, 0..) |*f, slot| {
                try l.readField(&in, f);
                filled = slot + 1;
                try c.slots.put(gpa, f.name, @intCast(slot));
            }
            break :fields fields;
        };
        try l.readMembers(&in, &c.methods);
        try l.readMembers(&in, &c.statics);
        if (in.at != in.bytes.len) return error.Damaged;
    }

    fn readField(l: *Loader, in: *In, f: *object.Field) Error!void {
        f.* = .{
            .name = try l.stringAt(try in.uint()),
            .check = try l.checkAt(try in.uint()),
            .default = try l.readValue(in),
            .exported = false,
            .is_const = false,
            .is_signal = false,
        };
        {
            const bits = try in.byte();
            f.exported = bits & 1 != 0;
            f.is_const = bits & 2 != 0;
            f.is_signal = bits & 4 != 0;
            f.computed = bits & 8 != 0;
            f.host = bits & 16 != 0;
        }
        if (try l.optionalAt(in)) |annotations| {
            if (annotations.tag != .map) return error.Damaged;
            f.annotations = annotations.as(object.Map);
        }
        if (try in.flag()) f.signature = try l.vm.gpa.dupe(u8, try in.blob());
    }

    fn fillEnum(l: *Loader, i: usize) Error!void {
        const gpa = l.vm.gpa;
        const e = l.values[i].as(object.EnumType);
        var in: In = .{ .bytes = l.payloads[i] };
        _ = try in.uint(); // the name, given when it was made
        e.module = l.module;
        const count = try in.count();
        e.members = try gpa.alloc(*object.String, count);
        e.values = try gpa.alloc(i64, count);
        for (e.members, e.values) |*m, *n| {
            m.* = try l.stringAt(try in.uint());
            n.* = try in.int();
        }
        try l.readMembers(&in, &e.methods);
        if (in.at != in.bytes.len) return error.Damaged;
    }

    fn fillList(l: *Loader, i: usize) Error!void {
        const gpa = l.vm.storage();
        const list = l.values[i].as(object.List);
        var in: In = .{ .bytes = l.payloads[i] };
        list.elem = try l.checkAt(try in.uint());
        const count = try in.count();
        try list.items.ensureTotalCapacity(gpa, count);
        for (0..count) |_| list.items.appendAssumeCapacity(try l.readValue(&in));
        if (in.at != in.bytes.len) return error.Damaged;
    }

    fn fillMap(l: *Loader, i: usize) Error!void {
        const gpa = l.vm.storage();
        const map = l.values[i].as(object.Map);
        var in: In = .{ .bytes = l.payloads[i] };
        map.key = try l.checkAt(try in.uint());
        map.value = try l.checkAt(try in.uint());
        const count = try in.count();
        for (0..count) |_| {
            const key = try l.readValue(&in);
            const v = try l.readValue(&in);
            map.table.put(gpa, key, v) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Damaged,
            };
        }
        if (in.at != in.bytes.len) return error.Damaged;
    }

    fn readMembers(l: *Loader, in: *In, table: *std.AutoHashMapUnmanaged(*object.String, Value)) Error!void {
        const count = try in.count();
        for (0..count) |_| {
            const member_name = try l.stringAt(try in.uint());
            try table.put(l.vm.gpa, member_name, try l.readValue(in));
        }
    }
};
