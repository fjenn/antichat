// File tools interpreter launcher (M6.T15 / M6.T17 / M6.T18; P-files-tools-09 fallback "build the launcher against
// Python.framework (Py_BytesMain)"). Python-Apple-support's bin/python3.13 is the python.org framework stub,
// which posix_spawns Resources/Python.app/Contents/MacOS/Python (a second process and an .app bundle inside the
// runtime). This single-process launcher replaces both: it links @rpath/Python.framework (LC_RPATH
// @executable_path/.. = the runtime root) and hands argv to the interpreter. Built by build.sh with the SDK's
// clang; signed by tools/release/sign-runtime.sh with Runtimes/filetools-runtime/entitlements/python.entitlements.
//
// Process limits (M6.T18 step 1; P-files-tools-09 "RLIMITs"): before the interpreter starts — so before any
// Python, ours or the user's — soft AND hard limits are set from ANTICHAT_LIMITS ("cpu=600,fsize=104857600,
// nofile=256,core=0,as=2147483648"; the FileTools XPC passes it) or, when it is absent, from the same strict
// defaults. A limit can only be lowered (the hard limit is irreversible for this process and everything it
// forks). Failure to set one (other than RLIMIT_AS, which macOS does not enforce for mmap and may refuse) aborts
// with exit 71 instead of running unlimited. The variable is removed before Python sees the environment.
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>

extern int Py_BytesMain(int argc, char **argv);

struct limit { const char *key; int resource; rlim_t value; int required; };

static struct limit LIMITS[] = {
    {"cpu", RLIMIT_CPU, 600, 1},                 // lifetime CPU seconds; repl.py lowers the soft limit per run (60 s)
    {"fsize", RLIMIT_FSIZE, 100u * 1024 * 1024, 1},  // 100 MB per file (EFBIG; CPython ignores SIGXFSZ)
    {"nofile", RLIMIT_NOFILE, 256, 1},
    {"core", RLIMIT_CORE, 0, 1},
    {"as", RLIMIT_AS, 2048ull * 1024 * 1024, 0},   // set, not relied upon (the watchdog measures the footprint)
};
#define NLIMITS (sizeof(LIMITS) / sizeof(LIMITS[0]))

static void parse(const char *spec) {
    char buf[512];
    if (!spec || strlen(spec) >= sizeof(buf)) return;
    strcpy(buf, spec);
    for (char *tok = strtok(buf, ",:"); tok; tok = strtok(NULL, ",:")) {
        char *eq = strchr(tok, '=');
        if (!eq) continue;
        *eq = 0;
        char *end = NULL;
        unsigned long long v = strtoull(eq + 1, &end, 10);
        if (!end || *end) continue;
        for (size_t i = 0; i < NLIMITS; i++)
            if (strcmp(tok, LIMITS[i].key) == 0) LIMITS[i].value = (rlim_t)v;
    }
}

int main(int argc, char **argv) {
    parse(getenv("ANTICHAT_LIMITS"));
    unsetenv("ANTICHAT_LIMITS");
    for (size_t i = 0; i < NLIMITS; i++) {
        struct rlimit cur;
        if (getrlimit(LIMITS[i].resource, &cur) != 0) cur.rlim_max = RLIM_INFINITY;
        rlim_t v = LIMITS[i].value;
        if (cur.rlim_max != RLIM_INFINITY && cur.rlim_max < v) v = cur.rlim_max;
        struct rlimit want = {v, v};
        if (setrlimit(LIMITS[i].resource, &want) != 0 && LIMITS[i].required) {
            fprintf(stderr, "ft-python: setrlimit(%s=%llu) failed: %s\n", LIMITS[i].key, (unsigned long long)v, strerror(errno));
            return 71;
        }
    }
    return Py_BytesMain(argc, argv);
}
