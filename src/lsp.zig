// SPDX-License-Identifier: BSD-2-Clause

//! The Language Server Protocol, for the editors that speak it: `flux lsp`
//! serves the language service over standard input and output.

pub const Server = @import("lsp/Server.zig");
pub const Lines = @import("lsp/Lines.zig");
pub const uri = @import("lsp/uri.zig");
pub const rpc = @import("lsp/rpc.zig");

test {
    _ = Lines;
    _ = uri;
    _ = rpc;
    _ = @import("lsp_test.zig");
}
