# Putting Flux in a program

A game or an application runs scripts through one `flux.Vm`: it compiles
them, calls into them, gives them functions of its own, moves their time
on, and reloads them while it runs. Everything below is in
[`examples/embed/main.zig`](../examples/embed/main.zig) and, for C,
[`examples/embed/main.c`](../examples/embed/main.c), which run with
`zig build example-embed` and `zig build example-embed-c`.

- [From Zig](#from-zig)
- [Functions and modules of the host's](#functions-and-modules-of-the-hosts)
- [The host's own values, through reflection](#the-hosts-own-values-through-reflection)
- [Time, tasks and panics](#time-tasks-and-panics)
- [Keeping a script in its place](#keeping-a-script-in-its-place)
- [Reloading a script while it runs](#reloading-a-script-while-it-runs)
- [From C](#from-c)
- [Values and the collector](#values-and-the-collector)

## From Zig

```zig
const flux = @import("fluxion_script");

const vm = try flux.Vm.create(gpa, .{ .out = &stdout.interface });
defer vm.destroy();

const module = vm.load("logic.flux", source) catch {
    try vm.writeDiagnostics(stderr, .{ .color = true });
    return;
};
const update = vm.get(module, "update").?;       // a variable, function or type by name
_ = try vm.call(update, &.{ .float(1.0 / 60.0) });
_ = try vm.callName(module, "reset", &.{});
```

`load` is `compile` then `run`: compiling checks the whole file and makes
its code, running runs its top-level statements - the modules it imports
first. After either fails, `vm.diagnostics` has every error and warning;
`writeDiagnostics` prints them as the `flux` command does, with the line and
a caret under the place, and `flux.diag.render.jsonLines` as one JSON object
per line for an editor.

`Vm.Options`:

| Field | |
| --- | --- |
| `out` | where `print` writes; nowhere without it |
| `loader` | how `@import("file.flux")` finds a file: `flux.FileLoader` reads from disk next to the importing file, or give your own to read from a pack or memory |
| `max_frames` | calls deep before a panic says "stack overflow" (8000) |
| `max_bytes` | the most the scripts' objects may take; past it an allocation fails with `error.OutOfMemory` rather than the program running out |
| `gc` | the collector's pace; `.stress` collects on every allocation, for tests |
| `on_task_panic` | called with each panic in a task nothing waited for |

## Functions and modules of the host's

```zig
fn clamp01(x: f64) f64 {
    return std.math.clamp(x, 0, 1);
}

fn roll(sides: i64, turn: i64) !i64 {
    if (sides < 1) return error.NoSides;     // the script sees error.NoSides
    return @mod(turn * 7 + 3, sides) + 1;
}

try vm.defineFn("clamp01", clamp01);                  // every script can call it
_ = try vm.defineModule("game", .{                   // `const game = @import("game");`
    .roll = roll,
    .version = 3,
});
```

A Zig function's signature says how its arguments and result convert:
ints of any width (a value that does not fit is a panic that says so),
floats, `bool`, `[]const u8`, optionals, enums (from the member's name or
number), `[2]f32` and `[3]f32` as `vec2` and `vec3`, `flux.Value` as it
is. A Zig error comes back to the script as an error value of that name.
For full control, a native is `fn (vm: *Vm, args: []Value) Vm.Error!Value`,
given with `vm.define(name, func, min_args, max_args)`; it stops the script
with `vm.fail("why {d}", .{n})`.

## The host's own values, through reflection

```zig
const Player = struct {
    name: []const u8 = "Ada",
    hp: i32 = 100,
    pos: Vec2 = .{},

    pub const reflect_methods = .{.heal};

    pub fn heal(self: *Player, amount: i32) i32 { ... }
};

var player: Player = .{};
const p = try vm.handle(&player);   // the player itself, not a copy
try vm.hold(p);
_ = try vm.call(update, &.{p});
```

A script reads and writes the struct's fields by name and calls the
methods `reflect_methods` lists, through
[Fluxion Reflect](https://github.com/kisstp2006/fluxion-reflect):
`player.hp -= 3`, `player.pos.x += 1`, `player.heal(5)`. A wrong type is
a panic that names the field; a misspelt name gets a "did you mean". The
value must outlive the scripts' use of it; `vm.newHandle(T)` makes one the
script owns instead, freed with the handle.

## Time, tasks and panics

A script's `await wait(1.0)` waits on the host's clock: call
`vm.update(dt)` once a frame with the seconds since the last, and the
tasks whose time has come run on.

A mistake at run time returns `error.Panic` from the call that met it.
`vm.panic` holds the message and every frame; `vm.writePanic(w, .{})`
prints it with the line, and `vm.clearPanic()` lets the program go on -
the VM is fine after a panic, only that call was abandoned. A panic in a
task nothing waits for goes to `on_task_panic`.

## Keeping a script in its place

```zig
vm.setBudget(1_000_000);   // loop rounds before a panic stops the script
vm.interrupt();            // from any thread: stop at the next loop round
vm.setBudget(null);
```

A budget counts the rounds of every loop and stops the script when they run
out, with the usual message and trace, so a script that never ends cannot
freeze the program. `interrupt` does the same from another thread - a
watchdog, a "stop" button. While neither is set, loops pay one test a
round. `max_bytes` bounds memory the same way. What a script can reach is
what the host gives it: there is no file access without the `os` module,
which the host installs (`flux.os.install`) or does not.

## Reloading a script while it runs

```zig
const report = vm.reload(module, new_source) catch |err| switch (err) {
    error.CompileFailed => {           // nothing changed; the old code runs on
        try vm.writeDiagnostics(stderr, .{});
        return;
    },
    error.Panic => ...,                // the new code is in; an initializer failed
    error.Busy => ...,                 // called from inside a script: call it between frames
    error.OutOfMemory => return err,
};
```

The `flux` command does this with `flux run --watch file.flux`: each file
the script loaded is reloaded when it is saved.

**What stays.** The new source is compiled over what the old one made, so
whatever holds those things goes on with the new code: the module; each
struct, whose instances keep their identity - a value the host holds is
the same instance after - and get the new fields, matched by name; each
enum, whose stored members follow their names to their new places; each
function and method, so a value holding one, a signal connected to one,
calls the new code. A variable declared as before - the same kind and type
- keeps its value. Top-level statements do not run again; the initializers
of new variables do, and of those whose declaration changed. The modules
importing the reloaded one are compiled again with it.

**When a shape changes.** Code from before can still be running: a task in
the middle of a function, a lambda made by the old code. Compiled code
reads fields by position and trusts the checks it made, so it may run on
only if the reload kept every shape it relies on - each struct's fields,
each function's signature, each variable's type, each enum's members.
When one changes:

- tasks in the middle of old code are stopped, each with a warning at the
  line it was waiting on;
- signal connections to lambdas the old code made are dropped, each with a
  warning at the lambda; a bound method - `door.opened.connect(player.onDoor)`
  - stays connected, and calls the new method;
- an old lambda still held somewhere panics if called, saying why.

When no shape changes - a body, a constant, a default, a new function -
nothing is stopped, and running code finishes in the code it began with.

**A loop that never ends keeps its own code.** A task running
`while (true) { await wait(0.3); target.hit(damage); }` goes on with the
code it started with, `damage` and all. Put what you want to tune in a
function the loop calls - `while (true) { await wait(0.3); shoot(); }` -
and a reload changes it on the next call. [`examples/scripts/arena.flux`](../examples/scripts/arena.flux)
is built this way.

The report says how many modules were compiled again, which declaration's
shape changed (if one did), how many instances moved and tasks stopped; its
warnings are in `vm.diagnostics`. From C, `flux_reload` does the same.

## From C

```c
#include "fluxion_script.h"

flux_vm *vm = flux_vm_create();
flux_vm_set_output(vm, write_out, NULL);
flux_define(vm, "spawn_rate", spawn_rate, 1, 1, &base);

flux_module *m;
if (flux_load(vm, "waves.flux", source, len, &m) != FLUX_OK) {
    fprintf(stderr, "%s", flux_error(vm, NULL));
}
flux_value update, args[2] = {flux_float(1.0 / 60.0), flux_int(2)};
flux_get(vm, m, "update", &update);
flux_call(vm, update, args, 2, NULL);
flux_update(vm, 1.0 / 60.0);
flux_reload(vm, m, edited, edited_len);
flux_vm_destroy(vm);
```

`zig build` installs `libfluxion_script` and
[`include/fluxion_script.h`](../include/fluxion_script.h) into `zig-out`.
Every call returns a `flux_status`; after one that is not `FLUX_OK`,
`flux_error` gives the compile errors or the panic with its trace as text.
A native written in C gets its arguments as an array and writes its result:

```c
static flux_status spawn_rate(flux_vm *vm, const flux_value *args, size_t nargs, flux_value *result, void *user) {
    if (flux_type_of(args[0]) != FLUX_INT) return flux_fail(vm, "spawn_rate takes a level");
    *result = flux_float(*(const double *)user * (double)flux_as_int(args[0]));
    return FLUX_OK;
}
```

## Values and the collector

A `Value` is sixteen bytes, passed by value: null, bools, ints, floats,
vectors and enum members are held in it; strings, lists, maps, instances
and functions point into the VM's heap. The collector frees what nothing
reaches - a script's variables, the registers of running code, what is
held. A value the host keeps across calls must be held: `vm.hold(v)` and
`vm.release(v)`, or `flux_hold` and `flux_release`, as many releases as
holds. A value only passed straight back into a call needs nothing.
