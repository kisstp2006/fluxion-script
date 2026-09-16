// SPDX-License-Identifier: BSD-2-Clause

//! The language service: what an editor asks about a file being written -
//! how to colour it, what a name is and where it is declared, what could be
//! typed at the cursor, which argument of which call the cursor is in -
//! answered by compiling the file with a `compile/Recorder.zig` listening,
//! in a VM of its own that runs nothing.
//!
//! An editor in the same program calls it directly, the way Godot's script
//! editor asks GDScript; `examples/ide` does. Other editors ask `flux lsp`,
//! which answers the Language Server Protocol with these.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Vm = @import("vm/Vm.zig");
const Recorder = @import("compile/Recorder.zig");

pub const Analysis = @import("service/Analysis.zig");
pub const Hover = Analysis.Hover;
pub const Symbol = Analysis.Symbol;
pub const highlight = @import("service/highlight.zig");
pub const Token = highlight.Token;
pub const TokenType = highlight.TokenType;
pub const Modifiers = highlight.Modifiers;
const complete_mod = @import("service/complete.zig");
pub const complete = complete_mod.complete;
pub const signatureHelp = complete_mod.signatureHelp;
pub const Item = complete_mod.Item;
pub const Completions = complete_mod.Completions;
pub const Signature = complete_mod.Signature;
pub const cursor = @import("service/cursor.zig");
pub const docs = @import("service/docs.zig");

pub const Error = error{ OutOfMemory, SetupFailed };

pub const Options = struct {
    /// Gives each VM the service makes what the host gives its scripts:
    /// natives, modules, `os`. Without it, what they use of those is
    /// reported as missing.
    setup: ?Setup = null,
    /// Where imports come from. An editor gives the text of the files it
    /// has open, and the rest from disk.
    loader: ?Vm.Loader = null,
    io: ?std.Io = null,
};

pub const Setup = struct {
    context: ?*anyopaque = null,
    run: *const fn (context: ?*anyopaque, vm: *Vm) anyerror!void,
};

/// What a name is, as an editor shows it: a completion's icon, a symbol's.
pub const Kind = enum {
    variable,
    constant,
    parameter,
    function,
    method,
    field,
    signal,
    @"struct",
    @"enum",
    enum_member,
    module,
    builtin_function,
    builtin_type,
    builtin_method,
    property,
    @"test",
    keyword,
    annotation,

    pub fn of(k: Recorder.Kind) Kind {
        return @enumFromInt(@intFromEnum(k));
    }
};

comptime {
    // `Kind.of` counts on the recorder's kinds coming first, in its order.
    for (@typeInfo(Recorder.Kind).@"enum".fields) |f| {
        if (@intFromEnum(@field(Kind, f.name)) != f.value) @compileError("service.Kind must start with Recorder.Kind: " ++ f.name);
    }
}

/// A VM to compile in, with what the host gives its scripts.
pub fn newVm(gpa: Allocator, options: Options) Error!*Vm {
    const vm = try Vm.create(gpa, .{ .loader = options.loader, .io = options.io });
    errdefer vm.destroy();
    if (options.setup) |s| s.run(s.context, vm) catch return error.SetupFailed;
    return vm;
}

test {
    _ = cursor;
    _ = docs;
    _ = @import("service_test.zig");
}
