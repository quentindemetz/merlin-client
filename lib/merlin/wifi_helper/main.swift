// Merlin Wi-Fi helper: reads the current Wi-Fi network name and scans for
// networks. Since macOS 14 both need Location Services, which macOS only
// grants to app bundles — hence this tiny background app (see WifiHelper).
//
// usage: merlin-wifi <authorize|ssid|scan> <output-file>
// The result is written to <output-file> (atomically) because the app is
// launched through `open`, which doesn't pass stdout back reliably.
import CoreLocation
import CoreWLAN
import Foundation

final class LocationAuthorization: NSObject, CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  private var decided = false

  func request(timeout: TimeInterval = 120) -> CLAuthorizationStatus {
    manager.delegate = self
    if manager.authorizationStatus == .notDetermined {
      manager.requestWhenInUseAuthorization()
      let deadline = Date().addingTimeInterval(timeout)
      while !decided && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
    }
    return manager.authorizationStatus
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    if manager.authorizationStatus != .notDetermined { decided = true }
  }
}

let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "ssid"
let iface = CWWiFiClient.shared().interface()
var result = ""

switch command {
case "authorize":
  let auth = LocationAuthorization()
  switch auth.request() {
  case .authorizedAlways: result = "authorized"
  case .denied: result = "denied"
  case .restricted: result = "restricted"
  default: result = "undetermined"
  }
case "ssid":
  result = iface?.ssid() ?? ""
case "scan":
  let networks = (try? iface?.scanForNetworks(withSSID: nil)) ?? []
  result = Set(networks.compactMap { $0.ssid }).sorted().joined(separator: "\n")
default:
  exit(2)
}

if args.count > 2 {
  let out = URL(fileURLWithPath: args[2])
  let tmp = out.appendingPathExtension("tmp")
  try? result.write(to: tmp, atomically: true, encoding: .utf8)
  try? FileManager.default.moveItem(at: tmp, to: out)
} else {
  print(result)
}
