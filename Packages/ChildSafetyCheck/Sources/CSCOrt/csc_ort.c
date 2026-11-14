// See include/csc_ort.h.
#include "csc_ort.h"

#include <onnxruntime/onnxruntime_c_api.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct csc_session {
    OrtSession *session;
    char *input_name;
    char *output_name;
    int64_t shape[8];
    size_t rank;
};

static const OrtApi *g_api;
static OrtEnv *g_env;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static void init_env(void) {
    g_api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (g_api && g_api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "ChildSafetyCheck", &g_env) != NULL) g_env = NULL;
}

/// Consumes `st`; returns 1 if it was an error (and copies its message into err).
static int failed(OrtStatus *st, char *err, size_t err_len) {
    if (st == NULL) return 0;
    if (err && err_len) snprintf(err, err_len, "%s", g_api->GetErrorMessage(st));
    g_api->ReleaseStatus(st);
    return 1;
}

#define TRY(expr) do { if (failed((expr), err, err_len)) goto fail; } while (0)

static OrtSessionOptions *make_options(char *err, size_t err_len) {
    OrtSessionOptions *o = NULL;
    TRY(g_api->CreateSessionOptions(&o));
    // Basic level: the extended fusions crash on the fp16 Freepik export (SimplifiedLayerNormFusion).
    TRY(g_api->SetSessionGraphOptimizationLevel(o, ORT_ENABLE_BASIC));
    // The check loads only around Photo/Video outputs on machines where the image model already uses
    // most of the tier budget (K-019): no growing CPU arena, no per-shape memory-pattern caches.
    TRY(g_api->DisableCpuMemArena(o));
    TRY(g_api->DisableMemPattern(o));
    return o;
fail:
    if (o) g_api->ReleaseSessionOptions(o);
    return NULL;
}

csc_session *csc_session_create(const char *path, const int64_t *shape, size_t rank, int use_coreml,
                                const char *cache_dir, char *err, size_t err_len) {
    pthread_once(&g_once, init_env);
    if (!g_api || !g_env) {
        snprintf(err, err_len, "onnxruntime environment unavailable");
        return NULL;
    }
    if (rank == 0 || rank > 8) {
        snprintf(err, err_len, "bad rank");
        return NULL;
    }
    csc_session *s = calloc(1, sizeof *s);
    OrtSessionOptions *probe_opts = NULL, *opts = NULL;
    OrtSession *probe = NULL;
    OrtTypeInfo *ti = NULL;
    OrtAllocator *alloc = NULL;
    char *name = NULL;
    const char **sym = NULL;
    if (!s) return NULL;
    memcpy(s->shape, shape, rank * sizeof *shape);
    s->rank = rank;

    // 1. Probe (CPU, no optimisation) to read the input/output names and symbolic input dimensions.
    if (!(probe_opts = make_options(err, err_len))) goto fail;
    TRY(g_api->SetSessionGraphOptimizationLevel(probe_opts, ORT_DISABLE_ALL));
    TRY(g_api->CreateSession(g_env, path, probe_opts, &probe));
    TRY(g_api->GetAllocatorWithDefaultOptions(&alloc));
    TRY(g_api->SessionGetInputName(probe, 0, alloc, &name));
    s->input_name = strdup(name);
    TRY(g_api->AllocatorFree(alloc, name));
    name = NULL;
    TRY(g_api->SessionGetOutputName(probe, 0, alloc, &name));
    s->output_name = strdup(name);
    TRY(g_api->AllocatorFree(alloc, name));
    name = NULL;
    TRY(g_api->SessionGetInputTypeInfo(probe, 0, &ti));
    const OrtTensorTypeAndShapeInfo *tsi = NULL;
    TRY(g_api->CastTypeInfoToTensorInfo(ti, &tsi));
    size_t dims = 0;
    TRY(g_api->GetDimensionsCount(tsi, &dims));
    if (dims != rank) {
        snprintf(err, err_len, "model input rank %zu != %zu", dims, rank);
        goto fail;
    }
    sym = calloc(dims, sizeof *sym);
    TRY(g_api->GetSymbolicDimensions(tsi, sym, dims));

    // 2. Real session: pin every symbolic dimension, then add the EP.
    if (!(opts = make_options(err, err_len))) goto fail;
    for (size_t i = 0; i < dims; i++) {
        if (sym[i] && sym[i][0]) TRY(g_api->AddFreeDimensionOverrideByName(opts, sym[i], shape[i]));
    }
    if (use_coreml) {
        const char *keys[4] = {"ModelFormat", "MLComputeUnits", "RequireStaticInputShapes", "ModelCacheDirectory"};
        // CSC_COREML_COMPUTE_UNITS (ALL | CPUAndGPU | CPUAndNeuralEngine | CPUOnly): csc-bench experiments only.
        const char *units = getenv("CSC_COREML_COMPUTE_UNITS");
        const char *vals[4] = {"MLProgram", units && units[0] ? units : "ALL", "1", cache_dir};
        TRY(g_api->SessionOptionsAppendExecutionProvider(opts, "CoreML", keys, vals, cache_dir ? 4 : 3));
    }
    TRY(g_api->CreateSession(g_env, path, opts, &s->session));

    free(sym);
    g_api->ReleaseTypeInfo(ti);
    g_api->ReleaseSession(probe);
    g_api->ReleaseSessionOptions(probe_opts);
    g_api->ReleaseSessionOptions(opts);
    return s;
fail:
    free(sym);
    if (ti) g_api->ReleaseTypeInfo(ti);
    if (probe) g_api->ReleaseSession(probe);
    if (probe_opts) g_api->ReleaseSessionOptions(probe_opts);
    if (opts) g_api->ReleaseSessionOptions(opts);
    csc_session_free(s);
    return NULL;
}

int csc_session_run(csc_session *s, const float *input, size_t n, float *out, size_t out_cap, size_t *out_n,
                    char *err, size_t err_len) {
    OrtMemoryInfo *mi = NULL;
    OrtValue *in = NULL, *res = NULL;
    OrtTensorTypeAndShapeInfo *info = NULL;
    int rc = 1;
    size_t expected = 1;
    for (size_t i = 0; i < s->rank; i++) expected *= (size_t)s->shape[i];
    if (n != expected) {
        snprintf(err, err_len, "input has %zu elements, expected %zu", n, expected);
        return 1;
    }
    TRY(g_api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &mi));
    TRY(g_api->CreateTensorWithDataAsOrtValue(mi, (void *)input, n * sizeof(float), s->shape, s->rank,
                                              ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &in));
    const char *in_names[1] = {s->input_name};
    const char *out_names[1] = {s->output_name};
    TRY(g_api->Run(s->session, NULL, in_names, (const OrtValue *const *)&in, 1, out_names, 1, &res));
    TRY(g_api->GetTensorTypeAndShape(res, &info));
    size_t count = 0;
    TRY(g_api->GetTensorShapeElementCount(info, &count));
    ONNXTensorElementDataType et;
    TRY(g_api->GetTensorElementType(info, &et));
    if (et != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
        snprintf(err, err_len, "output is not float32");
        goto fail;
    }
    float *data = NULL;
    TRY(g_api->GetTensorMutableData(res, (void **)&data));
    *out_n = count;
    memcpy(out, data, (count < out_cap ? count : out_cap) * sizeof(float));
    rc = 0;
fail:
    if (info) g_api->ReleaseTensorTypeAndShapeInfo(info);
    if (res) g_api->ReleaseValue(res);
    if (in) g_api->ReleaseValue(in);
    if (mi) g_api->ReleaseMemoryInfo(mi);
    return rc;
}

void csc_session_free(csc_session *s) {
    if (!s) return;
    if (s->session) g_api->ReleaseSession(s->session);
    free(s->input_name);
    free(s->output_name);
    free(s);
}
