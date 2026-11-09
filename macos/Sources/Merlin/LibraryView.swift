import AppKit
import MerlinCore
import SwiftUI
import UniformTypeIdentifiers

/// The library: folders on the left, the selected folder's tracks on the
/// right. Files dropped anywhere are imported.
struct LibraryView: View {
  @Environment(AppModel.self) private var app
  @ViewState private var selectedFolder: String?
  @ViewState private var selectedTracks = Set<String>()
  @ViewState private var importing = false
  @ViewState private var pendingFiles: FileBatch?
  @ViewState private var creatingFolder = false
  @ViewState private var renaming: Rename?
  @ViewState private var renameText = ""
  @ViewState private var newSectionFor: String?
  @ViewState private var newSectionText = ""
  @ViewState private var deletingFolder: MediaLibrary.Folder?
  @ViewState private var deletingTracks: [String]?
  @ViewState private var dropTargeted = false

  enum Rename: Identifiable {
    case folder(MediaLibrary.Folder), track(MediaLibrary.Track)
    var id: String {
      switch self {
      case .folder(let f): return f.id
      case .track(let t): return t.id
      }
    }
  }

  var body: some View {
    Group {
      if let library = app.library {
        content(library)
      } else {
        ContentUnavailableView {
          Label("No library", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
          Text(app.libraryError ?? "Choose a folder for your library.")
        } actions: {
          Button("Choose Library Folder…") { app.chooseLibraryFolder() }
        }
      }
    }
    .navigationTitle("Library")
  }

  @ViewBuilder
  private func content(_ library: MediaLibrary) -> some View {
    let _ = app.libraryVersion
    let folders = library.folders()
    let stats = library.folderStats()
    let folder = folders.first { $0.id == selectedFolder } ?? folders.first
    VStack(spacing: 0) {
      if folders.isEmpty {
        empty
      } else {
        HSplitView {
          folderList(library, folders, stats, selected: folder?.id)
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 340)
          if let folder {
            TrackTable(library: library, folder: folder, folders: folders, selection: $selectedTracks,
                       rename: { startRename(.track($0)) }, delete: { deletingTracks = $0 })
              .frame(minWidth: 360)
          }
        }
      }
      LibraryFooter(library: library)
    }
    .overlay {
      if dropTargeted {
        RoundedRectangle(cornerRadius: 12).stroke(.tint, lineWidth: 3).padding(6).allowsHitTesting(false)
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      choose(urls)
      return true
    } isTargeted: { dropTargeted = $0 }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .folder], allowsMultipleSelection: true) { result in
      if case .success(let urls) = result { choose(urls) }
    }
    .sheet(item: $pendingFiles) { batch in
      ImportSheet(files: batch.files, folders: folders, sections: library.sections(), preselected: folder?.id) { destination in
        pendingFiles = nil
        app.importFiles(batch.files, into: destination)
      }
    }
    .sheet(isPresented: $creatingFolder) {
      NewFolderSheet(sections: library.sections()) { title, section in
        creatingFolder = false
        var made: MediaLibrary.Folder?
        app.edit("New folder") { made = try $0.addFolder(title, section: section) }
        if let made { selectedFolder = made.id }
      }
    }
    .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
      TextField("Title", text: $renameText)
      Button("Rename") { rename() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The speaker shows titles up to 63 bytes; longer ones are shortened there.")
    }
    .alert("New Section", isPresented: Binding(get: { newSectionFor != nil }, set: { if !$0 { newSectionFor = nil } })) {
      TextField("Section", text: $newSectionText)
      Button("Move") {
        if let id = newSectionFor { app.edit("Section") { try $0.setSection(id, to: newSectionText) } }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("On the speaker, folders whose section it doesn't have go to its first section.")
    }
    .confirmationDialog("Delete \(deletingFolder?.title ?? "")?", isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } })) {
      Button("Delete Folder and Its Files", role: .destructive) {
        if let f = deletingFolder { app.edit("Delete") { try $0.removeFolder(f.id) } }
      }
    } message: {
      Text("Its \(deletingFolder.flatMap { stats[$0.id]?.tracks } ?? 0) track(s) are deleted from the library folder. Devices drop them at their next sync.")
    }
    .confirmationDialog("Delete \(deletingTracks?.count ?? 0) track(s)?", isPresented: Binding(get: { deletingTracks != nil }, set: { if !$0 { deletingTracks = nil } })) {
      Button("Delete", role: .destructive) {
        if let ids = deletingTracks {
          app.edit("Delete") { try $0.removeTracks(ids) }
          selectedTracks = []
        }
      }
    } message: {
      Text("Their files are deleted from the library folder. Devices drop them at their next sync.")
    }
    .toolbar {
      ToolbarItemGroup {
        Button { importing = true } label: { Label("Import Files…", systemImage: "square.and.arrow.down") }
          .help("Import audio files or folders from this Mac")
        Button { creatingFolder = true } label: { Label("New Folder…", systemImage: "folder.badge.plus") }
        Button { app.section = .catalog } label: { Label("Merlin Catalog", systemImage: "books.vertical") }
          .help("Browse the Merlin catalog to download episodes")
      }
    }
  }

  private var empty: some View {
    ContentUnavailableView {
      Label("Your library is empty", systemImage: "music.note.house")
    } description: {
      Text("Download episodes from the Merlin catalog, or import audio files from this Mac (drop them here). Then send them to your speaker or your iPod.")
    } actions: {
      HStack {
        Button("Browse the Catalog") { app.section = .catalog }.buttonStyle(.borderedProminent)
        Button("Import Files…") { importing = true }
      }
    }
  }

  private func folderList(_ library: MediaLibrary, _ folders: [MediaLibrary.Folder],
                          _ stats: [String: (tracks: Int, size: Int, duration: Int)], selected: String?) -> some View {
    let sections = library.sections()
    return List(selection: Binding(get: { selected }, set: { selectedFolder = $0; selectedTracks = [] })) {
      ForEach(folders) { f in
        FolderRow(library: library, folder: f, count: stats[f.id]?.tracks ?? 0, version: app.libraryVersion)
          .tag(f.id)
          .contextMenu {
            Button("Play Folder") {
              app.player.play(library.tracks(in: f.id), folder: f, library: library)
            }
            .disabled((stats[f.id]?.tracks ?? 0) == 0)
            Divider()
            Button("Rename…") { startRename(.folder(f)) }
            Menu("Section") {
              ForEach(sections, id: \.self) { s in
                Button {
                  app.edit("Section") { try $0.setSection(f.id, to: s) }
                } label: {
                  if SpeakerPlaylist.normalized(s) == SpeakerPlaylist.normalized(f.section) { Label(s, systemImage: "checkmark") } else { Text(s) }
                }
              }
              Divider()
              Button("New Section…") {
                newSectionText = ""
                newSectionFor = f.id
              }
            }
            Button("Choose Cover…") { chooseCover(f) }
            if f.cover != nil {
              Button("Remove Cover") {
                app.edit("Cover") { try $0.setFolderCover(f.id, image: nil) }
                app.refreshArtwork(library.tracksUsingFolderCover(f.id))
              }
            }
            Divider()
            Button("Delete Folder…", role: .destructive) { deletingFolder = f }
          }
      }
      .onMove { from, to in
        var ids = folders.map(\.id)
        ids.move(fromOffsets: from, toOffset: to)
        app.edit("Reorder") { try $0.reorderFolders(ids) }
      }
    }
    .onDeleteCommand { if let f = folders.first(where: { $0.id == selected }) { deletingFolder = f } }
  }

  // MARK: Actions

  struct FileBatch: Identifiable {
    let files: [URL]
    var id: String { files.map(\.path).joined(separator: "\n") }
  }

  private func choose(_ urls: [URL]) {
    do {
      try Media.requireFFmpeg()
      let files = try MediaLibrary.audioFiles(urls)
      guard !files.isEmpty else { return app.fail("No audio files found there") }
      pendingFiles = FileBatch(files: files)
    } catch {
      app.fail(error.userMessage)
    }
  }

  private func startRename(_ target: Rename) {
    switch target {
    case .folder(let f): renameText = f.title
    case .track(let t): renameText = t.title
    }
    renaming = target
  }

  private func rename() {
    guard let target = renaming else { return }
    let text = renameText
    switch target {
    case .folder(let f): app.edit("Rename") { try $0.renameFolder(f.id, to: text) }
    case .track(let t): app.edit("Rename") { try $0.renameTrack(t.id, to: text) }
    }
  }

  private func chooseCover(_ folder: MediaLibrary.Folder) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.message = "Choose a cover for \(folder.title)"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    app.edit("Cover") { try $0.setFolderCover(folder.id, image: url) }
    app.refreshArtwork(app.library?.tracksUsingFolderCover(folder.id) ?? [])
  }
}

struct FolderRow: View {
  let library: MediaLibrary
  let folder: MediaLibrary.Folder
  let count: Int
  var version = 0

  var body: some View {
    HStack(spacing: 10) {
      LocalCover(url: folder.cover.map(library.url), symbol: folder.source == .merlin ? "books.vertical" : "folder", size: 36, version: version)
      VStack(alignment: .leading, spacing: 2) {
        Text(folder.title).lineLimit(2)
        Text("\(folder.section) · \(count) track\(count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
  }
}

struct TrackTable: View {
  let library: MediaLibrary
  let folder: MediaLibrary.Folder
  let folders: [MediaLibrary.Folder]
  @Binding var selection: Set<String>
  let rename: (MediaLibrary.Track) -> Void
  let delete: ([String]) -> Void
  @Environment(AppModel.self) private var app

  var body: some View {
    let version = app.libraryVersion
    let tracks = library.tracks(in: folder.id)
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 14) {
        LocalCover(url: folder.cover.map(library.url), symbol: "folder", size: 64, version: app.libraryVersion)
        VStack(alignment: .leading, spacing: 4) {
          Text(folder.title).font(.title2.bold()).lineLimit(2)
          let total = tracks.reduce(0) { $0 + ($1.duration ?? 0) }
          Text([folder.section, "\(tracks.count) track(s)", CatalogFormat.duration(total),
                ByteCountFormatter.string(fromByteCount: Int64(tracks.reduce(0) { $0 + $1.size }), countStyle: .file)]
            .compactMap { $0 }.joined(separator: " · "))
            .foregroundStyle(.secondary)
          if folder.source == .merlin { Text("From the Merlin catalog").font(.caption).foregroundStyle(.secondary) }
        }
        Spacer()
        Button { play(tracks, from: 0) } label: { Label("Play", systemImage: "play.fill") }
          .controlSize(.large)
          .disabled(tracks.isEmpty)
          .help("Play this folder")
      }
      .padding(12)
      Divider()
      if tracks.isEmpty {
        ContentUnavailableView("Empty folder", systemImage: "folder", description: Text("Import files into it, or move tracks here."))
      } else {
        Table(tracks, selection: $selection) {
          TableColumn("#") { t in
            if app.player.current?.id == t.id {
              Image(systemName: app.player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill").foregroundStyle(.tint)
            } else {
              Text("\(t.episode ?? t.position + 1)").foregroundStyle(.secondary).monospacedDigit()
            }
          }
          .width(32)
          TableColumn("Title") { t in
            HStack(spacing: 8) {
              LocalCover(url: t.cover.map(library.url), symbol: "music.note", size: 28, version: version)
              VStack(alignment: .leading, spacing: 1) {
                Text(t.title).lineLimit(1)
                Text([t.artist, t.source == .merlin ? "Merlin" : t.sourceName].compactMap { $0 }.joined(separator: " · "))
                  .font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
            }
          }
          TableColumn("Time") { t in Text(CatalogFormat.duration(t.duration) ?? "").monospacedDigit().foregroundStyle(.secondary) }
            .width(56)
        }
        .contextMenu(forSelectionType: String.self) { ids in
          let picked = tracks.filter { ids.contains($0.id) }
          if let first = picked.first, let i = tracks.firstIndex(of: first) {
            Button("Play") { play(tracks, from: i) }
            Divider()
          }
          if picked.count == 1 { Button("Rename…") { rename(picked[0]) } }
          Menu("Move to") {
            ForEach(folders.filter { $0.id != folder.id }) { f in
              Button(f.title) {
                app.edit("Move") { try $0.moveTracks(picked.map(\.id), to: f.id) }
                app.refreshArtwork(picked.filter { $0.cover == nil }.map(\.id))
                selection = []
              }
            }
          }
          Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(picked.map { library.url($0.audio) })
          }
          Divider()
          Button("Delete…", role: .destructive) { delete(picked.map(\.id)) }
        } primaryAction: { ids in
          if let i = tracks.firstIndex(where: { ids.contains($0.id) }) { play(tracks, from: i) }
        }
        .onDeleteCommand { if !selection.isEmpty { delete(Array(selection)) } }
        .onKeyPress(.space) {
          if let i = tracks.firstIndex(where: { selection.contains($0.id) }), app.player.current?.id != tracks[i].id {
            play(tracks, from: i)
          } else {
            app.player.toggle()
          }
          return .handled
        }
        .onKeyPress(.return) {
          guard let i = tracks.firstIndex(where: { selection.contains($0.id) }) else { return .ignored }
          play(tracks, from: i)
          return .handled
        }
      }
    }
  }
}

extension TrackTable {
  func play(_ tracks: [MediaLibrary.Track], from i: Int) {
    app.player.play(tracks, from: i, folder: folder, library: library)
  }
}

/// Where the library lives, how big it is, and what's in progress.
struct LibraryFooter: View {
  let library: MediaLibrary
  @Environment(AppModel.self) private var app

  var body: some View {
    let _ = app.libraryVersion
    HStack(spacing: 8) {
      Image(systemName: "externaldrive").foregroundStyle(.secondary)
      Text("\(library.trackCount) track(s), \(ByteCountFormatter.string(fromByteCount: Int64(library.totalSize), countStyle: .file)) in \(library.root.abbreviatingWithTildeInPath)")
        .lineLimit(1).truncationMode(.middle)
      Spacer()
      Button("Show in Finder") { app.revealLibrary() }.buttonStyle(.link)
      Button("Change…") { app.chooseLibraryFolder() }.buttonStyle(.link)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
  }
}

extension URL {
  var abbreviatingWithTildeInPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

/// A picture from the library folder, loaded off the main thread.
struct LocalCover: View {
  let url: URL?
  let symbol: String
  var size: CGFloat = 36
  /// The library's version: covers reload when it changes.
  var version = 0
  @ViewState private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().scaledToFill()
      } else {
        RoundedRectangle(cornerRadius: size / 6)
          .fill(.quaternary)
          .overlay(Image(systemName: symbol).font(.system(size: size * 0.42)).foregroundStyle(.secondary))
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size / 6))
    .task(id: "\(url?.path ?? "")#\(version)") {
      guard let url else { image = nil; return }
      let pixels = Int(size * 2)
      image = await Task.detached { Self.thumbnail(url, pixels) }.value
    }
  }

  nonisolated static func thumbnail(_ url: URL, _ pixels: Int) -> NSImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
          ] as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
  }
}

// MARK: - Sheets

/// Where imported files go: by album tag, an existing folder, or a new one.
struct ImportSheet: View {
  enum Choice: Hashable { case byAlbum, folder(String), new }

  let files: [URL]
  let folders: [MediaLibrary.Folder]
  let sections: [String]
  let preselected: String?
  let onImport: (MediaLibrary.ImportDestination) -> Void

  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @ViewState private var choice: Choice = .byAlbum
  @ViewState private var section = MediaLibrary.defaultSections[0]
  @ViewState private var name = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Import \(files.count) file(s)").font(.headline)
      Picker("Put them in", selection: $choice) {
        Text("A folder per album (from the files' tags)").tag(Choice.byAlbum)
        Text("A new folder…").tag(Choice.new)
        if !folders.isEmpty {
          Divider()
          ForEach(folders) { Text($0.title).tag(Choice.folder($0.id)) }
        }
      }
      if choice == .new {
        TextField("Folder name", text: $name)
      }
      if !isExisting {
        Picker("Section", selection: $section) {
          ForEach(sections, id: \.self) { Text($0).tag($0) }
        }
        Text(choice == .byAlbum
          ? "Files without an album tag go to “\(MediaLibrary.fallbackFolder)”. New folders go into this section."
          : "On the speaker, the folder goes into this section.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Text("MP3s the speaker can play are copied as they are; other formats are converted to MP3 with ffmpeg.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Import") { start() }
          .keyboardShortcut(.defaultAction)
          .disabled(choice == .new && name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 460)
    .onAppear { if let preselected, folders.contains(where: { $0.id == preselected }) { choice = .folder(preselected) } }
  }

  private var isExisting: Bool {
    if case .folder = choice { return true }
    return false
  }

  private func start() {
    switch choice {
    case .byAlbum: onImport(.byAlbum(section: section))
    case .folder(let id): onImport(.folder(id))
    case .new:
      var made: MediaLibrary.Folder?
      app.edit("New folder") { made = try $0.addFolder(name, section: section) }
      if let made { onImport(.folder(made.id)) }
    }
  }
}

struct NewFolderSheet: View {
  let sections: [String]
  let onCreate: (String, String) -> Void
  @Environment(\.dismiss) private var dismiss
  @ViewState private var name = ""
  @ViewState private var section = MediaLibrary.defaultSections[0]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("New Folder").font(.headline)
      TextField("Name", text: $name)
      Picker("Section", selection: $section) {
        ForEach(sections, id: \.self) { Text($0).tag($0) }
      }
      Text("The speaker doesn't show folder names: a folder without a cover gets one with its name on it.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Create") { onCreate(name, section) }
          .keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 400)
  }
}
