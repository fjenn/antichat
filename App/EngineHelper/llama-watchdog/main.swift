// llama-watchdog (M1.T12 step 4): `Contents/Helpers/llama-watchdog --llama-watchdog <pgid>`, stdin = the read
// end of a pipe whose write end only the engine helper holds. On POLLHUP (helper gone, even after SIGKILL) it
// sends SIGTERM to the process group, then SIGKILL after 3 s. Logic: LlamaWatchdog.swift (compiled into this
// tool on its own; ported from johnbean393/Sidekick@83b3e6e, MIT).
import Foundation

LlamaWatchdog.runIfRequested()
FileHandle.standardError.write(Data("usage: llama-watchdog \(LlamaWatchdog.flag) <pgid> [<leader start µs>]  (stdin: parent pipe)\n".utf8))
exit(64)
