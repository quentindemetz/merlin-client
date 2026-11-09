import MerlinCore
import SwiftUI

/// Opens a catalog route in whichever navigation stack the view lives in.
struct OpenRouteKey: EnvironmentKey {
  static let defaultValue: (CatalogRoute) -> Void = { _ in }
}

extension EnvironmentValues {
  var openRoute: (CatalogRoute) -> Void {
    get { self[OpenRouteKey.self] }
    set { self[OpenRouteKey.self] = newValue }
  }
}

func destination(_ route: CatalogRoute) -> some View {
  Group {
    switch route {
    case .page(let id, let title): PageView(id: id, title: title)
    case .taxon(let id, let title): TaxonView(id: id, title: title)
    case .collection(let id): CollectionView(id: id)
    case .content(let id): ContentDetailView(id: id)
    case .pack(let id, let title): PackView(id: id, title: title)
    }
  }
}

// MARK: - Browse

struct CatalogBrowser: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    @Bindable var app = app
    NavigationStack(path: $app.catalogPath) {
      Loading(key: app.settingID, "Loading the catalog…", load: { [backend = app.backend] in try backend.homePageID() }) { id, _ in
        if let id {
          PageView(id: id, title: "Catalog")
        } else {
          ContentUnavailableView("No catalog", systemImage: "books.vertical", description: Text("Your account has no catalog home page."))
        }
      }
      .navigationDestination(for: CatalogRoute.self) { destination($0) }
    }
    .environment(\.openRoute) { CatalogRoute.open($0, in: &app.catalogPath) }
  }
}

struct SearchView: View {
  @Environment(AppModel.self) private var app
  @FocusState private var fieldFocused: Bool

  var body: some View {
    @Bindable var app = app
    VStack(spacing: 0) {
      // A field of its own: .searchable on a view swapped into the split
      // view's detail never reaches the window toolbar on macOS.
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search the catalog", text: $app.searchText)
          .textFieldStyle(.plain)
          .focused($fieldFocused)
          .onSubmit(submit)
        if !app.searchText.isEmpty {
          Button {
            app.searchText = ""
            fieldFocused = true
          } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            .buttonStyle(.plain)
            .help("Clear")
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      Divider()
      NavigationStack(path: $app.searchPath) {
        Group {
          if app.searchQuery.isEmpty {
            ContentUnavailableView("Search the catalog", systemImage: "magnifyingglass",
                                   description: Text("Type a title, a character or an author above, then press Return."))
          } else {
            Loading(key: [app.searchQuery, String(app.contentVersion)], "Searching…",
                    load: { [backend = app.backend, q = app.searchQuery] in try backend.search(q) }) { results, _ in
              let items = CatalogSection.unique(results.compactMap(CatalogItem.element))
              if items.isEmpty {
                ContentUnavailableView.search(text: app.searchQuery)
              } else {
                ItemList(sections: [CatalogSection(id: 0, title: "Results", items: items)])
              }
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(app.searchQuery.isEmpty ? "Search" : "“\(app.searchQuery)”")
        .navigationDestination(for: CatalogRoute.self) { destination($0) }
      }
      .frame(maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .environment(\.openRoute) { CatalogRoute.open($0, in: &app.searchPath) }
    // The sidebar keeps the focus after a click on "Search": take it just after.
    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { fieldFocused = true } }
    .onChange(of: app.searchFocusRequest) { fieldFocused = true }
  }

  private func submit() {
    let q = app.searchText.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return }
    app.searchPath = []
    app.searchQuery = q
  }
}

// MARK: - Shared list

/// Catalog rows grouped in sections. Categories and collections open with a
/// click; episodes are selected (⌘/⇧-click for several) and open with a
/// double-click. "Download to Library" fetches the selected episodes, or the
/// selected collection.
struct ItemList<Header: View>: View {
  let sections: [CatalogSection]
  /// The collection being shown, so its episodes go to its folder.
  var collection: String? = nil
  let header: Header

  @Environment(AppModel.self) private var app
  @Environment(\.openRoute) private var open
  @ViewState private var selection = Set<String>()

  init(sections: [CatalogSection], collection: String? = nil, @ViewBuilder header: () -> Header) {
    self.sections = sections
    self.collection = collection
    self.header = header()
  }

  private var allItems: [CatalogItem] { sections.flatMap(\.items) }
  private var selectedItems: [CatalogItem] { allItems.filter { selection.contains($0.id) } }

  var body: some View {
    List(selection: $selection) {
      header
      ForEach(sections) { section in
        Section(section.title) {
          ForEach(section.items) { item in
            if item.isContent {
              CatalogRow(item: item)
            } else {
              Button { item.route.map(open) } label: { CatalogRow(item: item).contentShape(Rectangle()) }
                .buttonStyle(.plain)
            }
          }
        }
      }
    }
    .contextMenu(forSelectionType: String.self) { ids in
      let items = allItems.filter { ids.contains($0.id) }
      if items.count == 1, let route = items[0].route { Button("Open") { open(route) } }
      addButtons(items)
    } primaryAction: { ids in
      if ids.count == 1, let item = allItems.first(where: { ids.contains($0.id) }), let route = item.route { open(route) }
    }
    .toolbar {
      ToolbarItem {
        Button { add(selectedItems) } label: { Label("Download to Library", systemImage: "arrow.down.circle") }
          .help("Download the selected episodes (or collection) to your library")
          .disabled(!canAdd(selectedItems))
      }
    }
  }

  @ViewBuilder
  private func addButtons(_ items: [CatalogItem]) -> some View {
    if canAdd(items) {
      Button("Download to Library") { add(items) }
    } else if items.contains(where: { app.downloadState($0) == .downloaded }) {
      Button("Already in Your Library") {}.disabled(true)
    }
  }

  /// Something selected that isn't in the library yet (nor downloading).
  private func canAdd(_ items: [CatalogItem]) -> Bool {
    let contents = items.filter(\.isContent)
    if !contents.isEmpty { return contents.contains { app.downloadState($0) == .none } }
    guard items.count == 1, items[0].kind == .collection else { return false }
    switch app.downloadState(items[0]) {
    case .none, .partial: return true
    case .downloaded, .downloading: return false
    }
  }

  private func add(_ items: [CatalogItem]) {
    let contents = items.filter(\.isContent)
    if contents.isEmpty, let col = items.first, col.kind == .collection {
      app.download(collection: col.itemID, title: col.title)
    } else {
      app.download(contents: contents.filter { app.downloadState($0) == .none }.map { ($0.itemID, $0.title, $0.size) }, collection: collection)
      selection = []
    }
  }
}

extension ItemList where Header == EmptyView {
  init(sections: [CatalogSection], collection: String? = nil) { self.init(sections: sections, collection: collection) { EmptyView() } }
}

/// Title, artwork, metadata and description above a list.
struct DetailHeader: View {
  let title: String
  let imageURL: URL?
  let symbol: String
  let lines: [String]
  let description: String?

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      Artwork(url: imageURL, symbol: symbol, size: 96)
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.title2.bold()).textSelection(.enabled)
        ForEach(lines, id: \.self) { Text($0).foregroundStyle(.secondary) }
        if let description {
          Text(description).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 8)
    .selectionDisabled()
  }
}

// MARK: - Pages

struct PageView: View {
  let id: String
  let title: String?
  @Environment(AppModel.self) private var app

  var body: some View {
    Loading(key: [id, String(app.contentVersion)], "Loading…", load: { [backend = app.backend] in try backend.page(id) }) { page, _ in
      let sections = CatalogSection.page(page)
      if sections.isEmpty {
        ContentUnavailableView("Nothing here", systemImage: "square.grid.2x2")
      } else {
        ItemList(sections: sections).navigationTitle(page.text("title") ?? title ?? "Catalog")
      }
    }
    .navigationTitle(title ?? "Catalog")
  }
}

struct TaxonView: View {
  let id: String
  let title: String?
  @Environment(AppModel.self) private var app

  var body: some View {
    Loading(key: [id, String(app.contentVersion)], "Loading…", load: { [backend = app.backend] in try backend.taxonomy(id) }) { root, _ in
      let items = CatalogSection.unique(root.objs("elements").compactMap(CatalogItem.element))
      ItemList(sections: [CatalogSection(id: 0, title: "\(items.count) item(s)", items: items)]) {
        if let d = root.text("description") {
          Text(d).foregroundStyle(.secondary).selectionDisabled()
        }
      }
      .navigationTitle(root.text("title") ?? title ?? "Category")
    }
    .navigationTitle(title ?? "Category")
  }
}

struct CollectionView: View {
  let id: String
  @Environment(AppModel.self) private var app

  var body: some View {
    Loading(key: [id, String(app.contentVersion)], "Loading collection…", load: { [backend = app.backend] in try backend.collection(id) }) { col, _ in
      let episodes = col.objs("contents").sorted { $0.int("episode") < $1.int("episode") }.compactMap(CatalogItem.content)
      let title = col.text("title") ?? "Collection"
      let meta = [CatalogFormat.ages(col), CatalogFormat.episodes(col), CatalogFormat.duration(of: col), col.text("status")]
        .compactMap { $0 }.joined(separator: " · ")
      let brands = col.objs("brands").compactMap { $0.text("title") }.joined(separator: ", ")
      ItemList(sections: [CatalogSection(id: 0, title: episodes.isEmpty ? "No episode available" : "Episodes", items: CatalogSection.unique(episodes))],
               collection: id) {
        DetailHeader(title: title, imageURL: CatalogFormat.imageURL(col), symbol: "books.vertical",
                     lines: [meta, brands].filter { !$0.isEmpty }, description: col.text("description"))
      }
      .toolbar {
        ToolbarItem {
          let missing = episodes.filter { !app.inLibrary.contains($0.itemID) }.count
          if !episodes.isEmpty && missing == 0 {
            Label("All Episodes Downloaded", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
              .help("Every episode of this collection is in your library")
          } else {
            Button {
              app.download(collection: id, title: title,
                           size: episodes.filter { !app.inLibrary.contains($0.itemID) }.reduce(0) { $0 + $1.size })
            } label: {
              Label(missing < episodes.count ? "Download \(missing) Remaining Episode(s)" : "Download All Episodes",
                    systemImage: "arrow.down.square")
            }
            .help("Download the episodes of this collection that aren't in your library yet")
            .disabled(episodes.isEmpty || app.tasks.catalogIDs.contains(id))
          }
        }
      }
      .navigationTitle(title)
    }
    .navigationTitle("Collection")
  }
}

struct ContentDetailView: View {
  let id: String
  @Environment(AppModel.self) private var app
  @Environment(\.openRoute) private var open

  var body: some View {
    Loading(key: [id, String(app.contentVersion)], "Loading…", load: { [backend = app.backend] in try backend.content(id) }) { c, _ in
      let credits = [c.text("author").map { "by \($0)" }, c.text("narrator").map { "read by \($0)" }, CatalogFormat.ages(c)]
        .compactMap { $0 }.joined(separator: " · ")
      let meta = [CatalogFormat.duration(of: c), c["audio_size"] != nil ? String(format: "%.1f MB", Double(c.int("audio_size")) / 1_048_576) : nil]
        .compactMap { $0 }.joined(separator: " · ")
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          DetailHeader(title: c.text("title") ?? "Episode", imageURL: CatalogFormat.imageURL(c), symbol: "headphones",
                       lines: [credits, meta].filter { !$0.isEmpty }, description: c.text("description"))
          HStack {
            if app.inLibrary.contains(id) {
              DownloadedBadge()
              Text("Already in your library").foregroundStyle(.secondary)
              Button("Show in Library") { app.section = .library }
            } else if app.tasks.catalogIDs.contains(id) {
              ProgressView().controlSize(.small)
              Text("Downloading…").foregroundStyle(.secondary)
            } else {
              Button {
                app.download(contents: [(id, c.text("title") ?? "Episode", CatalogImporter.size(c))], collection: c.obj("collection")?.id("id"))
              } label: { Label("Download to Library", systemImage: "arrow.down.circle") }
                .buttonStyle(.borderedProminent)
            }
            if let parent = c.obj("collection"), let pid = parent.id("id") {
              Button { open(.collection(id: pid)) } label: { Label("Open \(parent.text("title") ?? "Collection")", systemImage: "books.vertical") }
            }
          }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .navigationTitle(c.text("title") ?? "Episode")
    }
  }
}

struct PackView: View {
  let id: String
  let title: String?
  @Environment(AppModel.self) private var app

  var body: some View {
    Loading(key: id, "Loading pack…", load: { [backend = app.backend] in try backend.packPreview(id) }) { pack, _ in
      List {
        DetailHeader(title: pack.text("title") ?? title ?? "Pack", imageURL: CatalogFormat.imageURL(pack), symbol: "gift",
                     lines: ["Packs are purchased on the Hello Merlin website."], description: pack.text("description"))
        Section("Included") {
          ForEach(Array(pack.objs("preview_contents").enumerated()), id: \.offset) { _, c in
            VStack(alignment: .leading) {
              Text(c.text("title") ?? "")
              if let s = c.text("subtitle") { Text(s).font(.caption).foregroundStyle(.secondary) }
            }
          }
        }
      }
    }
    .navigationTitle(title ?? "Pack")
  }
}
