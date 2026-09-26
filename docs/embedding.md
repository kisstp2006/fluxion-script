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
`player.hp -= 3`, `player.pos.x += 1`, `player.heal(5)`. An enum's member
and a tagged union's arm that holds nothing go both ways as their names:
`window.setFullscreen("borderless")`. A wrong type is
a panic that names the field; a misspelt name gets a "did you mean". The
value must outlive the scripts' use of it; `vm.newHandle(T)` makes one the
script owns instead, freed with the handle, and `vm.adoptHandle(pointer)`
hands the collector a value the host made with `vm.gpa.create` - one a
script may keep after the host is done with it. A value known only at run time
as a `fluxion_reflect.Value` - a component found by name - is
`vm.handleOf(value)`.

A method's last arguments may be left out when its `reflect_methods` entry
gives them defaults, and a field may be written through a method of its own
(both are Fluxion Reflect attributes). A name kept in a `[N]u8` reads as its
text, without the zeros that pad it:

```zig
const Clip = struct {
    name: [32]u8 = @splat(0),

    pub const reflect_methods = .{
        .play = .{ attr.Params{ .names = &.{ "name", "speed" } }, attr.defaults(.{ "", 1.0 }) },
        .setName = .{},
    };
    // `clip.name = "run"` calls `clip.setName("run")`.
    pub const reflect_fields = .{ .name = .{attr.Setter{ .method = "setName" }} };
    ...
};
```

`clip.play()`, `clip.play("run")` and `clip.play("run", 2.0)` all call it;
a call given too few or too many says how many it takes: "`play` takes 0 to
2 arguments, and was given 3".

A reflected method may take the VM calling it, as its first parameter after
`self`, and return a `flux.Value` as it is - which is how a method hands a
script something only the VM can make:

```zig
pub fn get(self: *EntityRef, vm: *flux.Vm, component: []const u8) !flux.Value {
    const found = self.app.componentOf(self.entity, component) orelse return .null;
    return vm.handleOf(found);    // a script writes `self.entity.get("Health")`
}
```

The script does not pass the VM, and a panic the method raises with
`vm.fail` stops the script as a native's does.

What a method returns by value - a struct, a slice - is copied into the
script's own, as `vm.valueOf` copies, so it outlives the call. What it
returns by pointer is a handle into the host's value, as `vm.handle` makes.

A handle points at the value where it was when the handle was made. A value
that moves - a component in storage that is compacted and grown - wants a
*live* handle, which the host looks up again each time a script uses it:

```zig
const resolver: flux.Resolver = .{
    .context = &world,
    .resolve = findComponent,   // fn (context, key: u64, type) ?fluxion_reflect.Value
    .why = "its entity was despawned, or the component taken off",
};
const health = try vm.liveHandle(&resolver, entity_bits, fluxion_reflect.typeOf(Health));
```

Every read, write, index and method call on it asks `resolve` first, and so
does every handle reached through it - `self.body.shape.radius = 3` too. When
`resolve` gives null, the script stops with a panic: "this Health is gone:
its entity was despawned, or the component taken off". The resolver outlives
the handles made with it.

## A script's structs, as an engine uses them

An engine puts a script on an entity: it makes an instance of a struct the
script declares, calls its `ready` and `update` if it has them, and wires
its signals to its own.

```zig
// Before compiling scripts - and on an editor's analysis VMs, so that
// completions know them.
try vm.declareHostMember("entity", "The entity this script is on.");
try vm.defineGlobal("app", try vm.handle(&app), "The running game.");

const class = vm.get(module, "Player").?;
const player = try vm.instantiate(class, &.{.{ .name = "entity", .value = entity_handle }});
try vm.hold(player);

// Looked up once, called every frame; looked up again after a reload.
if (vm.methodNamed(class, "update")) |update| _ = try vm.call(update, &.{ player, .float(dt) });
_ = try vm.callMethod(player, "on_hit", &.{.int(10)});

// Signals, both ways.
const heard = try vm.native("on_died", onDied, 1, 1, &engine);  // finds &engine in vm.current_native.?.user
try vm.connectSignal(player, "died", heard);
try vm.emitSignal(player, "healed", &.{.int(5)});
```

A host member is on every struct's instances without being declared, and
a script reads it as `self.entity` but cannot assign it; one a script
makes with `Player{}` has it null, and printing an instance leaves it out.
A global defined with `defineGlobal` is seen by every module without an
import, and is compiled into the scripts that use it, so define it first.

An engine with a signal table of its own hears every emit of an instance's
signal without connecting to each: `Vm.Options.on_emit` is called with the
instance, the signal's name and its arguments, once per emit, after the
signal's own connections; an error it returns stops the script that
emitted. The other way, `vm.valueOf(reflect_value)` turns an argument the
engine has only as a `fluxion_reflect.Value` into the script's own - numbers,
strings and vectors converted, a slice as a list, anything else copied into
a handle the collector owns - and `vm.reflectOf(handle)` gives the host what
a handle stands for now.

Some of the host's types are better seen as something else. An entity is
eight bytes to an engine, and to a script it is the handle `self.entity`
is, the same one each time. `Vm.Options.host_types` names such types, each
with its two conversions, and they are asked before anything else whenever
a value of the type crosses: a field read or written through a handle, a
reflected method's argument or result, and `vm.valueOf`.

```zig
const entity_type: flux.HostType = .{
    .type = fluxion_reflect.typeOf(Entity),
    .to_script = entityToScript,     // fn (vm, fluxion_reflect.Value) Vm.Error!Value
    .from_script = entityFromScript, // fn (vm, into: fluxion_reflect.Value, Value) Vm.Error!void
};
const vm = try flux.Vm.create(gpa, .{ .host_types = &.{entity_type} });
```

The conversions find the host's own state through `vm.host`. A value that
is not of the type is theirs to refuse, with `vm.fail` and a message saying
what was wanted.

`flux.methodsOf(class, &buffer)` and `flux.signalsOf(class, &buffer)` list
what a struct has, its own first and then each parent's, in the order
written: each a `flux.Member` with the name, the number of parameters, the
parameters as written (`by: ?Actor`) and the doc comment. That is what an
editor's signal panel shows.

`flux.fieldsOf(vm, class, &buffer)` lists its fields the same way, each a
`flux.FieldInfo`: the name, whether it is marked `@export`, what it holds
(`kind`, `nullable`, a list's `element`, an enum's `members`), its default
and its doc comment - what an editor draws a row for without running a
line of the script. Every other annotation on the field is kept with its
arguments, which must be literals: `flux.annotationOf(field, "range")`
gives `@range(0, 100)`'s two numbers, and an editor decides what `@range`,
`@multiline`, `@group("Stats")` or its own `@entity` mean.

```zig
var found: [64]flux.FieldInfo = undefined;
for (flux.fieldsOf(vm, class, &found)) |field| {
    if (!field.exported) continue;
    const range = flux.annotationOf(field, "range");   // ?[]const Value
    try vm.setField(instance, field.name, given);        // checked as an assignment is
}
```

`vm.setField` and `vm.getField` set and read a field by name from the host,
checked against its type as a script's assignment would be;
`flux.enumMember`, `vm.newColor` and `vm.newList` make the values a field
of those kinds takes.

A host's signals of its own - an engine's `timeout`, heard by a script -
are `vm.newSignal(name, arity)`: a signal a script connects to, `once`s and
`await`s as it would its own, and the host emits with
`vm.emitSignalValue(signal, args)`. A task waiting on it wakes then.

`Vm.Options.host_member` is asked for a member of a handle that is none of
its fields - `timer.timeout` on a component whose struct has no such field:
a value to give the script, or null for the usual "has no field" panic.
`Vm.Options.host_set_member` is asked the same when such a member is
written - `label.text = "Hi"` on a component whose words the host keeps
beside it - and says whether it took the value. The compiler knows them by
what `vm.declareMember` says: see below.
And a reflected method's parameter of type `flux.Value` takes what the
script passed as it is - a function to call later, a signal, an instance.

### The host's types in scripts

A struct, a union or a handle of the host's is a type to the compiler, as
a script's own struct is: named in a type, known by what its reflected type
lists, and checked. `vm.declareType(t)` makes one a name scripts write, by
the type's own name without its file:

```zig
inline for (.{ App, EntityRef, Sprite, Timer, InputEvent, KeyEvent, Key }) |T|
    try vm.declareType(fluxion_reflect.typeOf(T));
```

```flux
fn aim(target: Entity) Sprite {
    return target.get(Sprite);      // a type where a value goes
}
```

A value's type is known from where it comes: a global the host defined (by
its handle's type, or where the scripts are only compiled, by
`vm.declareGlobal(name, type, doc)`), a host member
(`vm.declareHostMemberOf`), a field, what a method gives back. Its fields
and methods are offered after the `.`, their signatures shown as a call is
typed and their docs on a hover, and each call is checked as a script
function's is: how many arguments - the last ones may be left out where the
method gives them defaults (`attr.defaults`) - and of what types.

- **An enum** of the host's is a Flux enum of the same name and members,
  both ways: `deck.setMode(.loop)`, `if (event.key == .space)`,
  `Key.space`. `HostType.given` says what a converted type is when it is
  one of the language's own - a texture's path is a `string`, a colour a
  `color`; `HostType.script` when it is a handle of another of the host's
  types, as an entity is.
- **A tagged union** is its live arm: the payload's handle, or for an arm
  that holds nothing, the member of its tag naming it (`.borderless`, where
  the union is wanted). `x is KeyEvent` asks which arm it is, and inside
  the `if` - after an `and`, and past an `if (!(x is KeyEvent)) return;` -
  a constant is known as that arm's payload: its fields, its methods and the
  union's. A field every arm has is the union's too; one only some have is
  a mistake until `is` says which, and the compiler names the arms that
  have it.
- **A method given a type** - a parameter of type `*const
  fluxion_reflect.Type`, which a script passes by name - that gives back a
  `flux.Value` gives a value of that type, a `?flux.Value` one that may be
  null: `entity.get(Sprite)` is a Sprite, `entity.find(Sprite)` a
  `?Sprite`.
- **An error** a method returns stops the script, with the error's name,
  as a mistake in the script would; the errors of the methods of a type
  marked `flux.GivesErrors` (in `reflect_attributes`) are values the script
  catches instead, and the method's result is `!T`: `files.readText(path)
  catch ""`.
- **Another type's methods**: `vm.extend(of, by, receiver)` gives the
  values of `of` every method of `receiver` - a handle of `by` - whose first
  argument a script gives is one of `of`: `app.childCount(e)` as
  `e.childCount()`. `flux.Alias{ .name = "parent" }` names one as the value's
  method, where its own name reads badly there.
- **Members its type does not list** - a component's signal, the words it
  keeps beside it - are `vm.declareMember(.{ .of, .name, .type, .writable,
  .doc })`, and the host finds them as the script runs, through
  `Vm.Options.host_member` and `host_set_member`. A type whose values have
  members only the host can know, named by data - a material's numbers,
  named by its shader - is `vm.declareOpen(t)`: another name on one of them
  is `any` rather than a mistake.
- **The methods the host calls** on a script's instances, `vm.declareHook(.{
  .name = "input", .params = &.{.{ .name = "event", .type = typeOf(InputEvent) }} })`:
  a struct's method of the name is checked against it as it is compiled,
  a parameter it gave no type (or `any`) gets the hook's, and an editor
  offers the whole method - header and empty body - where a struct's member
  is written.
- **The annotations the host reads**, `vm.declareAnnotation(.{ .name =
  "range", .sig = "@range(min, max, step)", .doc = ... })`, are offered
  after a `@`; another one on a field is warned of.
- **What the host says of its members**, besides a member's `attr.Doc`:
  `Vm.Options.docs`, a list sorted by `"Type.member"` - what an engine
  generates from its doc comments.

## Time, tasks and panics

A script's `await wait(1.0)` waits on the host's clock: call
`vm.update(dt)` once a frame with the seconds since the last, and the
tasks whose time has come run on.

A host that pauses some things and not others gives each task an owner and
holds the owners it has paused:

```zig
const before = vm.setTaskOwner(entity_id);   // tasks started now are this one's
_ = try vm.call(method, args);
_ = vm.setTaskOwner(before);

try vm.updateHolding(dt, .{ .context = game, .held = isPaused });
```

A task started by another task takes that task's owner; one started from
outside any has whatever `setTaskOwner` last said, `0` at first. While its
owner is held a task's wait stands still - it neither wakes nor comes nearer
to waking - and it picks up where it was once it is not. A task woken by a
signal or by another task finishing wakes either way: what woke it is
running. An owner that is gone for good - an entity despawned - has its
tasks stopped with `vm.stopTasks(entity_id)`: none of them goes on, and a
task of another owner waiting for one fails at its `await`.

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
