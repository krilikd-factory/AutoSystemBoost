#pragma once
/*
 * LSPosed's verbose log, read and switched from the command line (fix187):
 *
 *     asb --lspd verbose-get  [db]          -> "verbose=on|off|default_on|unknown"
 *     asb --lspd verbose-set  on|off [db]   -> writes LSPosed's own setting, prints the new state
 *     asb --lspd verbose-unset [db]         -> removes the row (LSPosed's default again)
 *     asb --lspd modules [db]               -> fix277: read-only module/scope inventory
 *                                              "module|pkg|enabled|scopes" and "scope|module|app|user"
 *     asb --lspd scope-del MOD APP USER [db] -> V66: removes one scope row, "result=removed|absent"
 *     asb --lspd scope-add MOD APP USER [db] -> V66: puts one back, "result=added|present|no_module"
 *     asb --lspd module-set MOD 0|1 [db]     -> V66: LSPosed's own enabled flag, "before=/after="
 *
 * Asked for by a user whose LSPosed had written 31 MB of verbose logs. LSPosed keeps the
 * switch in its own SQLite database, /data/adb/lspd/config/modules_config.db, table configs,
 * row (module_pkg_name 'lspd', user_id 0, group 'config', key 'enable_verbose_log'), the
 * value a Java-serialized java.lang.Boolean (ConfigManager.updateModulePrefs ->
 * SerializationUtils.serialize). With no row LSPosed treats it as ON
 * (`verboseLog = bool == null || (boolean) bool`). The daemon reads it when it starts and
 * stops its verbose capture then if the value is false - so a change here takes effect at the
 * next boot. The running daemon only listens to "!!stop_verbose!!" from its own process,
 * which is why ASB cannot switch it off live.
 *
 * Android ships no sqlite3 binary on user builds, but every one has the library behind its
 * own databases. It is opened with dlopen, so nothing is linked against it and a phone where
 * it cannot be opened simply answers "unknown" - the WebUI then offers to open the LSPosed
 * manager instead. SQLite does the locking against the daemon, which keeps the database open.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef ASB_LSPD_DB
#define ASB_LSPD_DB "/data/adb/lspd/config/modules_config.db"
#endif
#ifndef ASB_LSPD_SQLITE_LIB
#define ASB_LSPD_SQLITE_LIB "libsqlite.so"
#endif
/* Where a private copy of the database is read when LSPosed's own file cannot be (below). */
#ifndef ASB_LSPD_TMP
#define ASB_LSPD_TMP "/dev/.asb"
#endif

typedef struct sqlite3_ sqlite3_h;
typedef struct sqlite3_stmt_ sqlite3_stmt_h;
typedef struct {
    int (*open_v2)(const char *, sqlite3_h **, int, const char *);
    int (*close)(sqlite3_h *);
    int (*busy_timeout)(sqlite3_h *, int);
    int (*exec)(sqlite3_h *, const char *, int (*)(void *, int, char **, char **), void *, char **);
    int (*prepare_v2)(sqlite3_h *, const char *, int, sqlite3_stmt_h **, const char **);
    int (*step)(sqlite3_stmt_h *);
    const void *(*column_blob)(sqlite3_stmt_h *, int);
    int (*column_bytes)(sqlite3_stmt_h *, int);
    const unsigned char *(*column_text)(sqlite3_stmt_h *, int);
    int (*column_int)(sqlite3_stmt_h *, int);
    int (*finalize)(sqlite3_stmt_h *);
    void (*sfree)(void *);
} asb_sqlite_t;

#define ASB_SQLITE_OK        0
#define ASB_SQLITE_ROW       100
#define ASB_SQLITE_DONE      101
#define ASB_SQLITE_OPEN_READONLY   0x00000001
#define ASB_SQLITE_OPEN_READWRITE  0x00000002

/* java.lang.Boolean, as ObjectOutputStream writes it: stream header, class descriptor
 * (serialVersionUID 0xCD207280D59CFAEE, one boolean field "value"), then the value byte.
 * The layout this parser/writer was built against is named so a future LSPosed that
 * changes its serialization is diagnosable from the answer itself (audit K8): a
 * successful read answers format=v1, an unrecognized layout answers
 * reason=unexpected_schema - and the WebUI shows the reason instead of silently doing
 * nothing. */
#define ASB_LSPD_FORMAT "v1"
static const unsigned char g_lspd_bool_prefix[] = {
    0xAC, 0xED, 0x00, 0x05, 0x73, 0x72, 0x00, 0x11,
    'j', 'a', 'v', 'a', '.', 'l', 'a', 'n', 'g', '.', 'B', 'o', 'o', 'l', 'e', 'a', 'n',
    0xCD, 0x20, 0x72, 0x80, 0xD5, 0x9C, 0xFA, 0xEE, 0x02, 0x00, 0x01, 0x5A, 0x00, 0x05,
    'v', 'a', 'l', 'u', 'e', 0x78, 0x70
};

static int asb_sqlite_load(asb_sqlite_t *s) {
    static const char *const libs[] = {
        ASB_LSPD_SQLITE_LIB, "/system/lib64/libsqlite.so", "/system/lib/libsqlite.so"
    };
    void *h = NULL;
    for (size_t i = 0; i < sizeof(libs) / sizeof(libs[0]) && !h; i++) h = dlopen(libs[i], RTLD_NOW);
    if (!h) return -1;
    s->open_v2      = (int (*)(const char *, sqlite3_h **, int, const char *))dlsym(h, "sqlite3_open_v2");
    s->close        = (int (*)(sqlite3_h *))dlsym(h, "sqlite3_close");
    s->busy_timeout = (int (*)(sqlite3_h *, int))dlsym(h, "sqlite3_busy_timeout");
    s->exec         = (int (*)(sqlite3_h *, const char *, int (*)(void *, int, char **, char **), void *, char **))
                      dlsym(h, "sqlite3_exec");
    s->prepare_v2   = (int (*)(sqlite3_h *, const char *, int, sqlite3_stmt_h **, const char **))
                      dlsym(h, "sqlite3_prepare_v2");
    s->step         = (int (*)(sqlite3_stmt_h *))dlsym(h, "sqlite3_step");
    s->column_blob  = (const void *(*)(sqlite3_stmt_h *, int))dlsym(h, "sqlite3_column_blob");
    s->column_bytes = (int (*)(sqlite3_stmt_h *, int))dlsym(h, "sqlite3_column_bytes");
    s->column_text  = (const unsigned char *(*)(sqlite3_stmt_h *, int))dlsym(h, "sqlite3_column_text");
    s->column_int   = (int (*)(sqlite3_stmt_h *, int))dlsym(h, "sqlite3_column_int");
    s->finalize     = (int (*)(sqlite3_stmt_h *))dlsym(h, "sqlite3_finalize");
    s->sfree        = (void (*)(void *))dlsym(h, "sqlite3_free");
    return (s->open_v2 && s->close && s->busy_timeout && s->exec && s->prepare_v2 && s->step &&
            s->column_blob && s->column_bytes && s->column_text && s->column_int &&
            s->finalize && s->sfree) ? 0 : -1;
}

/* 1 on, 0 off, 2 no row (LSPosed's default: on), -1 unreadable / not a Boolean. */
static int asb_lspd_read(asb_sqlite_t *s, sqlite3_h *db) {
    sqlite3_stmt_h *st = NULL;
    const char *q = "SELECT data FROM configs WHERE module_pkg_name='lspd' AND user_id=0 "
                    "AND `group`='config' AND `key`='enable_verbose_log'";
    if (s->prepare_v2(db, q, -1, &st, NULL) != ASB_SQLITE_OK || !st) return -1;
    int rc = s->step(st), v = -1;
    if (rc == ASB_SQLITE_DONE) {
        v = 2;
    } else if (rc == ASB_SQLITE_ROW) {
        const unsigned char *b = (const unsigned char *)s->column_blob(st, 0);
        int n = s->column_bytes(st, 0);
        if (b && n == (int)sizeof(g_lspd_bool_prefix) + 1 &&
            memcmp(b, g_lspd_bool_prefix, sizeof(g_lspd_bool_prefix)) == 0 &&
            (b[n - 1] == 0 || b[n - 1] == 1))
            v = b[n - 1];
    }
    s->finalize(st);
    return v;
}

/* Reading LSPosed's file in place, and when that cannot work (V66 dev13).
 *
 * Two users on Android 17 (CPH2769, LSPosed in /data/adb/lspd) saw "unexpected_schema" for
 * both the verbose switch and the module inventory, while the tables are the ones this file
 * reads: the maintained fork (Vector) keeps modules(mid, module_pkg_name, enabled),
 * scope(mid, app_pkg_name, user_id) and configs(..., data) with Java-serialized values. What
 * it also does is run the database in WAL mode. A read-only connection to a WAL database needs
 * the -shm index next to it, and has to create one when the daemon has closed the file; where
 * the directory or its SELinux label does not let the module's domain create files, every
 * statement fails with SQLITE_CANTOPEN - and this code printed any failure that was not
 * BUSY/LOCKED as a foreign schema.
 *
 * So a statement is tried on the file first; if the file cannot be opened or read (CANTOPEN,
 * IOERR, READONLY, PERM), the database and its -wal are copied to a private directory under
 * ASB_LSPD_TMP and the copy is read - LSPosed's directory is never written by a read. BUSY and
 * LOCKED stay "read_failed": a copy taken during LSPosed's own write could be torn. The SQLite
 * code is printed (sqlite_rc=) so the next report names the cause instead of guessing it. */
static int g_lspd_sqlite_rc = 0;
static char g_lspd_copy_dir[256] = "";

static int asb_lspd_probe(asb_sqlite_t *s, sqlite3_h *db) {
    sqlite3_stmt_h *st = NULL;
    int rc = s->prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &st, NULL);
    if (rc != ASB_SQLITE_OK || !st) { if (st) s->finalize(st); return rc ? rc : 1; }
    rc = s->step(st);
    s->finalize(st);
    return rc == ASB_SQLITE_ROW ? 0 : rc;
}

static int asb_lspd_copy_file(const char *src, const char *dst) {
    FILE *in = fopen(src, "rb");
    if (!in) return 1;
    FILE *out = fopen(dst, "wb");
    if (!out) { fclose(in); return -1; }
    char buf[16384];
    size_t n;
    int ok = 1;
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0)
        if (fwrite(buf, 1, n, out) != n) { ok = 0; break; }
    if (ferror(in)) ok = 0;
    fclose(in);
    if (fclose(out) != 0) ok = 0;
    return ok ? 0 : -1;
}

static void asb_lspd_copy_drop(void) {
    if (!g_lspd_copy_dir[0]) return;
    static const char *const sfx[] = { "", "-wal", "-shm", "-journal" };
    char f[320];
    for (size_t i = 0; i < sizeof(sfx) / sizeof(sfx[0]); i++) {
        snprintf(f, sizeof(f), "%s/m.db%s", g_lspd_copy_dir, sfx[i]);
        unlink(f);
    }
    rmdir(g_lspd_copy_dir);
    g_lspd_copy_dir[0] = 0;
}

/* 0 with *db open for reading (the file itself, or a private copy of it), or the CLI's own
 * return code: 7 read_failed (busy, or neither the file nor a copy could be read), 6 a file
 * that opens but is no SQLite database LSPosed would write. */
static int asb_lspd_open_read(asb_sqlite_t *s, const char *path, sqlite3_h **db) {
    sqlite3_h *d = NULL;
    *db = NULL;
    g_lspd_sqlite_rc = 0;
    int rc = s->open_v2(path, &d, ASB_SQLITE_OPEN_READONLY, NULL);
    if (rc == ASB_SQLITE_OK && d) {
        s->busy_timeout(d, 3000);
        rc = asb_lspd_probe(s, d);
        if (rc == 0) { *db = d; return 0; }
    }
    if (d) s->close(d);
    d = NULL;
    g_lspd_sqlite_rc = rc;
    int p = rc & 0xff;
    if (p == 5 || p == 6) return 7;
    if (p != 3 && p != 8 && p != 10 && p != 14) return 6;
    snprintf(g_lspd_copy_dir, sizeof(g_lspd_copy_dir), "%s/lspd_ro.%d", ASB_LSPD_TMP, (int)getpid());
    mkdir(g_lspd_copy_dir, 0700);
    char dst[320], src[320];
    snprintf(dst, sizeof(dst), "%s/m.db", g_lspd_copy_dir);
    if (asb_lspd_copy_file(path, dst) != 0) { asb_lspd_copy_drop(); return 7; }
    snprintf(src, sizeof(src), "%s-wal", path);
    snprintf(dst, sizeof(dst), "%s/m.db-wal", g_lspd_copy_dir);
    if (asb_lspd_copy_file(src, dst) < 0) { asb_lspd_copy_drop(); return 7; }
    snprintf(dst, sizeof(dst), "%s/m.db", g_lspd_copy_dir);
    if (s->open_v2(dst, &d, ASB_SQLITE_OPEN_READWRITE, NULL) != ASB_SQLITE_OK || !d) {
        if (d) s->close(d);
        asb_lspd_copy_drop();
        return 7;
    }
    s->busy_timeout(d, 3000);
    if (asb_lspd_probe(s, d) != 0) { s->close(d); asb_lspd_copy_drop(); return 7; }
    *db = d;
    return 0;
}

static void asb_lspd_close_read(asb_sqlite_t *s, sqlite3_h *db) {
    if (db) s->close(db);
    asb_lspd_copy_drop();
}

static void asb_lspd_print_rc(void) {
    if (g_lspd_sqlite_rc) printf("sqlite_rc=%d\n", g_lspd_sqlite_rc);
    if (g_lspd_copy_dir[0]) puts("read_from=copy");
}

static const char *asb_lspd_name(int v) {
    return v == 1 ? "on" : v == 0 ? "off" : v == 2 ? "default_on" : "unknown";
}

/* fix277: the module and scope tables, read-only. ASB answers "which LSPosed modules hook
 * which apps" from LSPosed's own database instead of guessing from logs. Names that are not
 * plain package identifiers are skipped, so nothing the shell parses can carry a separator
 * or a command; the framework's own "lspd" row is not a module. Output is bounded. */
static int asb_lspd_name_ok(const unsigned char *t) {
    if (!t || !*t) return 0;
    size_t n = 0;
    for (const unsigned char *c = t; *c; c++, n++) {
        if (n >= 127) return 0;
        if (!((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') ||
              (*c >= '0' && *c <= '9') || *c == '.' || *c == '_')) return 0;
    }
    return 1;
}

static int asb_lspd_modules(asb_sqlite_t *s, sqlite3_h *db) {
    sqlite3_stmt_h *st = NULL;
    const char *qm = "SELECT m.module_pkg_name, m.enabled, "
                     "(SELECT COUNT(*) FROM scope sc WHERE sc.mid = m.mid) "
                     "FROM modules m ORDER BY m.module_pkg_name";
    int prc = s->prepare_v2(db, qm, -1, &st, NULL);
    if (prc != ASB_SQLITE_OK || !st) {
        if (st) s->finalize(st);
        /* SQLITE_BUSY / SQLITE_LOCKED: LSPosed holds a write lock; that is not a foreign layout. */
        puts((prc == 5 || prc == 6) ? "modules=unknown\nreason=read_failed" : "modules=unknown\nreason=unexpected_schema");
        return (prc == 5 || prc == 6) ? 7 : 6;
    }
    int n = 0, rc;
    puts("format=v1");
    while ((rc = s->step(st)) == ASB_SQLITE_ROW && n < 256) {
        const unsigned char *name = s->column_text(st, 0);
        if (!asb_lspd_name_ok(name) || strcmp((const char *)name, "lspd") == 0) continue;
        printf("module|%s|%d|%d\n", (const char *)name, s->column_int(st, 1) ? 1 : 0, s->column_int(st, 2));
        n++;
    }
    s->finalize(st);
    st = NULL;
    /* A busy or damaged database must not read as a short, complete inventory. */
    if (rc != ASB_SQLITE_DONE && rc != ASB_SQLITE_ROW) {
        puts("modules=unknown\nreason=read_failed");
        return 7;
    }
    const char *qs = "SELECT m.module_pkg_name, sc.app_pkg_name, sc.user_id "
                     "FROM scope sc JOIN modules m ON m.mid = sc.mid ORDER BY 1, 2";
    prc = s->prepare_v2(db, qs, -1, &st, NULL);
    if (prc != ASB_SQLITE_OK || !st) {
        if (st) s->finalize(st);
        puts((prc == 5 || prc == 6) ? "scope=unknown\nreason=read_failed" : "scope=unknown\nreason=unexpected_schema");
        return (prc == 5 || prc == 6) ? 7 : 6;
    }
    int k = 0;
    while ((rc = s->step(st)) == ASB_SQLITE_ROW && k < 4096) {
        const unsigned char *mod = s->column_text(st, 0);
        const unsigned char *app = s->column_text(st, 1);
        if (!asb_lspd_name_ok(mod) || !asb_lspd_name_ok(app) || strcmp((const char *)mod, "lspd") == 0) continue;
        printf("scope|%s|%s|%d\n", (const char *)mod, (const char *)app, s->column_int(st, 2));
        k++;
    }
    s->finalize(st);
    if (rc != ASB_SQLITE_DONE && rc != ASB_SQLITE_ROW) {
        puts("scope=unknown\nreason=read_failed");
        return 7;
    }
    printf("modules=%d\nscopes=%d\n", n, k);
    return 0;
}

/* V66: the lighter-LSPosed edits. Only on the owner's tap or the opted-in automatic pass
 * (runtime/asb_lsposed_lite.sh), each one journaled there so it can be put back exactly. The
 * rows are the ones LSPosed's own manager writes (modules.enabled, scope(mid, app_pkg_name,
 * user_id)); the daemon reads them when it starts, so an edit takes effect at the next boot.
 * Names are plain package identifiers (asb_lspd_name_ok) before they reach a statement, and
 * a database without these columns is left untouched. */
static int asb_lspd_int(asb_sqlite_t *s, sqlite3_h *db, const char *q, int *out) {
    sqlite3_stmt_h *st = NULL;
    if (s->prepare_v2(db, q, -1, &st, NULL) != ASB_SQLITE_OK || !st) {
        if (st) s->finalize(st);
        return -1;
    }
    int rc = s->step(st);
    if (rc == ASB_SQLITE_ROW) *out = s->column_int(st, 0);
    s->finalize(st);
    return rc == ASB_SQLITE_ROW ? 1 : (rc == ASB_SQLITE_DONE ? 0 : -1);
}
static int asb_lspd_schema_ok(asb_sqlite_t *s, sqlite3_h *db) {
    static const char *const q[] = {
        "SELECT mid, module_pkg_name, enabled FROM modules LIMIT 0",
        "SELECT mid, app_pkg_name, user_id FROM scope LIMIT 0"
    };
    for (size_t i = 0; i < sizeof(q) / sizeof(q[0]); i++) {
        sqlite3_stmt_h *st = NULL;
        int rc = s->prepare_v2(db, q[i], -1, &st, NULL);
        if (st) s->finalize(st);
        if (rc != ASB_SQLITE_OK) return 0;
    }
    return 1;
}
static int asb_lspd_edit(int argc, char **argv) {
    const char *cmd = argv[0];
    int is_mod = strcmp(cmd, "module-set") == 0;
    int need = is_mod ? 3 : 4;
    if (argc < need) return 2;
    const char *mod = argv[1];
    const char *app = is_mod ? NULL : argv[2];
    const char *num = is_mod ? argv[2] : argv[3];
    if (!asb_lspd_name_ok((const unsigned char *)mod) || strcmp(mod, "lspd") == 0 ||
        (app && !asb_lspd_name_ok((const unsigned char *)app))) {
        puts("result=bad_request");
        return 2;
    }
    int val = 0;
    for (const char *c = num; ; c++) {
        if (!*c) break;
        if (*c < '0' || *c > '9' || c - num > 5) { puts("result=bad_request"); return 2; }
        val = val * 10 + (*c - '0');
    }
    if (!*num || (is_mod && val > 1)) { puts("result=bad_request"); return 2; }
    const char *path = (argc > need) ? argv[need] : ASB_LSPD_DB;
    FILE *probe = fopen(path, "rb");
    if (!probe) { puts("result=unknown\nreason=no_database"); return 3; }
    fclose(probe);
    asb_sqlite_t s;
    memset(&s, 0, sizeof(s));
    if (asb_sqlite_load(&s) != 0) { puts("result=unknown\nreason=no_sqlite"); return 4; }
    sqlite3_h *db = NULL;
    if (s.open_v2(path, &db, ASB_SQLITE_OPEN_READWRITE, NULL) != ASB_SQLITE_OK || !db) {
        if (db) s.close(db);
        puts("result=unknown\nreason=open_failed");
        return 5;
    }
    s.busy_timeout(db, 3000);
    if (!asb_lspd_schema_ok(&s, db)) {
        s.close(db);
        puts("result=unknown\nreason=unexpected_schema");
        return 6;
    }
    char q[512];
    int mid = -1;
    snprintf(q, sizeof(q), "SELECT mid FROM modules WHERE module_pkg_name='%s'", mod);
    int found = asb_lspd_int(&s, db, q, &mid);
    if (found < 0) { s.close(db); puts("result=unknown\nreason=read_failed"); return 7; }
    if (found == 0) { s.close(db); puts("result=no_module"); return 0; }
    if (s.exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != ASB_SQLITE_OK) {
        s.close(db);
        puts("result=unknown\nreason=busy");
        return 7;
    }
    int before = -1, after = -1, rc = 0;
    const char *res = "ok";
    if (is_mod) {
        snprintf(q, sizeof(q), "SELECT enabled FROM modules WHERE mid=%d", mid);
        if (asb_lspd_int(&s, db, q, &before) != 1) rc = 7;
        if (!rc) {
            snprintf(q, sizeof(q), "UPDATE modules SET enabled=%d WHERE mid=%d", val, mid);
            if (s.exec(db, q, NULL, NULL, NULL) != ASB_SQLITE_OK) rc = 7;
        }
        if (!rc) {
            snprintf(q, sizeof(q), "SELECT enabled FROM modules WHERE mid=%d", mid);
            if (asb_lspd_int(&s, db, q, &after) != 1 || (after ? 1 : 0) != val) rc = 8;
        }
    } else {
        int add = strcmp(cmd, "scope-add") == 0;
        snprintf(q, sizeof(q), "SELECT COUNT(*) FROM scope WHERE mid=%d AND app_pkg_name='%s' AND user_id=%d", mid, app, val);
        if (asb_lspd_int(&s, db, q, &before) != 1) rc = 7;
        if (!rc && add && before == 0) {
            snprintf(q, sizeof(q), "INSERT INTO scope(mid, app_pkg_name, user_id) VALUES(%d, '%s', %d)", mid, app, val);
            if (s.exec(db, q, NULL, NULL, NULL) != ASB_SQLITE_OK) rc = 7;
        } else if (!rc && !add && before > 0) {
            snprintf(q, sizeof(q), "DELETE FROM scope WHERE mid=%d AND app_pkg_name='%s' AND user_id=%d", mid, app, val);
            if (s.exec(db, q, NULL, NULL, NULL) != ASB_SQLITE_OK) rc = 7;
        }
        if (!rc) {
            snprintf(q, sizeof(q), "SELECT COUNT(*) FROM scope WHERE mid=%d AND app_pkg_name='%s' AND user_id=%d", mid, app, val);
            if (asb_lspd_int(&s, db, q, &after) != 1 || (add ? after != 1 : after != 0)) rc = 8;
        }
        res = add ? (before > 0 ? "present" : "added") : (before > 0 ? "removed" : "absent");
    }
    if (rc) {
        s.exec(db, "ROLLBACK", NULL, NULL, NULL);
        s.close(db);
        puts(rc == 8 ? "result=unknown\nreason=not_written" : "result=unknown\nreason=write_failed");
        return rc;
    }
    if (s.exec(db, "COMMIT", NULL, NULL, NULL) != ASB_SQLITE_OK) {
        s.exec(db, "ROLLBACK", NULL, NULL, NULL);
        s.close(db);
        puts("result=unknown\nreason=write_failed");
        return 7;
    }
    s.close(db);
    printf("result=%s\nbefore=%d\nafter=%d\n", res, before ? 1 : 0, after ? 1 : 0);
    return 0;
}

static int asb_lspd_cli(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "usage: asb --lspd verbose-get|verbose-set on|off|verbose-unset|modules|scope-del|scope-add|module-set ... [db]\n");
        return 2;
    }
    const char *cmd = argv[0];
    if (strcmp(cmd, "scope-del") == 0 || strcmp(cmd, "scope-add") == 0 || strcmp(cmd, "module-set") == 0)
        return asb_lspd_edit(argc, argv);
    if (strcmp(cmd, "modules") == 0) {
        const char *mpath = (argc > 1) ? argv[1] : ASB_LSPD_DB;
        FILE *mp = fopen(mpath, "rb");
        if (!mp) { puts("modules=unknown\nreason=no_database"); return 3; }
        fclose(mp);
        asb_sqlite_t ms;
        memset(&ms, 0, sizeof(ms));
        if (asb_sqlite_load(&ms) != 0) { puts("modules=unknown\nreason=no_sqlite"); return 4; }
        sqlite3_h *mdb = NULL;
        int orc = asb_lspd_open_read(&ms, mpath, &mdb);
        if (orc != 0) {
            puts(orc == 6 ? "modules=unknown\nreason=unexpected_schema" : "modules=unknown\nreason=read_failed");
            asb_lspd_print_rc();
            return orc;
        }
        int mrc = asb_lspd_modules(&ms, mdb);
        asb_lspd_print_rc();
        asb_lspd_close_read(&ms, mdb);
        return mrc;
    }
    int set = -1, unset = 0;
    int ai = 1;
    if (strcmp(cmd, "verbose-set") == 0) {
        if (argc < 2) return 2;
        if (strcmp(argv[1], "on") == 0) set = 1;
        else if (strcmp(argv[1], "off") == 0) set = 0;
        else return 2;
        ai = 2;
    } else if (strcmp(cmd, "verbose-unset") == 0) {
        unset = 1;
    } else if (strcmp(cmd, "verbose-get") != 0) {
        return 2;
    }
    const char *path = (argc > ai) ? argv[ai] : ASB_LSPD_DB;
    FILE *probe = fopen(path, "rb");
    if (!probe) { puts("verbose=unknown\nreason=no_database"); return 3; }
    fclose(probe);
    asb_sqlite_t s;
    memset(&s, 0, sizeof(s));
    if (asb_sqlite_load(&s) != 0) { puts("verbose=unknown\nreason=no_sqlite"); return 4; }
    sqlite3_h *db = NULL;
    int writing = (set >= 0 || unset);
    if (writing) {
        if (s.open_v2(path, &db, ASB_SQLITE_OPEN_READWRITE, NULL) != ASB_SQLITE_OK || !db) {
            if (db) s.close(db);
            puts("verbose=unknown\nreason=open_failed");
            return 5;
        }
        s.busy_timeout(db, 3000);
    } else {
        int orc = asb_lspd_open_read(&s, path, &db);
        if (orc != 0) {
            puts(orc == 6 ? "verbose=unknown\nreason=unexpected_schema" : "verbose=unknown\nreason=read_failed");
            asb_lspd_print_rc();
            return orc;
        }
    }
    int before = asb_lspd_read(&s, db);
    if (before < 0) {
        /* Not the layout this was written against (another fork, a newer schema): touch
         * nothing. */
        asb_lspd_close_read(&s, db);
        puts("verbose=unknown\nreason=unexpected_schema");
        asb_lspd_print_rc();
        return 6;
    }
    int rc = 0;
    if (set >= 0 || unset) {
        char sql[512];
        if (unset) {
            snprintf(sql, sizeof(sql), "DELETE FROM configs WHERE module_pkg_name='lspd' AND user_id=0 "
                                       "AND `group`='config' AND `key`='enable_verbose_log'");
        } else {
            char hex[2 * sizeof(g_lspd_bool_prefix) + 3];
            size_t p = 0;
            for (size_t i = 0; i < sizeof(g_lspd_bool_prefix); i++)
                p += (size_t)snprintf(hex + p, sizeof(hex) - p, "%02X", g_lspd_bool_prefix[i]);
            snprintf(hex + p, sizeof(hex) - p, "%02X", set ? 1 : 0);
            snprintf(sql, sizeof(sql),
                     "INSERT OR REPLACE INTO configs(module_pkg_name,user_id,`group`,`key`,data) "
                     "VALUES('lspd',0,'config','enable_verbose_log',X'%s')", hex);
        }
        char *err = NULL;
        if (s.exec(db, sql, NULL, NULL, &err) != ASB_SQLITE_OK) {
            printf("verbose=%s\nreason=write_failed%s%s\n", asb_lspd_name(before), err ? ":" : "", err ? err : "");
            if (err) s.sfree(err);
            s.close(db);
            return 7;
        }
        int after = asb_lspd_read(&s, db);
        int want = unset ? 2 : set;
        if (after != want) rc = 8;
        printf("verbose=%s\nbefore=%s\nformat=%s\n", asb_lspd_name(after), asb_lspd_name(before), ASB_LSPD_FORMAT);
    } else {
        printf("verbose=%s\nformat=%s\n", asb_lspd_name(before), ASB_LSPD_FORMAT);
        asb_lspd_print_rc();
    }
    asb_lspd_close_read(&s, db);
    return rc;
}
