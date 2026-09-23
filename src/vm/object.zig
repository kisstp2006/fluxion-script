// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;

const diag = @import("../diag.zig");
const Value = @import("value.zig").Value;
const Table = @import("table.zig").Table;
const code = @import("code.zig");
const Fiber = @import("fiber.zig").Fiber;
const types = @import("types.zig");

pub const Kind = enum(u8) {
    string,
    list,
    map,
    instance,
    closure,
    native,
    method,
    class,
    enum_type,
    module,
    task,
    signal,
    error_value,
    color,
    handle,
    proto,
    upvalue,
};

/// The header every heap object starts from. Objects are found from it with
/// `@fieldParentPtr`, so each type puts it wherever Zig likes.
pub const Obj = struct {
    next: ?*Obj,
    kind: Kind,
    color: u8,
    flags: u8 = 0,
};

fn Header(comptime T: type) type {
    return struct {
        /// Every object is allocated at its own type's alignment, which on a
        /// 32-bit target can be more than its header's.
        pub inline fn from(o: *Obj) *T {
            return @alignCast(@fieldParentPtr("obj", o));
        }
    };
}

fn trailing(comptime Item: type, self: anytype, len: usize) []Item {
    const bytes: [*]u8 = @ptrCast(@constCast(self));
    const items: [*]Item = @ptrCast(@alignCast(bytes + @sizeOf(@TypeOf(self.*))));
    return items[0..len];
}

pub const String = struct {
    obj: Obj,
    len: u32,
    hash: u32,
    chars: u32,

    pub const from = Header(String).from;

    pub fn bytes(s: *const String) []const u8 {
        return trailing(u8, s, s.len);
    }

    pub fn mutableBytes(s: *String) []u8 {
        return trailing(u8, s, s.len + 1);
    }

    pub fn isAscii(s: *const String) bool {
        return s.chars == s.len;
    }

    pub fn eql(a: *const String, b: *const String) bool {
        return a == b or (a.hash == b.hash and std.mem.eql(u8, a.bytes(), b.bytes()));
    }
};

pub const List = struct {
    obj: Obj,
    items: std.ArrayList(Value) = .empty,
    elem: types.Check = .any,

    pub const from = Header(List).from;
};

pub const Map = struct {
    obj: Obj,
    table: Table = .{},
    key: types.Check = .any,
    value: types.Check = .any,

    pub const from = Header(Map).from;
};

pub const Field = struct {
    name: *String,
    check: types.Check,
    default: Value,
    exported: bool,
    is_const: bool,
    is_signal: bool,
    /// Given its value by the struct's defaults, made for each instance: a
    /// list, a map, or anything computed. `default` is only its zero then.
    computed: bool = false,
    /// Given by the host to every struct: see `Vm.declareHostMember`.
    host: bool = false,
    annotations: ?*Map = null,
    doc: ?[]const u8 = null,
    /// A signal's parameters as written, `by: ?Actor`.
    signature: ?[]const u8 = null,
};

pub const Class = struct {
    obj: Obj,
    name: *String,
    parent: ?*Class = null,
    module: ?*Module = null,
    fields: []Field = &.{},
    slots: std.AutoHashMapUnmanaged(*String, u32) = .empty,
    methods: std.AutoHashMapUnmanaged(*String, Value) = .empty,
    statics: std.AutoHashMapUnmanaged(*String, Value) = .empty,
    defaults: ?*Closure = null,
    has_signals: bool = false,
    doc: ?[]const u8 = null,
    annotations: ?*Map = null,

    pub const from = Header(Class).from;

    pub fn isSubclassOf(c: *const Class, other: *const Class) bool {
        var at: ?*const Class = c;
        while (at) |x| : (at = x.parent) if (x == other) return true;
        return false;
    }

    pub fn method(c: *const Class, name: *String) ?Value {
        var at: ?*const Class = c;
        while (at) |x| : (at = x.parent) if (x.methods.get(name)) |m| return m;
        return null;
    }
};

pub const Instance = struct {
    obj: Obj,
    class: *Class,
    count: u32,

    pub const from = Header(Instance).from;

    /// Set in `obj.flags` once a reload has given the instance a new
    /// layout. Its fields then live in a block of their own, and the first
    /// field's place says where.
    pub const moved: u8 = 1;

    pub const Moved = struct { values: [*]Value, made: u32 };

    pub inline fn fields(self: *Instance) []Value {
        if (self.obj.flags & moved != 0) {
            @branchHint(.unlikely);
            return self.movedTo().values[0..self.count];
        }
        return trailing(Value, self, self.count);
    }

    pub fn movedTo(self: *Instance) *Moved {
        return @ptrCast(trailing(Value, self, 1).ptr);
    }
};

pub const UpvalDesc = struct {
    from_parent_local: bool,
    index: u8,
};

pub const Cache = struct {
    class: ?*Class = null,
    slot: u32 = 0,
    check: types.Check = .any,
    method: Value = .null,
};

pub const Proto = struct {
    obj: Obj,
    name: *String,
    code: []u32 = &.{},
    spans: []diag.Span = &.{},
    constants: []Value = &.{},
    protos: []*Proto = &.{},
    upvals: []UpvalDesc = &.{},
    caches: []Cache = &.{},
    param_checks: []types.Check = &.{},
    param_names: []*String = &.{},
    module: ?*Module = null,
    class: ?*Class = null,
    file: diag.FileId = .none,
    decl: diag.Span = .empty,
    params: u8 = 0,
    required: u8 = 0,
    regs: u8 = 1,
    has_self: bool = false,
    coroutine: bool = false,
    returns: types.Check = .any,
    /// The `///` comment written above a declared function, for a host.
    doc: ?[]const u8 = null,
    /// A declared function's parameters as written, `dt: float`, without
    /// `self`.
    signature: ?[]const u8 = null,
    /// Where a call whose arguments the compiler has already checked
    /// starts: past the checks of the required parameters.
    fast_entry: u32 = 0,

    pub const from = Header(Proto).from;
};

pub const Upvalue = struct {
    obj: Obj,
    location: *Value,
    closed: Value = .null,
    frame: u32 = 0,
    reg: u32 = 0,
    next: ?*Upvalue = null,

    pub const from = Header(Upvalue).from;
};

pub const Closure = struct {
    obj: Obj,
    proto: *Proto,
    count: u32,

    pub const from = Header(Closure).from;

    pub fn upvals(self: *Closure) []*Upvalue {
        return trailing(*Upvalue, self, self.count);
    }
};

pub const NativeFn = *const fn (vm: *@import("Vm.zig"), args: []Value) @import("Vm.zig").Error!Value;

pub const Native = struct {
    obj: Obj,
    func: NativeFn,
    name: []const u8,
    /// Fewest and most arguments; `max` null takes any number.
    min: u8 = 0,
    max: ?u8 = null,
    /// What a native made from C calls, and the pointer it was given for it.
    data: ?*const anyopaque = null,
    user: ?*anyopaque = null,

    pub const from = Header(Native).from;
};

pub const Method = struct {
    obj: Obj,
    receiver: Value,
    function: Value,

    pub const from = Header(Method).from;
};

pub const EnumType = struct {
    obj: Obj,
    name: *String,
    members: []*String = &.{},
    values: []i64 = &.{},
    methods: std.AutoHashMapUnmanaged(*String, Value) = .empty,
    module: ?*Module = null,

    pub const from = Header(EnumType).from;

    pub fn index(e: *const EnumType, name: *String) ?u32 {
        for (e.members, 0..) |m, i| if (m == name) return @intCast(i);
        return null;
    }
};

pub const Module = struct {
    obj: Obj,
    name: *String,
    path: []const u8 = "",
    globals: std.ArrayList(Value) = .empty,
    names: std.ArrayList(*String) = .empty,
    lookup: std.AutoHashMapUnmanaged(*String, u32) = .empty,
    main: ?*Proto = null,
    file: diag.FileId = .none,
    state: State = .loading,
    tests: std.ArrayList(Test) = .empty,
    imports: std.ArrayList(*Module) = .empty,
    ran: bool = false,

    pub const State = enum { loading, ready, failed };
    pub const Test = struct { name: *String, function: *Closure };

    pub const from = Header(Module).from;

    pub fn get(m: *const Module, name: *String) ?Value {
        const i = m.lookup.get(name) orelse return null;
        return m.globals.items[i];
    }
};

pub const Task = struct {
    obj: Obj,
    fiber: Fiber,
    slot: u32 = 0,
    await_reg: ?*Value = null,
    state: State = .ready,
    result: Value = .null,
    waiters: std.ArrayList(*Task) = .empty,
    waiting_on: Value = .null,
    wake_at: f64 = 0,
    /// Whose it is, as the host counts: what `Vm.task_owner` was when it
    /// started, or the task that started it's. See `api.updateHolding`.
    owner: u64 = 0,
    failure: ?[]const u8 = null,
    /// Why the task this one waited for failed: raised at its `await` when
    /// it runs on.
    awaited_failure: ?[]u8 = null,

    pub const State = enum { ready, running, suspended, done, failed };

    pub const from = Header(Task).from;
};

pub const Connection = struct {
    target: Value,
    once: bool,
};

pub const Signal = struct {
    obj: Obj,
    name: *String,
    connections: std.ArrayList(Connection) = .empty,
    waiters: std.ArrayList(*Task) = .empty,
    params: u8 = 0,
    /// The instance it is a signal of, for `Vm.Options.on_emit`; null for
    /// one that belongs to none.
    owner: Value = .null,

    pub const from = Header(Signal).from;
};

pub const ErrorValue = struct {
    obj: Obj,
    name: *String,
    message: ?*String = null,

    pub const from = Header(ErrorValue).from;
};

pub const Color = struct {
    obj: Obj,
    rgba: [4]f32,

    pub const from = Header(Color).from;
};

/// A Zig value seen through fluxion-reflect: its fields read and written by
/// name, its methods called. `owner` keeps alive what the value lives in;
/// `owned` values were made for the script and are freed with the handle.
pub const Handle = struct {
    obj: Obj,
    value: @import("fluxion_reflect").Value,
    owner: Value = .null,
    owned: bool = false,
    /// A live handle is looked up again at each use, through the host's
    /// resolver and its key; so is a handle reached through one, by its step
    /// from its owner. `value` is then only where it was the last time.
    live: ?*const Resolver = null,
    key: u64 = 0,
    step: Step = .none,

    pub const Step = union(enum) { none, field: u32, element: u32 };

    pub const from = Header(Handle).from;
};

/// Where the value a live handle stands for is now, or null when it is gone:
/// see `Vm.liveHandle`. It outlives the handles made with it.
pub const Resolver = struct {
    context: ?*anyopaque = null,
    resolve: *const fn (context: ?*anyopaque, key: u64, t: *const @import("fluxion_reflect").Type) ?@import("fluxion_reflect").Value,
    /// Why one would be gone, said after "this Health is gone: ".
    why: []const u8 = "what it was found by is not there any more",
};

test {
    _ = code;
}
