import MerlinCore
import SwiftUI

/// Which library folders a device gets (all of them unless unchecked).
struct SyncSelection: View {
  let target: String
  /// Free space on the device, when known.
  var capacity: Int64?
  @Environment(AppModel.self) private var app

  var body: some View {
    let _ = app.libraryVersion
    if let library = app.library {
      let folders = library.folders()
      let stats = library.folderStats()
      let excluded = library.excludedFolders(target)
      let chosen = folders.filter { !excluded.contains($0.id) && (stats[$0.id]?.tracks ?? 0) > 0 }
      let tracks = chosen.reduce(0) { $0 + (stats[$1.id]?.tracks ?? 0) }
      let size = chosen.reduce(0) { $0 + (stats[$1.id]?.size ?? 0) }
      GroupBox {
        VStack(alignment: .leading, spacing: 0) {
          HStack {
            Text("\(tracks) track(s) in \(chosen.count) folder(s) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
              .bold()
            if let capacity, Int64(size) > capacity {
              Text("— more than the free space").foregroundStyle(.red)
            }
            Spacer()
            Button("All") { app.edit("Selection") { try $0.setIncluded(true, folders: folders.map(\.id), target: target) } }
            Button("None") { app.edit("Selection") { try $0.setIncluded(false, folders: folders.map(\.id), target: target) } }
          }
          .padding(.bottom, 8)
          if folders.isEmpty {
            Text("Your library is empty: download episodes from the catalog or import files first.")
              .foregroundStyle(.secondary)
              .padding(.vertical, 6)
          } else {
            Divider()
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(folders) { f in
                  let n = stats[f.id]?.tracks ?? 0
                  Toggle(isOn: Binding(get: { !excluded.contains(f.id) }, set: { on in
                    app.edit("Selection") { try $0.setIncluded(on, folders: [f.id], target: target) }
                  })) {
                    HStack(spacing: 8) {
                      LocalCover(url: f.cover.map(library.url), symbol: "folder", size: 24, version: app.libraryVersion)
                      Text(f.title).lineLimit(1)
                      Text(f.section).font(.caption).foregroundStyle(.secondary)
                      Spacer()
                      Text("\(n) · \(ByteCountFormatter.string(fromByteCount: Int64(stats[f.id]?.size ?? 0), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                  }
                  .toggleStyle(.checkbox)
                  .disabled(n == 0)
                  .padding(.vertical, 4)
                }
              }
            }
            .frame(minHeight: 120, maxHeight: 280)
          }
        }
        .padding(4)
      } label: {
        Text("What to send")
      }
    }
  }
}
