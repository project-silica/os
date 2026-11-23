/*
 * QEMU TCG plugin: how many times each guest instruction at a kernel
 * address (the upper half) executed. Written to the file named by the
 * plugin argument out=<path> at exit, one "<hex vaddr> <count>" line per
 * instruction; with cpu=<n>, only what virtual processor n executed. Used by tools/profile.sh under -icount, one vCPU thread at a
 * time, so the plain increments below cannot race.
 */
#include <glib.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <qemu-plugin.h>

QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;

typedef struct { uint64_t vaddr; uint64_t count; } Insn;
static GHashTable *insns; /* vaddr -> Insn* */
static GMutex lock;
static char out[4096] = "insncount.txt";
static int only = -1; /* count only this vCPU (cpu=<n>); -1: every one */

static void exec(unsigned int vcpu, void *udata) {
    if (only < 0 || (int)vcpu == only) ((Insn *)udata)->count++;
}

#if QEMU_PLUGIN_VERSION >= 7
static void trans(struct qemu_plugin_tb *tb, void *udata) {
#else
static void trans(qemu_plugin_id_t id, struct qemu_plugin_tb *tb) {
#endif
    size_t n = qemu_plugin_tb_n_insns(tb);
    for (size_t i = 0; i < n; i++) {
        struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, i);
        uint64_t va = qemu_plugin_insn_vaddr(insn);
        if (va < 0xffff800000000000ULL) continue;
        g_mutex_lock(&lock);
        Insn *e = g_hash_table_lookup(insns, &va);
        if (!e) {
            e = g_new0(Insn, 1);
            e->vaddr = va;
            g_hash_table_insert(insns, &e->vaddr, e);
        }
        g_mutex_unlock(&lock);
        qemu_plugin_register_vcpu_insn_exec_cb(insn, exec, QEMU_PLUGIN_CB_NO_REGS, e);
    }
}

#if QEMU_PLUGIN_VERSION >= 7
static void at_exit(void *p) {
#else
static void at_exit(qemu_plugin_id_t id, void *p) {
#endif
    FILE *f = fopen(out, "w");
    if (!f) return;
    GHashTableIter it; gpointer k, v;
    g_hash_table_iter_init(&it, insns);
    while (g_hash_table_iter_next(&it, &k, &v)) {
        Insn *e = v;
        if (e->count) fprintf(f, "%" PRIx64 " %" PRIu64 "\n", e->vaddr, e->count);
    }
    fclose(f);
}

QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id, const qemu_info_t *info, int argc, char **argv) {
    for (int i = 0; i < argc; i++)
        if (strncmp(argv[i], "out=", 4) == 0) g_strlcpy(out, argv[i] + 4, sizeof out);
        else if (strncmp(argv[i], "cpu=", 4) == 0) only = atoi(argv[i] + 4);
    insns = g_hash_table_new(g_int64_hash, g_int64_equal);
#if QEMU_PLUGIN_VERSION >= 7
    qemu_plugin_register_vcpu_tb_trans_cb(id, trans, NULL);
#else
    qemu_plugin_register_vcpu_tb_trans_cb(id, trans);
#endif
    qemu_plugin_register_atexit_cb(id, at_exit, NULL);
    return 0;
}
