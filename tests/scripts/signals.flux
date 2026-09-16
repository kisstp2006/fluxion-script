struct Player {
    var hp: int = 3;
    signal died(by: string);
    signal hurt(amount: int);

    fn damage(self, amount: int, by: string) {
        self.hp -= amount;
        self.hurt.emit(amount);
        if (self.hp <= 0) self.died.emit(by);
    }
}

const p = Player{};
var hits = 0;
p.hurt.connect(|amount| {
    hits += amount;
});
p.died.once(|by| print("died to", by));
fn onDeath(by: string) {
    print("game over:", by);
}
p.died.connect(onDeath);
p.damage(1, "rat");
p.damage(2, "wolf");
// out: died to wolf
// out: game over: wolf
p.damage(1, "bat");
// out: game over: bat
print(hits, p.died.connections(), p.died.is_connected(onDeath));
// out: 4 1 true
_ = p.died.disconnect(onDeath);
p.damage(1, "ghost");
print(p.died.connections());
// out: 0
