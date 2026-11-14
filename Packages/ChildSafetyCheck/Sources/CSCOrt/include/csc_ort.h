// Minimal ONNX Runtime C-API shim for ChildSafetyCheck (P-media-14, onnxruntime 1.24.2).
// Why C and not the Objective-C bindings: the published detector ONNX files have symbolic input
// dimensions (batch, height, width); the CoreML EP rejects unbounded dimensions, and only the C API
// exposes AddFreeDimensionOverrideByName to pin them to the fixed size we always feed. The model
// files themselves are used exactly as published (D-007): nothing is converted or rewritten.
#ifndef CSC_ORT_H
#define CSC_ORT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct csc_session csc_session;

/// Creates a session for `path`. `shape` (length `rank`) is the fixed input shape; every symbolic
/// input dimension is overridden with the matching entry. `use_coreml` != 0 appends the CoreML EP
/// (MLProgram, all compute units; `cache_dir` may be NULL). Returns NULL and fills `err` on failure.
csc_session *csc_session_create(const char *path, const int64_t *shape, size_t rank, int use_coreml,
                                const char *cache_dir, char *err, size_t err_len);

/// Runs the session on one float32 input of `n` elements; writes up to `out_cap` float32 outputs
/// (first output only) to `out` and the element count to `out_n`. Returns 0 on success.
int csc_session_run(csc_session *s, const float *input, size_t n, float *out, size_t out_cap, size_t *out_n,
                    char *err, size_t err_len);

void csc_session_free(csc_session *s);

#ifdef __cplusplus
}
#endif

#endif
