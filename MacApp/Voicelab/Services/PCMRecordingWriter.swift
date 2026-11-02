import AVFoundation

/// Streams mono 16 kHz Float32 capture into the API's 16-bit PCM WAV format.
/// Owned exclusively by MicrophoneCapture's serial queue; releasing closes the file.
final class PCMRecordingWriter {
    private let file: AVAudioFile

    init(url: URL) throws {
        file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func write(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        guard
            let pcm = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = pcm.floatChannelData?[0]
        else { throw MicrophoneCaptureError.unsupportedFormat }
        pcm.frameLength = pcm.frameCapacity
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        try file.write(from: pcm)
    }
}
