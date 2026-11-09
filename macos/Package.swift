// swift-tools-version:6.0
import PackageDescription

// Native macOS app for the Merlin speaker. Build the .app with ./build-app.sh,
// run the tests with ./test.sh (both work with the Command Line Tools alone).
let package = Package(
  name: "Merlin",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "Merlin", targets: ["Merlin"]),
    .library(name: "MerlinCore", targets: ["MerlinCore"]),
  ],
  targets: [
    // Everything that isn't UI: speaker protocol, cloud API, sync, Wi-Fi,
    // traffic filter, local library. Blocking code, run off the main thread.
    .target(name: "MerlinCore", linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(name: "Merlin", dependencies: ["MerlinCore"]),
    .testTarget(name: "MerlinCoreTests", dependencies: ["MerlinCore"]),
  ],
  swiftLanguageModes: [.v5]
)
