struct Door {
    signal opened(by: string);
}

const door = Door{};

fn intro() {
    print("intro: start");
    await wait(1.0);
    print("intro: after a second");
    const who = await door.opened;
    print("intro: door opened by", who);
}

fn countdown(n: int) int {
    var left = n;
    while (left > 0) {
        await wait(0.5);
        left -= 1;
    }
    return n * 10;
}

fn waiter() {
    const result = await countdown(2);
    print("countdown gave", result);
}

fn opener() {
    await wait(2.0);
    door.opened.emit("the wind");
}

const t = intro();
print("main goes on while intro waits", typeof(t));
waiter();
opener();
print("main is done");
// out: intro: start
// out: main goes on while intro waits task
// out: main is done
// out: intro: after a second
// out: countdown gave 20
// out: intro: door opened by the wind
