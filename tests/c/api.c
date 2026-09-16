/* SPDX-License-Identifier: BSD-2-Clause */

#include "fluxion_script.h"

#include <stdio.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond)                                                       \
    do {                                                                  \
        if (!(cond)) {                                                    \
            fprintf(stderr, "%s:%d: failed: %s\n", __FILE__, __LINE__, #cond); \
            failures++;                                                   \
        }                                                                 \
    } while (0)

typedef struct Output {
    char text[1024];
    size_t len;
} Output;

static void collect(void *user, const char *bytes, size_t len) {
    Output *out = (Output *)user;
    if (out->len + len < sizeof out->text) {
        memcpy(out->text + out->len, bytes, len);
        out->len += len;
        out->text[out->len] = 0;
    }
}

static flux_status add_scaled(flux_vm *vm, const flux_value *args, size_t nargs, flux_value *result, void *user) {
    (void)vm;
    double scale = *(double *)user;
    double sum = 0;
    for (size_t i = 0; i < nargs; i++) sum += flux_as_float(args[i]);
    *result = flux_float(sum * scale);
    return FLUX_OK;
}

static flux_status refuse(flux_vm *vm, const flux_value *args, size_t nargs, flux_value *result, void *user) {
    (void)args;
    (void)nargs;
    (void)result;
    (void)user;
    return flux_fail(vm, "refused from C");
}

static const char script[] =
    "struct Player {\n"
    "    var name: string = \"ada\";\n"
    "    var hp: int = 10;\n"
    "}\n"
    "var players: [Player] = [];\n"
    "fn spawn(name: string) Player {\n"
    "    const p = Player{ .name = name };\n"
    "    players.push(p);\n"
    "    return p;\n"
    "}\n"
    "fn total(scale: float) float {\n"
    "    return add_scaled(1, 2, 3.5) * scale;\n"
    "}\n"
    "fn bad() { refuse(); }\n"
    "print(\"loaded\", players.len);\n";

/* The same file with a field more on Player, and a function reading it. */
static const char reloaded[] =
    "struct Player {\n"
    "    var name: string = \"ada\";\n"
    "    var level: int = 1;\n"
    "    var hp: int = 10;\n"
    "}\n"
    "var players: [Player] = [];\n"
    "fn spawn(name: string) Player {\n"
    "    const p = Player{ .name = name };\n"
    "    players.push(p);\n"
    "    return p;\n"
    "}\n"
    "fn total(scale: float) float {\n"
    "    return add_scaled(1, 2, 3.5) * scale * 2;\n"
    "}\n"
    "fn bad() { refuse(); }\n"
    "fn levels() int { var n = 0; for (players) |p| n += p.level; return n; }\n"
    "print(\"loaded\", players.len);\n";

int fxs_c_api_test(void) {
    flux_vm *vm = flux_vm_create();
    CHECK(vm != NULL);
    Output out = {{0}, 0};
    flux_vm_set_output(vm, collect, &out);
    double scale = 2.0;
    CHECK(flux_define(vm, "add_scaled", add_scaled, 0, -1, &scale) == FLUX_OK);
    CHECK(flux_define(vm, "refuse", refuse, 0, 0, NULL) == FLUX_OK);

    flux_module *m = NULL;
    flux_status status = flux_load(vm, "game.flux", script, sizeof script - 1, &m);
    if (status != FLUX_OK) fprintf(stderr, "%s\n", flux_error(vm, NULL));
    CHECK(status == FLUX_OK);
    CHECK(strcmp(out.text, "loaded 0\n") == 0);

    flux_value spawn, result, name;
    CHECK(flux_get(vm, m, "spawn", &spawn) == FLUX_OK);
    CHECK(flux_string(vm, "bob", 3, &name) == FLUX_OK);
    CHECK(flux_call(vm, spawn, &name, 1, &result) == FLUX_OK);
    CHECK(flux_type_of(result) == FLUX_OBJECT);
    flux_value field;
    CHECK(flux_field(vm, result, "name", &field) == FLUX_OK);
    size_t len = 0;
    CHECK(strcmp(flux_as_string(field, &len), "bob") == 0 && len == 3);
    CHECK(flux_set_field(vm, result, "hp", flux_int(42)) == FLUX_OK);
    CHECK(flux_field(vm, result, "hp", &field) == FLUX_OK && flux_as_int(field) == 42);
    CHECK(flux_set_field(vm, result, "hp", flux_float(1.5)) == FLUX_PANIC);

    flux_value players;
    CHECK(flux_get(vm, m, "players", &players) == FLUX_OK);
    CHECK(flux_list_len(players) == 1);
    char text[128];
    CHECK(flux_to_string(flux_list_get(players, 0), text, sizeof text) > 0);
    CHECK(strcmp(text, "Player{ .name = \"bob\", .hp = 42 }") == 0);

    flux_value total, arg = flux_float(10);
    CHECK(flux_get(vm, m, "total", &total) == FLUX_OK);
    CHECK(flux_call(vm, total, &arg, 1, &result) == FLUX_OK);
    CHECK(flux_as_float(result) == 130.0);

    flux_value bad;
    CHECK(flux_get(vm, m, "bad", &bad) == FLUX_OK);
    CHECK(flux_call(vm, bad, NULL, 0, &result) == FLUX_PANIC);
    CHECK(strstr(flux_error(vm, NULL), "refused from C") != NULL);
    CHECK(strstr(flux_error(vm, NULL), "in bad at game.flux:14") != NULL);

    /* A reload keeps bob, gives him the new field, and runs the new code. */
    flux_value bob = flux_list_get(players, 0);
    CHECK(flux_hold(vm, bob) == FLUX_OK);
    CHECK(flux_reload(vm, m, reloaded, sizeof reloaded - 1) == FLUX_OK);
    CHECK(flux_field(vm, bob, "level", &field) == FLUX_OK && flux_as_int(field) == 1);
    CHECK(flux_field(vm, bob, "hp", &field) == FLUX_OK && flux_as_int(field) == 42);
    flux_value levels;
    CHECK(flux_get(vm, m, "levels", &levels) == FLUX_OK);
    CHECK(flux_call(vm, levels, NULL, 0, &result) == FLUX_OK && flux_as_int(result) == 1);
    CHECK(flux_call(vm, total, &arg, 1, &result) == FLUX_OK && flux_as_float(result) == 260.0);
    const char *broken = "fn levels() int { return \"x\"; }";
    CHECK(flux_reload(vm, m, broken, strlen(broken)) == FLUX_COMPILE_ERROR);
    CHECK(strstr(flux_error(vm, NULL), "the return value must be int, not string") != NULL);
    CHECK(flux_call(vm, levels, NULL, 0, &result) == FLUX_OK && flux_as_int(result) == 1);
    CHECK(strcmp(out.text, "loaded 0\n") == 0);
    flux_release(vm, bob);

    CHECK(flux_load(vm, "broken.flux", "var x: int = \"s\";", 17, NULL) == FLUX_COMPILE_ERROR);
    CHECK(strstr(flux_error(vm, NULL), "the variable must be int, not string") != NULL);
    CHECK(flux_get(vm, m, "missing", &result) == FLUX_NOT_FOUND);

    flux_value v = flux_vec2(1.5f, -2.0f);
    float xy[2];
    flux_as_vec2(v, xy);
    CHECK(flux_type_of(v) == FLUX_VEC2 && xy[0] == 1.5f && xy[1] == -2.0f);

    flux_vm_destroy(vm);
    return failures;
}
