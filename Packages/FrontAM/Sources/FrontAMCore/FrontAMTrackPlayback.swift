import SwiftUI

public protocol FrontAMSpectrumSource: AnyObject {
    func subscribeSpectrum() -> AnyObject
}

@MainActor public protocol FrontAMTrackPlayback: AnyObject {
    var currentSongID: String? { get }
    var isPlaying: Bool { get }
    var isLoading: Bool { get }
    var playbackSourceTitle: String? { get }
    var playbackSpectrum: (any FrontAMSpectrumSource)? { get }
    func spectrumLevels() -> [Float]
}

extension EnvironmentValues {
    @Entry public var songRowPlayback: (any FrontAMTrackPlayback)?
    @Entry public var songPlaybackIndicatorsActive = true
}
