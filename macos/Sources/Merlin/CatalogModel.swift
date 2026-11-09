import Foundation
import MerlinCore
import Observation
import SwiftUI

/// Where the catalog can navigate to.
enum CatalogRoute: Hashable {
  case page(id: String, title: String?)
  case taxon(id: String, title: String?)
  case collection(id: String)
  case content(id: String)
  case pack(id: String, title: String?)

  /// Pushes route, or goes back to it if it's already in the stack (an
  /// episode's "Open collection" when you came from that collection): a
  /// navigation path can't show the same value twice.
  static func open(_ route: CatalogRoute, in path: inout [CatalogRoute]) {
    if let i = path.firstIndex(where: { $0.matches(route) }) {
      path.removeSubrange((i + 1)...)
    } else {
      path.append(route)
    }
  }

  /// Same page (titles aside).
  func matches(_ other: CatalogRoute) -> Bool {
    switch (self, other) {
    case let (.page(a, _), .page(b, _)), let (.taxon(a, _), .taxon(b, _)), let (.pack(a, _), .pack(b, _)): return a == b
    case let (.collection(a), .collection(b)), let (.content(a), .content(b)): return a == b
    default: return false
    }
  }
}

/// One row of the catalog: an element wraps exactly one of collection /
/// content / pack / webradio; taxa lead to sub-pages or category listings.
struct CatalogItem: Identifiable, Hashable {
  enum Kind: String { case collection, content, pack, webradio, page, taxon }

  let kind: Kind
  let itemID: String
  let title: String
  let subtitle: String?
  let imageURL: URL?
  var episode = 0
  /// A collection's number of episodes (0: unknown).
  var episodeCount = 0
  /// An episode's audio size in bytes (0: unknown).
  var size: Int64 = 0
  var id: String { "\(kind.rawValue):\(itemID)" }
  var isContent: Bool { kind == .content }

  var route: CatalogRoute? {
    switch kind {
    case .page: return .page(id: itemID, title: title)
    case .taxon: return .taxon(id: itemID, title: title)
    case .collection: return .collection(id: itemID)
    case .content: return .content(id: itemID)
    case .pack: return .pack(id: itemID, title: title)
    case .webradio: return nil
    }
  }

  var symbol: String {
    switch kind {
    case .collection: return "books.vertical"
    case .content: return "headphones"
    case .pack: return "gift"
    case .webradio: return "radio"
    case .page, .taxon: return "square.grid.2x2"
    }
  }

  static func element(_ el: JSONObject) -> CatalogItem? {
    // Search results carry the episode with its collection: the episode is the hit.
    if let c = el.obj("content"), el.obj("collection") != nil { return content(c) }
    if let c = el.obj("collection"), let id = c.id("id") {
      let meta = [CatalogFormat.ages(c), CatalogFormat.episodes(c)].compactMap { $0 }.joined(separator: " · ")
      return CatalogItem(kind: .collection, itemID: id, title: c.text("title") ?? "Collection",
                         subtitle: meta.isEmpty ? nil : meta, imageURL: CatalogFormat.imageURL(c), episodeCount: c.int("nb_episode"))
    }
    if let c = el.obj("content") { return content(c) }
    if let p = el.obj("pack"), let id = p.id("id") {
      return CatalogItem(kind: .pack, itemID: id, title: p.text("title") ?? "Pack", subtitle: "Pack", imageURL: CatalogFormat.imageURL(p))
    }
    if let w = el.obj("webradio"), let id = w.id("id") {
      return CatalogItem(kind: .webradio, itemID: id, title: w.text("title") ?? "Webradio", subtitle: "Webradio", imageURL: CatalogFormat.imageURL(w))
    }
    return nil
  }

  static func content(_ c: JSONObject) -> CatalogItem? {
    guard let id = c.id("id") else { return nil }
    let ep = c.int("episode")
    return CatalogItem(kind: .content, itemID: id, title: (ep > 0 ? "\(ep). " : "") + (c.text("title") ?? "Episode"),
                       subtitle: CatalogFormat.duration(of: c), imageURL: CatalogFormat.imageURL(c), episode: ep,
                       size: CatalogImporter.size(c))
  }

  static func taxon(_ t: JSONObject) -> CatalogItem? {
    if let sub = t.text("subpageid") {
      return CatalogItem(kind: .page, itemID: sub, title: t.text("title") ?? "Category", subtitle: nil, imageURL: CatalogFormat.imageURL(t))
    }
    guard let id = t.id("id") else { return nil }
    return CatalogItem(kind: .taxon, itemID: id, title: t.text("title") ?? "Category", subtitle: nil, imageURL: CatalogFormat.imageURL(t))
  }
}

/// A titled group of catalog rows (one module of a store page).
struct CatalogSection: Identifiable {
  let id: Int
  let title: String
  let items: [CatalogItem]

  static func page(_ page: JSONObject) -> [CatalogSection] {
    page.objs("modules").enumerated().compactMap { i, mod in
      let raw = mod.objs("elements").isEmpty ? mod.objs("items") : mod.objs("elements")
      let isTaxa = (mod.str("format") ?? "").hasPrefix("taxon")
      let items = raw.compactMap { isTaxa ? CatalogItem.taxon($0) : CatalogItem.element($0) }
      guard !items.isEmpty else { return nil }
      return CatalogSection(id: i, title: mod.text("title") ?? mod.str("format") ?? "", items: unique(items))
    }
  }

  /// List selection needs unique ids; the API can repeat an item in a module.
  static func unique(_ items: [CatalogItem]) -> [CatalogItem] {
    var seen = Set<String>()
    return items.filter { seen.insert($0.id).inserted }
  }
}

// MARK: - Loading

/// Loads data off the main thread, keyed by `key`; `reload()` fetches again.
@MainActor @Observable
final class Loader<T> {
  var value: T?
  var error: String?
  var generation = 0

  func reload() { generation += 1 }
}

/// Shows a spinner, then the content, or the error with a retry button.
struct Loading<T, Content: View>: View {
  let key: AnyHashable
  let label: String
  let load: () throws -> T
  @ViewBuilder let content: (T, Loader<T>) -> Content

  @ViewState private var loader = Loader<T>()

  init(key: AnyHashable, _ label: String, load: @escaping () throws -> T, @ViewBuilder content: @escaping (T, Loader<T>) -> Content) {
    self.key = key
    self.label = label
    self.load = load
    self.content = content
  }

  var body: some View {
    Group {
      if let value = loader.value {
        content(value, loader)
      } else if let error = loader.error {
        ContentUnavailableView {
          Label("Couldn't load", systemImage: "exclamationmark.triangle")
        } description: {
          Text(error)
        } actions: {
          Button("Try Again") { loader.reload() }
        }
      } else {
        ProgressView(label).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: [key, AnyHashable(loader.generation)]) {
      let load = load
      let result = await Task.detached { Result { try load() } }.value
      switch result {
      case .success(let v):
        loader.value = v
        loader.error = nil
      case .failure(let e):
        if loader.value == nil { loader.error = e.userMessage }
      }
    }
  }
}

// MARK: - Rows

struct Artwork: View {
  let url: URL?
  let symbol: String
  var size: CGFloat = 36

  var body: some View {
    Group {
      if let url {
        AsyncImage(url: url) { phase in
          if let image = phase.image { image.resizable().scaledToFill() } else { placeholder }
        }
      } else {
        placeholder
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size / 6))
  }

  private var placeholder: some View {
    RoundedRectangle(cornerRadius: size / 6)
      .fill(.quaternary)
      .overlay(Image(systemName: symbol).font(.system(size: size * 0.42)).foregroundStyle(.secondary))
  }
}

struct CatalogRow: View {
  let item: CatalogItem
  @Environment(AppModel.self) private var app

  var body: some View {
    let state = app.downloadState(item)
    HStack(spacing: 10) {
      Artwork(url: item.imageURL, symbol: item.symbol)
        .overlay(alignment: .bottomTrailing) {
          if state == .downloaded {
            Image(systemName: "checkmark.circle.fill")
              .symbolRenderingMode(.palette)
              .foregroundStyle(.white, .green)
              .font(.system(size: 15))
              .offset(x: 4, y: 4)
          }
        }
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title).lineLimit(2)
        if let subtitle = item.subtitle {
          Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
      switch state {
      case .downloaded: DownloadedBadge()
      case .partial(let n): Badge(text: item.episodeCount > 0 ? "\(n)/\(item.episodeCount) downloaded" : "\(n) downloaded", color: .green)
      case .downloading: Badge(text: "Downloading", color: .blue)
      case .none: EmptyView()
      }
      if item.route != nil && item.kind != .content {
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 2)
    .help(state == .downloaded ? "Already in your library" : "")
  }
}

struct DownloadedBadge: View {
  var body: some View {
    Label("Downloaded", systemImage: "checkmark")
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color.green.opacity(0.18), in: Capsule())
      .foregroundStyle(.green)
  }
}

struct Badge: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(0.18), in: Capsule())
      .foregroundStyle(color)
  }
}
