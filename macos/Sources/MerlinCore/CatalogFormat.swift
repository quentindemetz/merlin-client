import Foundation

/// Labels for catalog items (durations are in seconds).
public enum CatalogFormat {
  public static func duration(_ secs: Int?) -> String? {
    guard let secs else { return nil }
    return secs >= 3600 ? String(format: "%dh%02d", secs / 3600, secs % 3600 / 60) : String(format: "%d:%02d", secs / 60, secs % 60)
  }

  public static func duration(of x: JSONObject, _ key: String = "duration") -> String? {
    x[key] == nil || x[key] is NSNull ? nil : duration(x.int(key))
  }

  /// The API sends min_age/max_age = 0 when no age is set; some items carry
  /// an age tag instead (taxonomies of type TAG such as "7 ans et +").
  public static func ages(_ x: JSONObject) -> String? {
    let lo = x.int("min_age"), hi = x.int("max_age")
    if lo > 0 && hi > 0 { return "\(lo)-\(hi) ans" }
    if lo > 0 { return "\(lo) ans et +" }
    if hi > 0 { return "jusqu'à \(hi) ans" }
    return x.objs("taxonomies").first {
      $0.str("type") == "TAG" && ($0.str("title") ?? "").range(of: #"^\d+\s*ans\b"#, options: .regularExpression) != nil
    }?.str("title")
  }

  public static func episodes(_ x: JSONObject) -> String? {
    x.int("nb_episode") > 0 ? "\(x.int("nb_episode")) ép." : nil
  }

  /// Protected audio: secure.bayard.io sits behind CloudFront signed
  /// links, and the catalog hands out the bare link, which answers 403.
  /// (Badaboum-style paid audio on the public S3 bucket downloads fine.)
  public static func isLocked(_ c: JSONObject) -> Bool {
    guard let s = c.str("audio_url"), let u = URL(string: Backend.lenientURL(s)) else { return false }
    return u.host?.lowercased() == "secure.bayard.io" && !(u.query ?? "").contains("Key-Pair-Id")
  }

  public static let lockedMessage = "protected: Merlin gives out no download link for it (bought episodes reach the speaker through its own sync)"

  /// Best guess at an artwork URL (the field name varies across endpoints).
  public static func imageURL(_ x: JSONObject) -> URL? {
    let keys = x.keys.sorted().filter { $0.range(of: "image|cover|thumbnail|picture|illustration|visual|artwork", options: [.regularExpression, .caseInsensitive]) != nil }
    for k in keys {
      if let s = x.str(k), s.hasPrefix("http") { return URL(string: Backend.lenientURL(s)) }
      if let o = x.obj(k), let s = o.values.compactMap({ $0 as? String }).first(where: { $0.hasPrefix("http") }) {
        return URL(string: Backend.lenientURL(s))
      }
      // "images": [{"url": "https://…", "type": "PHOTO"}, …]
      for o in x.objs(k) {
        if let s = o.str("url") ?? o.values.compactMap({ $0 as? String }).first(where: { $0.hasPrefix("http") }), s.hasPrefix("http") {
          return URL(string: Backend.lenientURL(s))
        }
      }
    }
    return nil
  }
}
