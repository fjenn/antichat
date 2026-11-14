// M10.T09: DEBUG `-DownloadHost <url>` rewrites Hugging Face sources (the clean-VM suite's local mirror); nothing else.
@testable import AntiChatPlatform
import Foundation
import Testing

struct DownloadHostTests {
    let hf = URL(string: "https://huggingface.co/mlx-community/Qwen3.5-2B-MLX-4bit/resolve/93760be/config.json")!

    @Test func hfSourceKeepsItsPathOnTheMirror() {
        #expect(DownloadRequest.rewritten(hf, host: "http://127.0.0.1:8770").absoluteString
            == "http://127.0.0.1:8770/mlx-community/Qwen3.5-2B-MLX-4bit/resolve/93760be/config.json")
        #expect(DownloadRequest.rewritten(hf, host: "http://127.0.0.1:8770/").absoluteString
            == "http://127.0.0.1:8770/mlx-community/Qwen3.5-2B-MLX-4bit/resolve/93760be/config.json")
    }

    @Test func noHostOrOtherHostsAreUntouched() {
        #expect(DownloadRequest.rewritten(hf, host: nil) == hf)
        let gh = URL(string: "https://github.com/x/y/releases/download/v1/a.zip")!
        #expect(DownloadRequest.rewritten(gh, host: "http://127.0.0.1:8770") == gh)
    }
}
