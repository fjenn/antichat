// video-runtime-launcher (M5.T01 step 4; P-media-11). Design port of
// Blaizzy/nativ@72f4b9192ffc258f10a543d774e44d8db1a81ebb PythonDistribution/Launcher/mlx_vlm_server_launcher.c (MIT):
// find the runtime root from our own path, set a clean environment, exec the bundled CPython on our module.
// AntiChat differences: no PYTHONPATH/PYTHONHOME games (the interpreter runs isolated, `-I`, and finds its home and
// site-packages next to itself; our package and the vendored FastVideo files live in that site-packages); bytecode
// writes off (`-B`: the signed tree is never written); proxies and Hugging Face tokens are removed and the hub is
// forced offline (models come from local CAS directories only, R-241 network rule); argv is passed through.
//   video-runtime-launcher [server args…]   → python3.12 -I -B -m antichat_video.server [args…]
//   video-runtime-launcher --selftest       → python3.12 -I -B -m antichat_video.selftest
//   video-runtime-launcher --pytest PATHS…  → python3.12 -I -B -m antichat_video.devtest PATHS… (compiled only with
//                                              -DANTICHAT_VIDEO_DEVTEST: the local dev tree, never the shipped zip;
//                                              needs ANTICHAT_VIDEO_TEST_SITE, a pytest install outside the runtime)
// Build: clang -O2 -arch arm64 -mmacosx-version-min=26.0 -o bin/video-runtime-launcher video_runtime_launcher.c
#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

static const char *const kDropExact[] = {
    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
    "PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "PYTHONUSERBASE", "PYTHONEXECUTABLE", "PYTHONINSPECT",
    "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", NULL,
};
static const char *const kDropPrefix[] = {"HF_", "HUGGING_FACE_", "HUGGINGFACE_", NULL};

static int dropped(const char *entry) {
    const char *eq = strchr(entry, '=');
    size_t n = eq ? (size_t)(eq - entry) : strlen(entry);
    for (int i = 0; kDropExact[i]; i++)
        if (strlen(kDropExact[i]) == n && strncmp(entry, kDropExact[i], n) == 0) return 1;
    for (int i = 0; kDropPrefix[i]; i++)
        if (strncmp(entry, kDropPrefix[i], strlen(kDropPrefix[i])) == 0) return 1;
    return 0;
}

int main(int argc, char **argv) {
    char raw[PATH_MAX], self[PATH_MAX], root[PATH_MAX], python[PATH_MAX];
    uint32_t size = sizeof(raw);
    if (_NSGetExecutablePath(raw, &size) != 0 || realpath(raw, self) == NULL) {
        fprintf(stderr, "video-runtime-launcher: cannot resolve own path\n");
        return 70;
    }
    // <root>/bin/video-runtime-launcher → <root>
    char tmp[PATH_MAX];
    strlcpy(tmp, self, sizeof(tmp));
    strlcpy(root, dirname(dirname(tmp)), sizeof(root));
    snprintf(python, sizeof(python), "%s/bin/python3.12", root);

    // Clean environment: everything except the dropped names, plus our fixed values.
    int envc = 0;
    while (environ[envc]) envc++;
    char **env = calloc((size_t)envc + 8, sizeof(char *));
    if (!env) return 71;
    int k = 0;
    for (int i = 0; i < envc; i++) {
        const char *e = environ[i];
        if (dropped(e) || strncmp(e, "PYTHONNOUSERSITE=", 17) == 0 || strncmp(e, "PYTHONDONTWRITEBYTECODE=", 24) == 0 ||
            strncmp(e, "TRANSFORMERS_OFFLINE=", 21) == 0)
            continue;
        env[k++] = (char *)e;
    }
    env[k++] = "HF_HUB_OFFLINE=1";
    env[k++] = "TRANSFORMERS_OFFLINE=1";
    env[k++] = "PYTHONNOUSERSITE=1";
    env[k++] = "PYTHONDONTWRITEBYTECODE=1";
    env[k] = NULL;

    const char *module = "antichat_video.server";
    int first = 1;
    if (argc > 1 && strcmp(argv[1], "--selftest") == 0) {
        module = "antichat_video.selftest";
        first = 2;
    } else if (argc > 1 && strcmp(argv[1], "--pytest") == 0) {
#ifdef ANTICHAT_VIDEO_DEVTEST
        module = "antichat_video.devtest";
        first = 2;
#else
        fprintf(stderr, "video-runtime-launcher: --pytest is not available in this build\n");
        return 64;
#endif
    }
    char **args = calloc((size_t)argc + 6, sizeof(char *));
    if (!args) return 71;
    int a = 0;
    args[a++] = python;
    args[a++] = "-I";
    args[a++] = "-B";
    args[a++] = "-m";
    args[a++] = (char *)module;
    for (int i = first; i < argc; i++) args[a++] = argv[i];
    args[a] = NULL;
    execve(python, args, env);
    fprintf(stderr, "video-runtime-launcher: exec %s: %s\n", python, strerror(errno));
    return 72;
}
