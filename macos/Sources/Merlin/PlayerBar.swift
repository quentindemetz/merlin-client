import MerlinCore
import SwiftUI

/// What's playing, at the bottom of the window.
struct PlayerBar: View {
  @Environment(AppModel.self) private var app
  @ViewState private var scrubbing: Double?

  var body: some View {
    let player = app.player
    if let track = player.current, let library = app.library {
      HStack(spacing: 12) {
        LocalCover(url: (track.cover ?? player.folder?.cover).map(library.url), symbol: "music.note", size: 40,
                   version: app.libraryVersion)
        VStack(alignment: .leading, spacing: 2) {
          Text(track.title).lineLimit(1).font(.callout.weight(.medium))
          Text([track.artist, player.folder?.title].compactMap { $0 }.joined(separator: " — "))
            .lineLimit(1).font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 220, alignment: .leading)

        HStack(spacing: 14) {
          Button { player.previous() } label: { Image(systemName: "backward.fill") }
            .help("Previous (⌘←)")
          Button { player.toggle() } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2).frame(width: 24)
          }
          .help(player.isPlaying ? "Pause" : "Play")
          Button { player.next() } label: { Image(systemName: "forward.fill") }
            .disabled(!player.hasNext)
            .help("Next (⌘→)")
        }
        .buttonStyle(.borderless)

        Text(Self.clock(scrubbing ?? player.time)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
          .frame(width: 52, alignment: .trailing)
        Slider(value: Binding(get: { scrubbing ?? player.time }, set: { scrubbing = $0 }),
               in: 0...max(player.duration, 1)) { editing in
          if !editing, let t = scrubbing {
            player.seek(to: t)
            scrubbing = nil
          }
        }
        .controlSize(.small)
        .disabled(player.duration <= 0)
        Text("-" + Self.clock(max(0, player.duration - (scrubbing ?? player.time))))
          .font(.caption).monospacedDigit().foregroundStyle(.secondary)
          .frame(width: 58, alignment: .leading)

        Text("\(player.index + 1)/\(player.queue.count)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
        Button { player.stop() } label: { Image(systemName: "xmark") }
          .buttonStyle(.borderless)
          .help("Stop")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.bar)
      .overlay(alignment: .top) { Divider() }
    }
  }

  static func clock(_ seconds: Double) -> String {
    let s = Int(seconds.rounded(.down))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
  }
}
