import AppKit
import AVFoundation
import MediaPlayer
import MerlinCore
import Observation

/// Plays library tracks: a queue (usually a folder from the chosen track
/// on), with the keyboard's media keys and Control Center wired in.
@MainActor @Observable
final class Player {
  private(set) var queue: [MediaLibrary.Track] = []
  private(set) var index = 0
  private(set) var isPlaying = false
  private(set) var time: Double = 0
  private(set) var duration: Double = 0
  /// The folder the queue came from (for the cover fallback and the label).
  private(set) var folder: MediaLibrary.Folder?

  @ObservationIgnored private let player = AVPlayer()
  @ObservationIgnored private var library: MediaLibrary?
  @ObservationIgnored private var timeObserver: Any?
  @ObservationIgnored private var endObserver: NSObjectProtocol?
  @ObservationIgnored private var artwork: NSImage?

  var current: MediaLibrary.Track? { queue.indices.contains(index) ? queue[index] : nil }
  var hasNext: Bool { index + 1 < queue.count }

  init() {
    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
      MainActor.assumeIsolated { self?.tick(t) }
    }
    endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
      MainActor.assumeIsolated {
        guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
        if self.hasNext { self.skip(by: 1) } else { self.finish() }
      }
    }
    setUpRemoteCommands()
  }

  /// Plays tracks[start], then the ones after it.
  func play(_ tracks: [MediaLibrary.Track], from start: Int = 0, folder: MediaLibrary.Folder?, library: MediaLibrary) {
    guard tracks.indices.contains(start) else { return }
    self.library = library
    self.folder = folder
    queue = tracks
    load(start, autoplay: true)
  }

  func toggle() {
    guard current != nil else { return }
    if isPlaying {
      player.pause()
      isPlaying = false
    } else {
      if duration > 0, time >= duration - 0.5 { player.seek(to: .zero) }
      player.play()
      isPlaying = true
    }
    updateNowPlaying()
  }

  func next() { if hasNext { skip(by: 1) } }

  /// Back to the start of the track, or the previous one if near the start.
  func previous() {
    if time > 3 || index == 0 {
      seek(to: 0)
    } else {
      skip(by: -1)
    }
  }

  func seek(to seconds: Double) {
    time = seconds
    player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    updateNowPlaying()
  }

  func stop() {
    player.pause()
    player.replaceCurrentItem(with: nil)
    queue = []
    index = 0
    isPlaying = false
    time = 0
    duration = 0
    folder = nil
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    MPNowPlayingInfoCenter.default().playbackState = .stopped
  }

  /// The library changed: drop tracks that were deleted (stops if the
  /// current one was).
  func libraryChanged(_ library: MediaLibrary?) {
    guard let current else { return }
    guard let library, library === self.library, library.track(current.id) != nil else { return stop() }
    let kept = queue.filter { library.track($0.id) != nil }
    if kept.count != queue.count {
      queue = kept
      index = kept.firstIndex { $0.id == current.id } ?? 0
    }
  }

  // MARK: Private

  private func skip(by delta: Int) {
    load(index + delta, autoplay: true)
  }

  private func load(_ i: Int, autoplay: Bool) {
    guard queue.indices.contains(i), let library else { return }
    index = i
    let track = queue[i]
    player.replaceCurrentItem(with: AVPlayerItem(url: library.url(track.audio)))
    time = 0
    duration = Double(track.duration ?? 0)
    artwork = (track.cover ?? folder?.cover).flatMap { NSImage(contentsOf: library.url($0)) }
    if autoplay {
      player.play()
      isPlaying = true
    }
    updateNowPlaying()
  }

  private func finish() {
    isPlaying = false
    player.pause()
    seek(to: 0)
  }

  private func tick(_ t: CMTime) {
    guard current != nil else { return }
    if t.isNumeric { time = t.seconds }
    if let d = player.currentItem?.duration, d.isNumeric, d.seconds > 0 { duration = d.seconds }
  }

  private func updateNowPlaying() {
    guard let track = current else { return }
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: track.title,
      MPMediaItemPropertyAlbumTitle: folder?.title ?? "",
      MPMediaItemPropertyPlaybackDuration: duration,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
      MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
    ]
    if let artist = track.artist { info[MPMediaItemPropertyArtist] = artist }
    if let image = artwork {
      info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
  }

  private func setUpRemoteCommands() {
    let c = MPRemoteCommandCenter.shared()
    func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (Player) -> Void) {
      command.isEnabled = true
      command.addTarget { [weak self] _ in
        guard let self else { return .noActionableNowPlayingItem }
        DispatchQueue.main.async { MainActor.assumeIsolated { action(self) } }
        return .success
      }
    }
    on(c.togglePlayPauseCommand) { $0.toggle() }
    on(c.playCommand) { if !$0.isPlaying { $0.toggle() } }
    on(c.pauseCommand) { if $0.isPlaying { $0.toggle() } }
    on(c.nextTrackCommand) { $0.next() }
    on(c.previousTrackCommand) { $0.previous() }
    c.changePlaybackPositionCommand.isEnabled = true
    c.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      let position = e.positionTime
      DispatchQueue.main.async { MainActor.assumeIsolated { self.seek(to: position) } }
      return .success
    }
  }
}
