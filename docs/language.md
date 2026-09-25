# The Flux language

Flux reads like Zig and C - braces, semicolons, `fn`, `const` and `var`,
`|x|` captures - and runs like a scripting language: no build step, no
memory to manage, values that know their own type. Types are yours to give
or to leave out. Where you give them the compiler checks them before the
program starts and the code runs on typed instructions; where you leave
them out the value is checked at run time, at the place it crosses into
typed code.

The examples here are pieces of programs; [`examples/scripts`](../examples/scripts)
has whole ones, run with `flux run file.flux`. The code blocks are marked
as Zig for their colours: it is the nearest language GitHub knows.

- [A first program](#a-first-program)
- [Values and types](#values-and-types)
- [Variables](#variables)
- [Operators](#operators)
- [Control flow](#control-flow)
- [Functions](#functions)
- [Structs](#structs)
- [Enums](#enums)
- [Null and errors](#null-and-errors)
- [Lists, maps and strings](#lists-maps-and-strings)
- [Vectors and colours](#vectors-and-colours)
- [Tasks and `await`](#tasks-and-await)
- [Signals](#signals)
- [Modules](#modules)
- [Tests](#tests)
- [Built in](#built-in)
- [How types are checked](#how-types-are-checked)
- [Mistakes, and what the compiler says](#mistakes-and-what-the-compiler-says)

## A first program

```zig
const json = @import("json");

struct Item {
    var name: string = "";
    var weight: float = 0;
}

fn heaviest(items: [Item]) ?Item {
    var best: ?Item = null;
    for (items) |item| {
        if (best == null or item.weight > best.?.weight) best = item;
    }
    return best;
}

const bag = [Item{ .name = "rope", .weight = 1.5 }, Item{ .name = "map", .weight = 0.1 }];
if (heaviest(bag)) |item| print(f"the heaviest is the {item.name}, at {item.weight:.1} kg");
print(json.stringify(bag));
```

Code at the top of a file runs once, in order, when the file is loaded.
Declarations - functions, structs, enums - can come in any order: a
function may call one declared below it.

## Values and types

| Type | What it holds | Written |
| --- | --- | --- |
| `null` | nothing | `null` |
| `bool` | true or false | `true`, `false` |
| `int` | a 64-bit integer; going past its range is a panic | `42`, `-7`, `1_000_000`, `0xff`, `0b101`, `0o17` |
| `float` | a 64-bit float | `2.5`, `1.5e3`, `0.5` (not `.5`) |
| `string` | UTF-8 text, never changed in place | `"hi\n"`, `f"x is {x}"`, multi-line below |
| `vec2`, `vec3` | two or three 32-bit floats, held in the value | `vec2(1, 2)`, `vec3(1, 2, 3)` |
| `color` | four floats, red green blue alpha | `color("#FF8000")`, `color(1, 0.5, 0)`, `color("royalblue")`, `hsv(30, 1, 1)` |
| `[T]` | a list of `T` | `[1, 2, 3]`, `[]` |
| `[K: V]` | a map from `K` to `V`, in the order keys were added | `{"hp": 10}`, `{}` |
| `?T` | a `T`, or null | |
| `!T` | a `T`, or an error | |
| `error` | an error value: a name and, if given, a message | `error.NotFound`, `error.Bad("why")` |
| `fn(A, B) R` | a function | `fn add(...)`, `\|x\| x + 1` |
| `task` | a coroutine running on its own | what calling a coroutine gives |
| `signal` | something that happens, which functions connect to | `signal died(by: string);` in a struct |
| a struct | an instance of it | `Enemy{ .hp = 3 }` |
| an enum | one of its members | `State.idle`, or `.idle` where the type is known |
| `any` | anything, checked where it is used | |

Strings count characters, not bytes: `"héllo".len` is 5 and `"héllo"[1]`
is `"é"`. The escapes are `\n \t \r \0 \\ \" \' \{ \}`, `\xNN` and
`\u{1F600}`.

A string over several lines is one line per `\\`, as in Zig; nothing in it
is an escape:

```zig
const usage =
    \\usage: tool <file>
    \\  --verbose   say more
;
```

An f-string puts values into text. After a `:` comes how to show it:

```zig
const name = "Ada";
const count = 3;
print(f"{name} has {count} items");     // the value as print shows it
print(f"{3.14159:.2}");                 // 3.14: two digits after the point
print(f"{42:>6}|{7:<4}|{7:^5}|");       // right, left, centred in a width
print(f"{255:x} {255:X} {5:b} {8:o}");  // ff FF 101 10
print(f"{5:03}");                       // 005: zeros in front
print(f"{12345.678:+.3e}");             // +1.235e4: a sign, and exponent form
print(f"{{braces}}");                   // {braces}
```

`typeof(x)` names a value's type as text: `"int"`, `"list"`, the struct's
name for an instance, `"fn"` for any function.

## Variables

```zig
const limit = 10;          // never assigned again
var count = 0;             // its type is int: the value says so
var name: string = "Ada";  // or said outright
var target: ?Enemy = null; // null needs a type to be null of
count += 1;
_ = parse(text);           // a value you mean to drop
```

A variable holds one type for its life: `var count = 0;` then
`count = "many";` is a compile error. `const` is a binding that does not
change; what it holds may - a `const` list still takes `push`.

Variables at the top of a file belong to the module: every function in it
sees them, and a module importing it can read the ones whose names do not
start with `_`. Variables inside functions are locals, and cost nothing to
use. Function parameters and loop captures are constants.

## Operators

| Operator | What it does |
| --- | --- |
| `+ - * / %` | arithmetic. `int / int` truncates toward zero, `%` takes the sign of the left side, as in C. `math.mod` is the one that wraps (`math.mod(-1, 5) == 4`). An int result past the range of an int is a panic; `/ 0` and `% 0` on ints are too. Floats follow IEEE: `1.0 / 0` is `inf`. |
| `+% -% *%` | int arithmetic that wraps instead |
| `== != < <= > >=` | comparison; `==` on lists, maps and vectors compares what they hold (256 levels deep: a list may hold itself), on instances whether they are the same one. Comparisons do not chain: write `a < b and b < c`. |
| `and or !` | on bools only; `and` and `or` stop early |
| `& \| ^ ~ << >>` | bits, on ints |
| `x in xs` | a list holds it, a map has the key, a string contains the text |
| `x is T` | the value is a `T`: a struct (its own or one extending it), `int`, `string`, ... |
| `x orelse y` | `x`, or `y` if `x` is null |
| `x catch y`, `x catch \|e\| y` | `x`, or `y` if `x` is an error |
| `try x` | `x`, or return its error from this function |
| `x.?` | `x`, or a panic if it is null |
| `+` on strings and lists | joins them; `"ab" * 3` repeats |

## Control flow

```zig
if (hp <= 0) {
    die();
} else if (hp < 10) {
    flee();
} else fight();

const label = if (hp > 50) "healthy" else "hurt";   // `if` gives a value too

while (queue.len > 0) handle(queue.pop().?);
var i = 0;
while (i < 10) : (i += 2) print(i);                 // the part after `:` runs each time round

for (0..5) |n| print(n);                            // 0 to 4
for (1..=5) |n| print(n);                           // 1 to 5
for (items) |item, index| print(index, item);
for (scores) |name, score| print(name, score);      // a map: key and value
for ("héllo") |ch| print(ch);                       // a string: each character

outer: for (rows) |row| {
    for (row) |cell| {
        if (cell == 0) continue :outer;
        if (cell < 0) break :outer;
    }
}
```

`switch` takes values, lists of values and ranges, and gives a value when
used as one:

```zig
const grade = switch (score) {
    90...100 => "A",
    80...89 => "B",
    else => "C",
};

switch (key) {
    "w", "up" => move(0, -1),
    "s", "down" => move(0, 1),
    else => {},
}
```

On an enum a switch must handle every member, or say `else`; the compiler
names the ones missing. The same holds for a bool once `true` and `false`
are both there. A prong may set something - `.run => speed = 5,` - when
the switch's value is not wanted.

## Functions

```zig
fn add(a: int, b: int) int {
    return a + b;
}

fn greet(name, greeting = "hello") string {   // an untyped parameter is `any`
    return f"{greeting}, {name}!";
}

fn counter() fn() int {
    var count = 0;
    return fn () int {                           // a closure keeps `count`
        count += 1;
        return count;
    };
}

const double = |x: int| x * 2;                   // a lambda: one expression
const log = |msg| { print("[log]", msg); };      // or a block
fn apply(f: fn(int) int, x: int) int { return f(x); }
print(apply(|v| v + 1, 9));                      // 10: `v` is an int, from `f`'s type
```

A function can be declared inside another, and sees that one's variables.
A function whose type says it returns something must return on every path;
the compiler says so when one does not. A function with no return type and
no `return value;` gives nothing - a call to it cannot be used as a value.

## Structs

```zig
struct Enemy {
    /// Shown by an editor as the field's help.
    @export var hp: int = 10;
    var name = "enemy";
    var path: [vec2];                 // a list starts empty, a new one for each enemy
    var leader: ?Enemy = null;
    const MAX_HP = 100;               // belongs to the type: `Enemy.MAX_HP`
    signal died(by: string);

    fn spawn(name: string) Enemy {    // no `self`: called on the type, `Enemy.spawn("orc")`
        return Enemy{ .name = name };
    }

    fn damage(self, amount: int) {    // a method: `enemy.damage(3)`
        self.hp -= amount;
        if (self.hp <= 0) self.died.emit("damage");
    }
}

struct Boss extends Enemy {
    var phase = 1;

    fn damage(self, amount: int) {    // an override takes and gives what the original does
        self.hp -= amount / 2;
        if (self.hp < 5) self.phase = 2;
    }
}

const orc = Enemy.spawn("orc");
const dragon = Boss{ .name = "dragon", .hp = 50 };
const all: [Enemy] = [orc, dragon];   // a Boss is an Enemy
for (all) |e| e.damage(4);            // each runs its own `damage`
print(dragon is Enemy, orc is Boss);  // true false
```

A field needs a type or a default to take one from. A field of a struct
type, or a function type, needs a default unless it may be null. Instances
are shared, not copied: passing one to a function passes the same one.
`print` shows an instance as `Enemy{ .hp = 6, .name = "orc", ... }`.

`@export` marks a field an editor or a host shows and saves; `///` above a
field or a struct is its documentation, kept with the type.

## Enums

```zig
enum State { idle, run, jump = 10, dead }   // dead is 11

enum Dir {
    left,
    right,

    fn flip(self) Dir {
        return switch (self) {
            .left => .right,
            .right => .left,
        };
    }
}

var state: State = .idle;          // `.idle`: the type is known
state = State.run;
print(state, int(State.dead));     // State.run 11
print(Dir.left.flip());            // Dir.right
```

## Null and errors

A `?T` is a `T` or null. The compiler will not let one be used as a `T`
until it has been looked at:

```zig
fn find(names: [string], wanted: string) ?int {
    for (names) |n, i| if (n == wanted) return i;
    return null;
}

const at = find(names, "Ada") orelse -1;
if (find(names, "Bob")) |i| print("Bob is at", i) else print("no Bob");
while (queue.pop()) |job| run(job);
const sure = find(names, "Ada").?;   // a panic if it is null
```

A `!T` is a `T` or an error. Errors are values, made with a name and, if
you like, a message, and handled where you choose:

```zig
fn parsePort(text: string) !int {
    const n = try int(text);                    // a failed parse goes to the caller
    if (n < 1 or n > 65535) return error.OutOfRange(f"{n} is not a port");
    return n;
}

const port = parsePort(arg) catch 8080;
_ = parsePort(arg) catch |e| print(e.name, e.message orelse "");
if (parsePort(arg)) |p| listen(p) else |err| print("bad port:", err.name);
```

An error ignored is a compile error: `parsePort(arg);` alone is refused
with a hint to `try`, `catch` or `_ =` it.

`defer` runs a statement when the block ends, however it ends; `errdefer`
only when the function returns an error:

```zig
fn save(path: string) !void {
    const file = try open(path);
    defer file.close();
    errdefer print("could not save", path);
    try file.write(data());
}
```

A **panic** is different: a mistake in the program - an index past the
end, a `.?` on null, an int overflowing, `panic("why")` - stops the script
and gives the host the message and a stack trace. Scripts do not catch
panics; a host can go on after one.

## Lists, maps and strings

```zig
var xs = [5, 3, 8];
xs.push(1);
xs.sort();
print(xs[0], xs[-1], xs[1..3], xs.len);           // 1 8 [3, 5] 4
print(xs.map(|x| x * 2), xs.filter(|x| x > 3), xs.reduce(|a, x| a + x, 0));

var hp: [string: int] = {};
hp["ada"] = 10;
hp["bob"] = 7;
hp["ada"] += 5;
print(hp.get("cid"), hp.get("cid", 0), "bob" in hp, hp.keys());
```

| Lists | |
| --- | --- |
| `push(x)` `append(x)` `insert(i, x)` `extend(ys)` | add |
| `pop()` `first()` `last()` | `?T`: null when empty |
| `remove(i)` `remove_value(x)` `clear()` | take out |
| `contains(x)` `index_of(x)` `count(x)` `is_empty()` | ask |
| `sort()` `sort_by(\|a, b\| a < b)` `reverse()` | in place |
| `reversed()` `copy()` `xs[a..b]` | new lists |
| `map(f)` `filter(f)` `reduce(f, start)` `find(f)` `any(f)` `all(f)` | with a function |
| `join(sep)` `sum()` | into one value |

| Maps | |
| --- | --- |
| `m[k]` `m[k] = v` | read (a panic for a missing key), write |
| `get(k)` `get(k, default)` | `?V`, or the default |
| `has(k)` `contains(k)` `k in m` | ask |
| `remove(k)` `clear()` `merge(other)` `set(k, v)` | change |
| `keys()` `values()` `copy()` `is_empty()` `len` | look |

| Strings | |
| --- | --- |
| `len` `s[i]` `s[a..b]` | characters |
| `upper()` `lower()` `trim()` `trim_start()` `trim_end()` `reversed()` | new strings |
| `split(sep)` `split()` `lines()` `chars()` `bytes()` | into lists; `split()` splits on runs of spaces |
| `contains(t)` `starts_with(t)` `ends_with(t)` `find(t)` `count(t)` | search |
| `replace(a, b)` `repeat(n)` `pad_start(n, fill)` `pad_end(n, fill)` `code(i)` | the rest |

Lists and maps are shared like instances. A typed list only takes its
type: `var names: [string] = [];` refuses `names.push(3)` at compile time,
and a value of type `any` pushed into it is checked as it goes in.

## Vectors and colours

`vec2` and `vec3` are values, like numbers: assigning one copies it, and
`+ - *` work on them, with a float too.

```zig
var pos = vec2(1, 2);
const vel = vec2(3, 4);
pos += vel * 0.5;
pos.x = 0;
print(vel.length(), vel.normalized(), pos.distance_to(vel), vel.dot(vec2(1, 0)));
```

Their methods: `length` `length_squared` `normalized` `dot` `distance_to`
`distance_squared_to` `direction_to` `lerp` `move_toward` `limit_length`
`clamp` `min` `max` `abs` `floor` `ceil` `round` `is_zero` `cross`; and for
`vec2` only `angle` `angle_to` `rotated` `orthogonal`.

`color("#FF8000")`, `color("#FF800080")`, `color("#F80")`, `color(r, g, b)`,
`color(r, g, b, a)` or `color(grey)`; `color("royalblue")` by any of the web's
148 names, whatever their case; and `hsv(h, s, v)` or `hsv(h, s, v, a)`, the
hue in degrees round the wheel (0 red, 120 green, 240 blue). Its parts are
`.r .g .b .a`, floats from 0 to 1.

## Tasks and `await`

A function that `await`s is a coroutine. Called with `await`, it runs to
its end and gives its result. Called without, it starts a task - its own
line of execution - and gives the task at once; the caller goes on.

```zig
fn countdown(n: int) int {
    var left = n;
    while (left > 0) {
        await wait(1.0);          // come back in a second
        left -= 1;
    }
    return n;
}

fn intro() {
    print("3...");
    const took = await countdown(3);     // wait for it here
    print("go! after", took);
}

const t = intro();                // a task: intro waits, this goes on
print("loading");                 // printed before "go!"
```

What can be awaited: a number of seconds, a task (for its result), a
signal (for what it is emitted with). Time moves when the host says so -
`vm.update(dt)` each frame, or the `flux` command's clock. A task that
panics reports it; one waiting on it fails too, with the reason.

## Signals

A signal is declared in a struct and belongs to each instance. Functions,
methods and lambdas connect to it; `emit` calls each of them in order.

```zig
struct Door {
    signal opened(by: string);
}

fn log(who: string) {
    print(who, "opened the door");
}

const door = Door{};
door.opened.connect(log);
door.opened.once(|_| print("only the first time"));
door.opened.emit("the wind");
print(door.opened.connections(), door.opened.is_connected(log));   // 1 true

fn waitForDoor() {
    const who = await door.opened;   // a task can wait for one
    print("finally,", who);
}
```

`disconnect(f)` takes one off. Connecting a bound method -
`door.opened.connect(player.onDoor)` - survives a reload of the script;
see [reloading](embedding.md#reloading-a-script-while-it-runs).

## Modules

```zig
const math = @import("math");        // built in
const json = @import("json");        // built in
const os = @import("os");            // given by the `flux` command, or a host
const enemies = @import("enemies.flux");   // a file, next to this one
const game = @import("game");        // a module the host made

print(math.sqrt(2.0), enemies.spawn("orc"));
var boss: ?enemies.Enemy = null;     // its types come too
```

Everything a file declares is its module's, and every name not starting
with `_` can be used by a file importing it. A file is compiled once, the
first time it is imported, and its top-level code runs before the code of
the file importing it. A file that imports itself, through others, is
refused.

## Tests

```zig
fn clamp01(x: float) float { return clamp(x, 0.0, 1.0); }

test "clamp01 keeps what is in range" {
    assert(clamp01(0.5) == 0.5);
    assert(clamp01(2.0) == 1.0, "clamped from above");
}
```

`flux test file.flux` runs every `test` block and reports each, with the
stack trace of the ones that fail.

## Built in

Everywhere, with nothing imported:

| Name | What it does |
| --- | --- |
| `print(a, b, ...)` | writes the values with spaces between, and a new line |
| `assert(ok)`, `assert(ok, message)` | a panic when `ok` is false |
| `panic(message)` | stops the script |
| `str(x)` `typeof(x)` | text |
| `int(x)` | an int from a float (dropping the fraction), a bool, an enum member, or text. From text - or from a value that may be text - it gives `!int`, since the text may be no number. |
| `float(x)` | the same, to a float |
| `vec2(...)` `vec3(...)` `color(...)` `hsv(...)` | make one |
| `wait(seconds)` | something to `await` |
| `min(...)` `max(...)` | of their arguments, or of one list |
| `abs(x)` `clamp(x, lo, hi)` | numbers and vectors |
| `range(n)` `range(a, b)` `range(a, b, step)` | a list of ints |

`@import("math")`: `pi` `tau` `e` `inf` `nan` `epsilon` `max_int`
`min_int`; `sqrt` `pow` `log` `log2` `log10` `exp` `sin` `cos` `tan` `asin`
`acos` `atan` `atan2` `sinh` `cosh` `tanh`; `floor` `ceil` `round` `trunc`
(ints: NaN and the infinities are panics), `fract` `sign` `mod` `wrap`;
`lerp` `inverse_lerp` `remap` `smoothstep` `move_toward`; `deg_to_rad`
`rad_to_deg`; `is_nan` `is_inf` `approx_eq`; `random` `random_range`
`random_int` `seed`. The random numbers start from the same seed every
run, so a replay replays; `math.seed(n)` changes that.

`@import("json")`: `json.parse(text)` gives `!any` - maps, lists,
strings, numbers, bools and null, or an error with the line and column;
`json.stringify(value)` and `json.stringify(value, indent)` give text, of
lists, maps, instances (their fields), vectors (as arrays) and the rest.

`@import("os")`, where the host gives it (the `flux` command does):
`os.args`, `os.read_file(path)` and `os.write_file(path, text)` (errors
name what went wrong), `os.exists(path)`, `os.list_dir(path)`, `os.time()`
in seconds since the program started, `os.read_line()` (`?string`, null at
the end of input), `os.exit(code)`.

## How types are checked

A type written down is checked by the compiler. Each of these is refused
before the program runs, with the place marked:

```zig
var count: int = "three";          // the variable must be int, not string
heal(player);                      // `heal` takes 2 arguments, and is given 1
player.helth = 5;                  // `Player` has no field or method `helth` - did you mean `health`?
const hp: int = player.target.hp;  // cannot read `hp` of a value that may be null
if (player.hp) {}                  // a condition is a bool, and this is int
```

A value of type `any` - an untyped parameter, what `json.parse` gives, a
function from the host - can go anywhere, and is checked when it crosses
into a typed variable, parameter, field or list. That check is one
instruction; past it the code runs on typed instructions, which is where
Flux gets its speed. Leaving types out is fine for small scripts and glue;
giving them makes the compiler find more, and the code faster.

## Mistakes, and what the compiler says

Messages point at the place, say what was wanted and what was found, and
often what to write instead:

```text
error: cannot use `+` on int and !int
 --> waves.flux:7:9
  |
7 |         spawned += int(spawn_rate(level));
  |         ^^^^^^^    ---------------------- this is !int
  = help: use it once its error is handled - `x catch 0` - or pass the error on with `try x`
```

A mistake is reported once: a name that failed to be declared, a type that
failed to be worked out, does not bring a line of errors after it. The
`flux check --json` command gives each diagnostic as one line of JSON, for
editors.

Runtime mistakes stop with the message, the line, and every call that led
there:

```text
error: index 5 is out of bounds for a list of length 1
 --> inventory.flux:5:16
  |
5 |         return self.items[slot];
  |                ^^^^^^^^^^^^^^^^
stack trace, most recent call first:
    in Inventory.take at inventory.flux:5:16
    in open at inventory.flux:10:12
    in <main> at inventory.flux:16:7
```
