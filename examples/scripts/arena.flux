// A small game with no window: enemies walk in on the player, a tower shoots
// the nearest, waves come on a timer, and signals tell the score what
// happened. It plays for six seconds.
//
//     flux run --watch examples/scripts/arena.flux
//
// With `--watch`, change a number below while it plays - the tower's
// `damage`, how far away enemies start - and save: the game goes on with
// it.

const math = @import("math");
const os = @import("os");

enum Mode { walking, stunned }

struct Enemy {
    var pos: vec2 = vec2(0, 0);
    var speed: float = 40;
    var hp: int = 3;
    var mode: Mode = .walking;
    signal died(at: vec2);

    fn step(self, target: vec2, dt: float) {
        switch (self.mode) {
            .walking => self.pos = self.pos.move_toward(target, self.speed * dt),
            .stunned => {},
        }
    }

    fn hit(self, damage: int) {
        self.hp -= damage;
        if (self.hp <= 0) {
            self.died.emit(self.pos);
            return;
        }
        self.mode = .stunned;
        recover(self);
    }
}

/// Called without `await`, a function that waits runs as a task of its own.
fn recover(e: Enemy) {
    await wait(0.2);
    e.mode = .walking;
}

struct Score {
    var kills: int = 0;
    var leaked: int = 0;

    fn onKill(self, at: vec2) {
        self.kills += 1;
    }
}

const player = vec2(0, 0);
const score = Score{};
const damage = 1;
var enemies: [Enemy] = [];
var time = 0.0;

fn spawn(count: int) {
    for (0..count) |i| {
        const angle = math.tau * float(i) / float(count);
        const e = Enemy{ .pos = vec2(160, 0).rotated(angle), .speed = 30 + float(i % 4) * 8 };
        e.died.connect(score.onKill);
        enemies.push(e);
    }
}

fn nearest() ?Enemy {
    var best: ?Enemy = null;
    var best_distance = math.inf;
    for (enemies) |e| {
        const d = e.pos.distance_to(player);
        if (d < best_distance) {
            best = e;
            best_distance = d;
        }
    }
    return best;
}

fn waves() {
    for (1..=3) |wave| {
        print(f"wave {wave}: {wave * 4} enemies");
        spawn(wave * 4);
        await wait(2.0);
    }
}

fn tower() {
    while (true) {
        await wait(0.3);
        shoot();
    }
}

/// What the tower does each time, in a function of its own: the tower's
/// loop never ends, so it goes on in the code it started with, but each
/// call to `shoot` runs the newest.
fn shoot() {
    if (nearest()) |target| target.hit(damage);
}

fn frame(dt: float) {
    time += dt;
    for (enemies) |e| {
        e.step(player, dt);
        if (e.hp > 0 and e.pos.distance_to(player) < 4) {
            score.leaked += 1;
            e.hp = 0;
        }
    }
    enemies = enemies.filter(|e| e.hp > 0);
}

fn play() {
    var shown = 0;
    while (time < 6.0) {
        await wait(1.0 / 60.0);
        frame(1.0 / 60.0);
        if (int(time) > shown) {
            shown = int(time);
            print(f"{shown}s: {enemies.len} on the field, {score.kills} down, {score.leaked} got through");
        }
    }
    print(f"over: {score.kills} down, {score.leaked} got through");
    os.exit(0);
}

waves();
tower();
play();
