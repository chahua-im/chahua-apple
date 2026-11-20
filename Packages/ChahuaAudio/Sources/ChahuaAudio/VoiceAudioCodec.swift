import AVFoundation
import Foundation
import SwiftOGG

/// Ogg/Opus is Chahua's published format. Upload native AAC recordings so the
/// backend performs canonical encoding; decode received Opus as Flutter does.
public enum VoiceAudioCodec {
    public static func decode(input: URL, output: URL) throws {
        try OGGConverter.convertOpusOGGToM4aFile(src: input, dest: output)
    }

    public static func isOgg(_ url: URL) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try file.read(upToCount: 4) == Data("OggS".utf8)
    }

    /// Reads bounded PCM chunks rather than retaining a second full decoded clip.
    public static func waveform(input: URL, count: Int = 35) throws -> (
        duration: TimeInterval, samples: [Float]
    ) {
        let file = try AVAudioFile(
            forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
        let length = file.length
        let duration = Double(length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
        guard count > 0 else { return (duration, []) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)
        else { throw CocoaError(.fileReadUnknown) }
        var peaks = [Float](repeating: 0, count: count)
        while file.framePosition < length {
            try Task.checkCancellation()
            let start = file.framePosition
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for frame in 0..<Int(buffer.frameLength) {
                let bar = min(count - 1, Int((start + Int64(frame)) * Int64(count) / length))
                for channel in 0..<Int(buffer.format.channelCount) {
                    let value = abs(channels[channel][frame])
                    if value.isFinite { peaks[bar] = max(peaks[bar], value) }
                }
            }
        }
        let maximum = peaks.max() ?? 0
        return (duration, maximum > 0 ? peaks.map { $0 / maximum } : peaks)
    }
}
