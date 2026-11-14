// M3.T12 (AT-280 AC1 ambient check, AC3 ducking): the default input's level, RMS per 100 ms, for N seconds.
//   swift tools/voice/level-probe.swift <seconds> [out.json]   → prints the median dBFS; the JSON has every value.
// A plain AVAudioEngine input tap (no voice processing), so it hears the room as it is.
@preconcurrency import AVFoundation
import Foundation

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "10") ?? 10
let out = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
let engine = AVAudioEngine()
let input = engine.inputNode
let format = input.outputFormat(forBus: 0)
final class Box: @unchecked Sendable { var values: [Double] = []; var acc: [Float] = []; let lock = NSLock() }
let box = Box()
let window = Int(format.sampleRate / 10)
input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
    guard let ch = buffer.floatChannelData?[0] else { return }
    let n = Int(buffer.frameLength)
    box.lock.lock(); defer { box.lock.unlock() }
    box.acc.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
    while box.acc.count >= window {
        let w = box.acc.prefix(window)
        let rms = sqrt(w.reduce(0) { $0 + Double($1) * Double($1) } / Double(window))
        box.values.append(20 * log10(max(rms, 1e-9)))
        box.acc.removeFirst(window)
    }
}
do { try engine.start() } catch { print("level-probe: cannot start the input: \(error)"); exit(1) }
Thread.sleep(forTimeInterval: seconds)
engine.stop()
let values = box.lock.withLock { box.values }
let sorted = values.sorted()
let median = sorted.isEmpty ? -120 : sorted[sorted.count / 2]
print(String(format: "%.1f", median))
if let out {
    let o: [String: Any] = ["seconds": seconds, "median_dbfs": median, "values_dbfs": values,
                            "device_sample_rate": format.sampleRate, "date": ISO8601DateFormatter().string(from: Date())]
    try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
}
