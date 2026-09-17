import Foundation

/// Meter history in chronological order without shifting samples each recording tick.
nonisolated struct VoiceRecordingWaveform: RandomAccessCollection {
    typealias Index = Int
    private var samples = [Float](repeating: 0, count: 240)
    private var oldest = 0
    private(set) var count = 0

    var startIndex: Int { 0 }
    var endIndex: Int { count }
    var capacity: Int { samples.count }

    subscript(position: Int) -> Float {
        precondition(position >= 0 && position < count)
        return samples[(oldest + position) % samples.count]
    }

    mutating func append(power: Float) {
        // Fixed perceptual amplitude scale keeps normal speech visible without
        // amplifying a quiet window to full height. Below -50 dB is the baseline.
        let amplitude = power.isFinite && power > -50 ? Swift.min(1, pow(10, power / 40)) : 0
        if count < samples.count {
            samples[(oldest + count) % samples.count] = amplitude
            count += 1
        } else {
            samples[oldest] = amplitude
            oldest = (oldest + 1) % samples.count
        }
    }
}
