"""AntiChat video runtime (M0.T07, D-013; M5.T02): Wan2.2-TI2V-5B T2V on FastMetal's MLX runtime, torch-free.

Modules: server (the unix-socket job server, the only entry point), wan22_generator / ltx_generator (in-memory
generators), umt5 (MLX text encoder), numerics (NumPy schedule + RoPE), frames / preview (in-memory frames and
previews), protocol, selftest. The M0.T07 file-writing CLI driver (generate_wan22) was removed in M5.T14: nothing in
the runtime writes a frame or a video file.
"""
