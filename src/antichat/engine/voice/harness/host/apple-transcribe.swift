// Runs Apple's on-device SpeechTranscriber (the recogniser iOS 26+ uses for
// the system STT path) over WAV files on the Mac and prints one JSON line
// per file: every volatile and final result with the audio time it covers.
//
//   swift apple-transcribe.swift status en-US de-DE …
//   swift apple-transcribe.swift <locale> file.wav [file.wav …]
//
// Only locales whose assets are already installed are used; nothing is
// downloaded.
import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
func transcriber(_ locale: Locale) -> SpeechTranscriber {
  SpeechTranscriber(
    locale: locale,
    transcriptionOptions: [],
    reportingOptions: [.volatileResults],
    attributeOptions: [.audioTimeRange])
}

@available(macOS 26.0, *)
func status(_ identifiers: [String]) async {
  for identifier in identifiers {
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
      print("{\"locale\":\"\(identifier)\",\"status\":\"unsupported\"}")
      continue
    }
    let state = await AssetInventory.status(forModules: [transcriber(locale)])
    print("{\"locale\":\"\(locale.identifier(.bcp47))\",\"status\":\"\(state)\"}")
  }
}

@available(macOS 26.0, *)
func run(_ identifier: String, _ paths: [String]) async throws {
  guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
    FileHandle.standardError.write("unsupported locale \(identifier)\n".data(using: .utf8)!)
    exit(2)
  }
  guard await AssetInventory.status(forModules: [transcriber(locale)]) == .installed else {
    FileHandle.standardError.write("assets for \(identifier) are not installed\n".data(using: .utf8)!)
    exit(3)
  }
  for path in paths {
    let module = transcriber(locale)
    let analyzer = SpeechAnalyzer(modules: [module])
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let started = Date()
    let collector = Task { () -> [[String: Any]] in
      var events: [[String: Any]] = []
      for try await result in module.results {
        let text = String(result.text.characters)
        events.append([
          "final": result.isFinal,
          "text": text,
          "start": result.range.start.seconds,
          "end": result.range.end.seconds,
          "wallMs": Int(Date().timeIntervalSince(started) * 1000),
        ])
      }
      return events
    }
    if let last = try await analyzer.analyzeSequence(from: file) {
      try await analyzer.finalizeAndFinish(through: last)
    } else {
      await analyzer.cancelAndFinishNow()
    }
    let events = try await collector.value
    let text = events.filter { $0["final"] as? Bool == true }.map { $0["text"] as! String }.joined()
    let line: [String: Any] = [
      "file": (path as NSString).lastPathComponent,
      "locale": locale.identifier(.bcp47),
      "text": text.trimmingCharacters(in: .whitespacesAndNewlines),
      "events": events,
      "wallMs": Int(Date().timeIntervalSince(started) * 1000),
    ]
    let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
  }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard #available(macOS 26.0, *), let first = arguments.first else {
  FileHandle.standardError.write("needs macOS 26 and arguments\n".data(using: .utf8)!)
  exit(1)
}
if first == "status" {
  await status(Array(arguments.dropFirst()))
} else {
  try await run(first, Array(arguments.dropFirst()))
}
