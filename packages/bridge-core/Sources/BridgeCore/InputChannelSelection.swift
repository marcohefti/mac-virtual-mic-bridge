import Foundation

/// A single physical input, numbered from 1 in configuration and the UI.
public struct InputChannelSelection {
    public let sourceChannels: Int
    public let channelIndex: Int

    public init(channel: Int, sourceChannels: Int) throws {
        guard channel >= 1, channel <= sourceChannels else {
            throw CoreAudioError.invalidState("Input channel \(channel) is unavailable; device has \(sourceChannels) inputs")
        }
        self.sourceChannels = sourceChannels
        channelIndex = channel - 1
    }

    /// Copies one input at unity gain, duplicating it only when the target is stereo.
    public func copy(from input: UnsafePointer<Float>, to output: UnsafeMutablePointer<Float>,
                     frameCount: Int, targetChannels: Int) {
        for frame in 0..<frameCount {
            let base = frame * sourceChannels
            let sample = input[base + channelIndex]
            for channel in 0..<targetChannels {
                output[frame * targetChannels + channel] = sample
            }
        }
    }
}
