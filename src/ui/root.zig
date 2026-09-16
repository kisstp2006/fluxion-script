// SPDX-License-Identifier: BSD-2-Clause

//! Flux's code editor on fluxion-ui: a `flux.edit.Code` drawn, clicked and
//! scrolled, in colours a program can change. The mini IDE in `examples/ide`
//! is a window around it.
//!
//! A module of its own so that a program using the language never builds
//! it: `zig build` makes it only when this package is built itself, or when a
//! dependant asks for `.ui = true`. A program that has fluxion-ui already can
//! build this file over its own instead, so the two are one package.

pub const View = @import("View.zig");
pub const Theme = @import("Theme.zig");
pub const Ruler = View.Ruler;
pub const Pointer = View.Pointer;

test {
    _ = View;
    _ = Theme;
}
