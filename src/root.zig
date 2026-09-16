// SPDX-License-Identifier: BSD-2-Clause

//! Flux - a scripting language for games and applications, with Zig's and
//! C's syntax, GDScript's ideas and Python's reach.

pub const diag = @import("diag.zig");

pub const syntax = struct {
    pub const token = @import("syntax/token.zig");
    pub const lex = @import("syntax/lex.zig");
    pub const ast = @import("syntax/ast.zig");
    pub const parse = @import("syntax/parse.zig");
    pub const dump = @import("syntax/dump.zig");
};

pub const Vm = @import("vm/Vm.zig");
pub const Value = @import("vm/value.zig").Value;
pub const object = @import("vm/object.zig");
pub const Compiler = @import("compile/Compiler.zig");

pub const run = @import("vm/call.zig").runModule;
pub const call = @import("vm/call.zig").call;
pub const update = @import("vm/call.zig").update;
pub const renderPanic = @import("vm/panic.zig").render;
pub const gc = @import("vm/gc.zig");
pub const disasm = @import("disasm.zig");
pub const os = @import("lib/os.zig");
pub const bind = @import("bind.zig");
pub const FileLoader = @import("api.zig").FileLoader;

/// A script's structs, from the host: `vm.instantiate`, `vm.callMethod` and
/// `vm.connectSignal` and the rest on `Vm`, and these, which need none.
pub const Member = @import("api.zig").Member;
pub const HostValue = @import("api.zig").HostValue;
pub const Resolver = object.Resolver;
pub const classOf = @import("api.zig").classOf;
pub const methodsOf = @import("api.zig").methodsOf;
pub const signalsOf = @import("api.zig").signalsOf;

/// What an editor asks about code being written: highlighting, hovers,
/// completions, where names are declared. `flux lsp` serves it to editors.
pub const service = @import("service.zig");
pub const lsp = @import("lsp.zig");

/// A code editor's model over the service, for an interface to draw;
/// `fluxion_script_ui` draws it with fluxion-ui.
pub const edit = @import("edit.zig");

/// The C API of `include/fluxion_script.h`. Its functions are exported, so
/// a program with C beside it writes `comptime { _ = flux.c; }`.
pub const c = @import("c.zig");

test {
    _ = diag;
    _ = syntax.token;
    _ = syntax.lex;
    _ = @import("syntax/strings.zig");
    _ = @import("syntax/lex_test.zig");
    _ = @import("syntax/parse_test.zig");
    _ = @import("vm/value.zig");
    _ = @import("vm/table.zig");
    _ = @import("vm/code.zig");
    _ = @import("vm/heap.zig");
    _ = @import("vm/strings.zig");
    _ = @import("vm/format.zig");
    _ = @import("compile/scan.zig");
    _ = @import("run_test.zig");
    _ = @import("reload_test.zig");
    _ = @import("host_test.zig");
    _ = @import("bind.zig");
    _ = os;
    _ = @import("reflect_test.zig");
    _ = service;
    _ = @import("service/complete.zig");
    _ = lsp;
    _ = edit;
}
