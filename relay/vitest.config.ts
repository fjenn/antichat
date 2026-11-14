import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    testTimeout: 30_000,
    // Each file owns the process-wide relay context; files run in separate workers, tests inside a file in order.
    fileParallelism: true,
  },
});
