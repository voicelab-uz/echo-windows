import AVFoundation

/// Converts native device PCM to the meter/WAV format on the capture queue.
/// Keep one converter per input format so resampling state survives buffer boundaries.
final class MicrophonePCMConverter {
    static let sampleRate: Double = 16_000
    private let destination = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?

    func convert(_ sample: CMSampleBuffer) throws -> [Float] {
        let frames = CMSampleBufferGetNumSamples(sample)
        guard CMSampleBufferDataIsReady(sample), frames > 0, frames <= 192_000,
            let description = CMSampleBufferGetFormatDescription(sample),
            let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else { throw MicrophoneCaptureError.unsupportedFormat }
        var asbd = stream.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM,
            asbd.mSampleRate.isFinite, (8_000...192_000).contains(asbd.mSampleRate),
            (1...32).contains(asbd.mChannelsPerFrame),
            let format = AVAudioFormat(streamDescription: &asbd),
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { throw MicrophoneCaptureError.unsupportedFormat }
        input.frameLength = AVAudioFrameCount(frames)
        guard
            CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList
            ) == noErr
        else { throw MicrophoneCaptureError.unsupportedFormat }

        if converter?.inputFormat != format {
            guard let converter = AVAudioConverter(from: format, to: destination) else {
                throw MicrophoneCaptureError.unsupportedFormat
            }
            converter.primeMethod = .none
            converter.downmix = format.channelCount > 1
            self.converter = converter
        }
        guard let converter,
            let output = AVAudioPCMBuffer(
                pcmFormat: destination,
                frameCapacity: AVAudioFrameCount(ceil(Double(frames) * Self.sampleRate / format.sampleRate))
                    + 64)
        else { throw MicrophoneCaptureError.unsupportedFormat }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            guard !supplied else {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil,
            let samples = output.floatChannelData?[0]
        else { throw MicrophoneCaptureError.unsupportedFormat }
        return Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
    }
}
