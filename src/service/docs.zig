// SPDX-License-Identifier: BSD-2-Clause

//! What is built in, as an editor shows it: a signature and a line or two
//! for each prelude function, each method of the builtin types, and each
//! member of the modules that come with the language. In a signature `T`
//! is a list's item, `K` and `V` a map's key and value, and `V` the vector
//! a vector's method is called on; `substitute` puts the real types in.

const std = @import("std");

pub const Entry = struct {
    name: []const u8,
    sig: []const u8,
    doc: []const u8,
};

pub fn find(table: []const Entry, name: []const u8) ?Entry {
    for (table) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

pub const prelude = [_]Entry{
    .{ .name = "print", .sig = "print(values: any...)", .doc = "Writes the values with a space between each, and a line break." },
    .{ .name = "assert", .sig = "assert(ok: bool, message: any = null)", .doc = "Stops the script with a panic when `ok` is false, saying `message` if one is given." },
    .{ .name = "panic", .sig = "panic(message: any) noreturn", .doc = "Stops the script, with the message and a stack trace for the host." },
    .{ .name = "str", .sig = "str(value: any) string", .doc = "The value as text, the way `print` writes it." },
    .{ .name = "typeof", .sig = "typeof(value: any) string", .doc = "The name of the value's type: `\"int\"`, `\"[string]\"`, `\"Player\"`." },
    .{ .name = "int", .sig = "int(value: any) int", .doc = "An int from a float (dropping the fraction), a bool, an enum member, or text. From text it gives `!int`: the text may be no number." },
    .{ .name = "float", .sig = "float(value: any) float", .doc = "A float from an int or from text. From text it gives `!float`: the text may be no number." },
    .{ .name = "vec2", .sig = "vec2(x: float = 0, y: float = x) vec2", .doc = "A 2D vector: `vec2()`, `vec2(s)` for both parts, or `vec2(x, y)`." },
    .{ .name = "vec3", .sig = "vec3(x: float = 0, y: float = x, z: float = x) vec3", .doc = "A 3D vector: `vec3()`, `vec3(s)`, `vec3(xy, z)` or `vec3(x, y, z)`." },
    .{ .name = "color", .sig = "color(r: float, g: float, b: float, a: float = 1) color", .doc = "A colour: `color(\"#FF8000\")`, `color(\"#FF800080\")`, `color(grey)`, `color(r, g, b)` or `color(r, g, b, a)`, each part from 0 to 1." },
    .{ .name = "wait", .sig = "wait(seconds: float) float", .doc = "Something to `await`: `await wait(0.5)` comes back after half a second of script time." },
    .{ .name = "min", .sig = "min(values: any...) any", .doc = "The smallest of its arguments, or of the items of one list." },
    .{ .name = "max", .sig = "max(values: any...) any", .doc = "The largest of its arguments, or of the items of one list." },
    .{ .name = "abs", .sig = "abs(x: any) any", .doc = "How far a number is from zero; for a vector, each of its parts." },
    .{ .name = "clamp", .sig = "clamp(x: float, lo: float, hi: float) float", .doc = "`x`, kept between `lo` and `hi`. Ints give an int." },
    .{ .name = "range", .sig = "range(a: int, b: int = a, step: int = 1) [int]", .doc = "A list of ints: `range(n)` from 0 up to n, `range(a, b)` from a up to b, `range(a, b, step)` counting by step. A random number is `math.random_int(a, b)`." },
};

pub const list = [_]Entry{
    .{ .name = "push", .sig = "push(value: T)", .doc = "Adds `value` at the end." },
    .{ .name = "append", .sig = "append(value: T)", .doc = "Adds `value` at the end, as `push` does." },
    .{ .name = "pop", .sig = "pop() ?T", .doc = "Takes the last item out and gives it; null when the list is empty." },
    .{ .name = "first", .sig = "first() ?T", .doc = "The first item; null when the list is empty." },
    .{ .name = "last", .sig = "last() ?T", .doc = "The last item; null when the list is empty." },
    .{ .name = "insert", .sig = "insert(index: int, value: T)", .doc = "Puts `value` at `index`, moving what was there and after it along." },
    .{ .name = "remove", .sig = "remove(index: int) T", .doc = "Takes out the item at `index` and gives it." },
    .{ .name = "remove_value", .sig = "remove_value(value: T) bool", .doc = "Takes out the first item equal to `value`; whether there was one." },
    .{ .name = "clear", .sig = "clear()", .doc = "Takes every item out." },
    .{ .name = "contains", .sig = "contains(value: T) bool", .doc = "Whether an item is equal to `value`." },
    .{ .name = "index_of", .sig = "index_of(value: T) ?int", .doc = "Where the first item equal to `value` is; null when none is." },
    .{ .name = "count", .sig = "count(value: T) int", .doc = "How many items are equal to `value`." },
    .{ .name = "is_empty", .sig = "is_empty() bool", .doc = "Whether the list has no items." },
    .{ .name = "sort", .sig = "sort()", .doc = "Puts the items in order, smallest first, in place." },
    .{ .name = "sort_by", .sig = "sort_by(less: fn(T, T) bool)", .doc = "Puts the items in the order `less` says, in place: `xs.sort_by(|a, b| a.hp < b.hp)`." },
    .{ .name = "reverse", .sig = "reverse()", .doc = "Turns the list around, in place." },
    .{ .name = "reversed", .sig = "reversed() [T]", .doc = "A new list, the items in the other order." },
    .{ .name = "copy", .sig = "copy() [T]", .doc = "A new list with the same items." },
    .{ .name = "extend", .sig = "extend(other: [T])", .doc = "Adds every item of `other` at the end." },
    .{ .name = "join", .sig = "join(separator: string = \"\") string", .doc = "The items as text, with `separator` between each." },
    .{ .name = "sum", .sig = "sum() T", .doc = "The items added together." },
    .{ .name = "map", .sig = "map(f: fn(T) any) [any]", .doc = "A new list of what `f` gives for each item: `xs.map(|x| x * 2)`." },
    .{ .name = "filter", .sig = "filter(keep: fn(T) bool) [T]", .doc = "A new list of the items `keep` says yes to." },
    .{ .name = "reduce", .sig = "reduce(f: fn(any, T) any, start: any) any", .doc = "Each item folded into one value: `xs.reduce(|total, x| total + x, 0)`." },
    .{ .name = "find", .sig = "find(test: fn(T) bool) ?T", .doc = "The first item `test` says yes to; null when there is none." },
    .{ .name = "any", .sig = "any(test: fn(T) bool) bool", .doc = "Whether `test` says yes to any item." },
    .{ .name = "all", .sig = "all(test: fn(T) bool) bool", .doc = "Whether `test` says yes to every item." },
};

pub const map = [_]Entry{
    .{ .name = "get", .sig = "get(key: K, default: V = null) ?V", .doc = "The value at `key`, or `default` - null unless given - when there is none. `m[key]` is a panic for a missing key." },
    .{ .name = "has", .sig = "has(key: K) bool", .doc = "Whether there is a value at `key`; the same as `key in m`." },
    .{ .name = "contains", .sig = "contains(key: K) bool", .doc = "Whether there is a value at `key`; the same as `key in m`." },
    .{ .name = "remove", .sig = "remove(key: K) bool", .doc = "Takes out the value at `key`; whether there was one." },
    .{ .name = "set", .sig = "set(key: K, value: V)", .doc = "Puts `value` at `key`, as `m[key] = value` does." },
    .{ .name = "keys", .sig = "keys() [K]", .doc = "The keys, in the order they were first put in." },
    .{ .name = "values", .sig = "values() [V]", .doc = "The values, in the order of `keys()`." },
    .{ .name = "clear", .sig = "clear()", .doc = "Takes everything out." },
    .{ .name = "is_empty", .sig = "is_empty() bool", .doc = "Whether the map holds nothing." },
    .{ .name = "copy", .sig = "copy() [K: V]", .doc = "A new map with the same keys and values." },
    .{ .name = "merge", .sig = "merge(other: [K: V])", .doc = "Puts in every key and value of `other`, over those already here." },
};

pub const string = [_]Entry{
    .{ .name = "is_empty", .sig = "is_empty() bool", .doc = "Whether the string has no characters." },
    .{ .name = "contains", .sig = "contains(text: string) bool", .doc = "Whether `text` is somewhere in the string." },
    .{ .name = "starts_with", .sig = "starts_with(prefix: string) bool", .doc = "Whether the string starts with `prefix`." },
    .{ .name = "ends_with", .sig = "ends_with(suffix: string) bool", .doc = "Whether the string ends with `suffix`." },
    .{ .name = "find", .sig = "find(text: string) ?int", .doc = "Where `text` first is, in characters; null when it is not there." },
    .{ .name = "count", .sig = "count(text: string) int", .doc = "How many times `text` is in the string, not overlapping." },
    .{ .name = "replace", .sig = "replace(old: string, new: string) string", .doc = "A new string with each `old` replaced by `new`." },
    .{ .name = "split", .sig = "split(separator: string = \" \") [string]", .doc = "The pieces between each `separator`. With none, the words between runs of spaces, tabs and line breaks." },
    .{ .name = "lines", .sig = "lines() [string]", .doc = "The lines, without their line breaks." },
    .{ .name = "chars", .sig = "chars() [string]", .doc = "Each character, as a string of its own." },
    .{ .name = "bytes", .sig = "bytes() [int]", .doc = "Each byte of its UTF-8, as an int." },
    .{ .name = "trim", .sig = "trim() string", .doc = "Without the spaces, tabs and line breaks at either end." },
    .{ .name = "trim_start", .sig = "trim_start() string", .doc = "Without the spaces, tabs and line breaks at the start." },
    .{ .name = "trim_end", .sig = "trim_end() string", .doc = "Without the spaces, tabs and line breaks at the end." },
    .{ .name = "upper", .sig = "upper() string", .doc = "In capital letters." },
    .{ .name = "lower", .sig = "lower() string", .doc = "In small letters." },
    .{ .name = "reversed", .sig = "reversed() string", .doc = "The characters in the other order." },
    .{ .name = "repeat", .sig = "repeat(times: int) string", .doc = "The string `times` times over." },
    .{ .name = "pad_start", .sig = "pad_start(width: int, fill: string = \" \") string", .doc = "Made `width` characters long with `fill` before it; as it is when it is that long already." },
    .{ .name = "pad_end", .sig = "pad_end(width: int, fill: string = \" \") string", .doc = "Made `width` characters long with `fill` after it; as it is when it is that long already." },
    .{ .name = "code", .sig = "code(index: int = 0) int", .doc = "The Unicode code point of the character at `index`." },
};

pub const vector = [_]Entry{
    .{ .name = "length", .sig = "length() float", .doc = "How long the vector is." },
    .{ .name = "length_squared", .sig = "length_squared() float", .doc = "The length times itself: cheaper, for comparing lengths." },
    .{ .name = "normalized", .sig = "normalized() V", .doc = "The same direction with a length of 1; zero stays zero." },
    .{ .name = "dot", .sig = "dot(other: V) float", .doc = "The dot product." },
    .{ .name = "cross", .sig = "cross(other: V) V", .doc = "The cross product: a `vec3` for `vec3`s, the z part of it, a float, for `vec2`s." },
    .{ .name = "distance_to", .sig = "distance_to(other: V) float", .doc = "How far it is to `other`." },
    .{ .name = "distance_squared_to", .sig = "distance_squared_to(other: V) float", .doc = "The distance to `other` times itself: cheaper, for comparing." },
    .{ .name = "direction_to", .sig = "direction_to(other: V) V", .doc = "The direction to `other`, with a length of 1." },
    .{ .name = "lerp", .sig = "lerp(to: V, weight: float) V", .doc = "The point `weight` of the way to `to`: 0 is here, 1 is `to`." },
    .{ .name = "move_toward", .sig = "move_toward(to: V, delta: float) V", .doc = "Moved `delta` toward `to`, without passing it." },
    .{ .name = "limit_length", .sig = "limit_length(max: float) V", .doc = "Made no longer than `max`." },
    .{ .name = "clamp", .sig = "clamp(lo: V, hi: V) V", .doc = "Each part kept between those of `lo` and `hi`." },
    .{ .name = "min", .sig = "min(other: V) V", .doc = "The smaller of each part." },
    .{ .name = "max", .sig = "max(other: V) V", .doc = "The larger of each part." },
    .{ .name = "abs", .sig = "abs() V", .doc = "Each part made positive." },
    .{ .name = "floor", .sig = "floor() V", .doc = "Each part rounded down." },
    .{ .name = "ceil", .sig = "ceil() V", .doc = "Each part rounded up." },
    .{ .name = "round", .sig = "round() V", .doc = "Each part rounded to the nearest whole number." },
    .{ .name = "is_zero", .sig = "is_zero() bool", .doc = "Whether every part is zero." },
    .{ .name = "angle", .sig = "angle() float", .doc = "The angle from the x axis, in radians. `vec2` only." },
    .{ .name = "angle_to", .sig = "angle_to(other: vec2) float", .doc = "The angle to `other`, in radians. `vec2` only." },
    .{ .name = "rotated", .sig = "rotated(radians: float) vec2", .doc = "Turned by an angle. `vec2` only." },
    .{ .name = "orthogonal", .sig = "orthogonal() vec2", .doc = "Turned a quarter turn. `vec2` only." },
};

pub const signal = [_]Entry{
    .{ .name = "connect", .sig = "connect(target: fn)", .doc = "Calls `target` with the signal's values each time it is emitted: a function, a method bound to an instance, or a lambda." },
    .{ .name = "once", .sig = "once(target: fn)", .doc = "Calls `target` the next time the signal is emitted, and then no more." },
    .{ .name = "disconnect", .sig = "disconnect(target: fn) bool", .doc = "Stops calling `target`; whether it was connected." },
    .{ .name = "emit", .sig = "emit(values: any...)", .doc = "Calls what is connected, in order, with the values; and wakes the tasks that `await` the signal." },
    .{ .name = "is_connected", .sig = "is_connected(target: fn) bool", .doc = "Whether `target` is connected." },
    .{ .name = "connections", .sig = "connections() int", .doc = "How many are connected." },
};

/// What builtin values have, read as `x.name`.
pub const property = [_]Entry{
    .{ .name = "len", .sig = "len: int", .doc = "How many there are: characters in a string, items in a list, keys in a map." },
    .{ .name = "x", .sig = "x: float", .doc = "The first part." },
    .{ .name = "y", .sig = "y: float", .doc = "The second part." },
    .{ .name = "z", .sig = "z: float", .doc = "The third part." },
    .{ .name = "r", .sig = "r: float", .doc = "How red, from 0 to 1." },
    .{ .name = "g", .sig = "g: float", .doc = "How green, from 0 to 1." },
    .{ .name = "b", .sig = "b: float", .doc = "How blue, from 0 to 1." },
    .{ .name = "a", .sig = "a: float", .doc = "How opaque, from 0 to 1." },
    .{ .name = "name", .sig = "name: string", .doc = "The error's name: `NotFound` for `error.NotFound`." },
    .{ .name = "message", .sig = "message: ?string", .doc = "What the error says, when it was made with one: `error.NotFound(\"no save\")`." },
};

pub const math = [_]Entry{
    .{ .name = "pi", .sig = "pi: float", .doc = "Half a turn in radians: 3.14159..." },
    .{ .name = "tau", .sig = "tau: float", .doc = "A whole turn in radians: 6.28318..." },
    .{ .name = "e", .sig = "e: float", .doc = "Euler's number: 2.71828..." },
    .{ .name = "inf", .sig = "inf: float", .doc = "Infinity." },
    .{ .name = "nan", .sig = "nan: float", .doc = "Not a number." },
    .{ .name = "epsilon", .sig = "epsilon: float", .doc = "The gap between 1.0 and the next float." },
    .{ .name = "max_int", .sig = "max_int: int", .doc = "The largest int." },
    .{ .name = "min_int", .sig = "min_int: int", .doc = "The smallest int." },
    .{ .name = "sqrt", .sig = "sqrt(x: float) float", .doc = "The square root." },
    .{ .name = "pow", .sig = "pow(base: float, exponent: float) float", .doc = "`base` to the power of `exponent`; ints give an int." },
    .{ .name = "exp", .sig = "exp(x: float) float", .doc = "e to the power of `x`." },
    .{ .name = "log", .sig = "log(x: float, base: float = e) float", .doc = "The logarithm, natural unless a base is given." },
    .{ .name = "log2", .sig = "log2(x: float) float", .doc = "The base-2 logarithm." },
    .{ .name = "log10", .sig = "log10(x: float) float", .doc = "The base-10 logarithm." },
    .{ .name = "sin", .sig = "sin(radians: float) float", .doc = "The sine." },
    .{ .name = "cos", .sig = "cos(radians: float) float", .doc = "The cosine." },
    .{ .name = "tan", .sig = "tan(radians: float) float", .doc = "The tangent." },
    .{ .name = "asin", .sig = "asin(x: float) float", .doc = "The arcsine, in radians." },
    .{ .name = "acos", .sig = "acos(x: float) float", .doc = "The arccosine, in radians." },
    .{ .name = "atan", .sig = "atan(x: float) float", .doc = "The arctangent, in radians." },
    .{ .name = "atan2", .sig = "atan2(y: float, x: float) float", .doc = "The angle of the point (x, y) from the x axis, in radians." },
    .{ .name = "sinh", .sig = "sinh(x: float) float", .doc = "The hyperbolic sine." },
    .{ .name = "cosh", .sig = "cosh(x: float) float", .doc = "The hyperbolic cosine." },
    .{ .name = "tanh", .sig = "tanh(x: float) float", .doc = "The hyperbolic tangent." },
    .{ .name = "floor", .sig = "floor(x: float) int", .doc = "Rounded down, to an int. NaN and the infinities are panics." },
    .{ .name = "ceil", .sig = "ceil(x: float) int", .doc = "Rounded up, to an int. NaN and the infinities are panics." },
    .{ .name = "round", .sig = "round(x: float) int", .doc = "Rounded to the nearest, to an int. NaN and the infinities are panics." },
    .{ .name = "trunc", .sig = "trunc(x: float) int", .doc = "The fraction dropped, to an int. NaN and the infinities are panics." },
    .{ .name = "fract", .sig = "fract(x: float) float", .doc = "The fraction: `x - floor(x)`." },
    .{ .name = "sign", .sig = "sign(x: float) float", .doc = "-1, 0 or 1, as `x` is below, at or above zero." },
    .{ .name = "mod", .sig = "mod(a: float, b: float) float", .doc = "The remainder with the sign of `b`: `mod(-1, 5)` is 4, where `-1 % 5` is -1." },
    .{ .name = "wrap", .sig = "wrap(value: float, lo: float, hi: float) float", .doc = "`value` wrapped into the range from `lo` up to `hi`, as an angle wraps." },
    .{ .name = "lerp", .sig = "lerp(from: float, to: float, weight: float) float", .doc = "The value `weight` of the way from `from` to `to`." },
    .{ .name = "inverse_lerp", .sig = "inverse_lerp(from: float, to: float, value: float) float", .doc = "How far of the way from `from` to `to` `value` is." },
    .{ .name = "remap", .sig = "remap(value: float, from_lo: float, from_hi: float, to_lo: float, to_hi: float) float", .doc = "`value` moved from one range into another." },
    .{ .name = "smoothstep", .sig = "smoothstep(from: float, to: float, x: float) float", .doc = "0 below `from`, 1 above `to`, and a smooth curve between." },
    .{ .name = "move_toward", .sig = "move_toward(from: float, to: float, delta: float) float", .doc = "Moved `delta` toward `to`, without passing it." },
    .{ .name = "deg_to_rad", .sig = "deg_to_rad(degrees: float) float", .doc = "Degrees in radians." },
    .{ .name = "rad_to_deg", .sig = "rad_to_deg(radians: float) float", .doc = "Radians in degrees." },
    .{ .name = "is_nan", .sig = "is_nan(x: float) bool", .doc = "Whether `x` is not a number." },
    .{ .name = "is_inf", .sig = "is_inf(x: float) bool", .doc = "Whether `x` is an infinity." },
    .{ .name = "approx_eq", .sig = "approx_eq(a: float, b: float, tolerance: float = 0.000001) bool", .doc = "Whether `a` and `b` are no further apart than `tolerance`." },
    .{ .name = "random", .sig = "random() float", .doc = "A random float from 0 up to 1. The numbers start from the same seed each run, so a replay replays." },
    .{ .name = "random_range", .sig = "random_range(lo: float, hi: float) float", .doc = "A random float from `lo` up to `hi`." },
    .{ .name = "random_int", .sig = "random_int(lo: int, hi: int) int", .doc = "A random int from `lo` to `hi`, both included." },
    .{ .name = "seed", .sig = "seed(n: int)", .doc = "Starts the random numbers again from `n`." },
};

pub const json = [_]Entry{
    .{ .name = "parse", .sig = "parse(text: string) !any", .doc = "The value the JSON text holds - maps, lists, strings, numbers, bools and null - or an error saying where the text is wrong." },
    .{ .name = "stringify", .sig = "stringify(value: any, indent: int = 0) string", .doc = "The value as JSON text: one line, or laid out with `indent` spaces a level." },
};

pub const os = [_]Entry{
    .{ .name = "args", .sig = "args: [string]", .doc = "The arguments the script was given." },
    .{ .name = "read_file", .sig = "read_file(path: string) !string", .doc = "What the file holds, or an error naming what went wrong." },
    .{ .name = "write_file", .sig = "write_file(path: string, text: string) !void", .doc = "Writes the text to the file, replacing what it held." },
    .{ .name = "exists", .sig = "exists(path: string) bool", .doc = "Whether there is a file or a folder at `path`." },
    .{ .name = "list_dir", .sig = "list_dir(path: string) ![string]", .doc = "The names of what is in the folder." },
    .{ .name = "time", .sig = "time() float", .doc = "Seconds since the program started." },
    .{ .name = "read_line", .sig = "read_line() ?string", .doc = "The next line typed in; null at the end of the input." },
    .{ .name = "exit", .sig = "exit(code: int) noreturn", .doc = "Ends the program with the exit code." },
};

pub fn module(name: []const u8) []const Entry {
    if (std.mem.eql(u8, name, "math")) return &math;
    if (std.mem.eql(u8, name, "json")) return &json;
    if (std.mem.eql(u8, name, "os")) return &os;
    return &.{};
}

pub const types = [_]Entry{
    .{ .name = "int", .sig = "int", .doc = "A whole number, 64 bits. `/` of two ints drops the fraction; `%` keeps the sign of the left side." },
    .{ .name = "float", .sig = "float", .doc = "A number with a fraction, 64 bits." },
    .{ .name = "bool", .sig = "bool", .doc = "`true` or `false`." },
    .{ .name = "string", .sig = "string", .doc = "Text, in UTF-8. Strings cannot be changed; their methods give new ones." },
    .{ .name = "void", .sig = "void", .doc = "No value: what a function that returns nothing gives." },
    .{ .name = "any", .sig = "any", .doc = "Any value, checked when it goes where a type is written." },
    .{ .name = "vec2", .sig = "vec2", .doc = "Two floats, `x` and `y`: a value, copied when assigned." },
    .{ .name = "vec3", .sig = "vec3", .doc = "Three floats, `x`, `y` and `z`: a value, copied when assigned." },
    .{ .name = "color", .sig = "color", .doc = "A colour: `r`, `g`, `b` and `a`, each from 0 to 1." },
    .{ .name = "error", .sig = "error", .doc = "An error value: `error.NotFound`, or `error.NotFound(\"why\")` with a message." },
    .{ .name = "task", .sig = "task", .doc = "What calling a coroutine without `await` gives: it runs on its own, and can be awaited for its result." },
    .{ .name = "signal", .sig = "signal", .doc = "A signal of an instance: connect functions to it, emit it, or `await` it." },
    .{ .name = "null", .sig = "null", .doc = "No value, where a `?T` allows it." },
};

pub const annotations = [_]Entry{
    .{ .name = "import", .sig = "@import(path: string)", .doc = "A module: `const math = @import(\"math\");`, one built in, one the host made, or a file next to this one." },
    .{ .name = "export", .sig = "@export", .doc = "Shows the field in an editor's inspector, and saves it with the scene." },
};

/// A signature with the real types put in for `T`, `K` and `V`: each one
/// a name of its own, not a letter of a longer one.
pub fn substitute(out: *std.Io.Writer, sig: []const u8, t: []const u8, k: []const u8, v: []const u8) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < sig.len) : (i += 1) {
        const c = sig[i];
        const alone = (i == 0 or !isName(sig[i - 1])) and (i + 1 == sig.len or !isName(sig[i + 1]));
        if (alone and (c == 'T' or c == 'K' or c == 'V')) {
            try out.writeAll(switch (c) {
                'T' => t,
                'K' => k,
                else => v,
            });
        } else try out.writeByte(c);
    }
}

fn isName(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "a signature takes the receiver's types" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try substitute(&w, "get(key: K, default: V = null) ?V", "?", "string", "int");
    try std.testing.expectEqualStrings("get(key: string, default: int = null) ?int", w.buffered());
    w = .fixed(&buf);
    try substitute(&w, "sort_by(less: fn(T, T) bool) [T]", "Enemy", "?", "?");
    try std.testing.expectEqualStrings("sort_by(less: fn(Enemy, Enemy) bool) [Enemy]", w.buffered());
}

test "every builtin method has its entry" {
    const Vm = @import("../vm/Vm.zig");
    const vm = try Vm.create(std.testing.allocator, .{});
    defer vm.destroy();
    const tables = .{ .{ Vm.BuiltinType.list, &list }, .{ Vm.BuiltinType.map, &map }, .{ Vm.BuiltinType.string, &string }, .{ Vm.BuiltinType.vec2, &vector }, .{ Vm.BuiltinType.vec3, &vector }, .{ Vm.BuiltinType.signal, &signal } };
    inline for (tables) |pair| {
        var it = vm.methods.getPtrConst(pair[0]).keyIterator();
        while (it.next()) |k| {
            if (find(pair[1], k.*.bytes()) == null) {
                std.debug.print("no entry for the {s} method `{s}`\n", .{ @tagName(pair[0]), k.*.bytes() });
                return error.MissingEntry;
            }
        }
    }
    var names = vm.prelude.keyIterator();
    while (names.next()) |k| if (find(&prelude, k.*.bytes()) == null) {
        std.debug.print("no entry for the prelude's `{s}`\n", .{k.*.bytes()});
        return error.MissingEntry;
    };
    inline for (.{ "math", "json" }) |m| {
        const module_obj = vm.native_modules.get(m).?;
        for (module_obj.names.items) |n| if (find(module(m), n.bytes()) == null) {
            std.debug.print("no entry for `{s}.{s}`\n", .{ m, n.bytes() });
            return error.MissingEntry;
        };
    }
}
