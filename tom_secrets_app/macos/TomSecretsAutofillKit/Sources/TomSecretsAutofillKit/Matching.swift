// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

import Foundation

/// What the system asks logins for: a web domain, or a URL (Safari passes
/// the page's URL).
public enum TomSecretsServiceIdentifier: Equatable, Sendable {
  case domain(String)
  case url(String)
}

/// How closely an entry matches.
public enum TomSecretsMatchLevel: Int, Comparable, Sendable {
  case exactHost = 0
  case domain = 1

  public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A page as matching reads it.
struct Page {
  let scheme: String
  let host: String
  let port: Int?
  let path: String

  init?(_ identifier: TomSecretsServiceIdentifier) {
    switch identifier {
    case .domain(let domain):
      let host = domain.trimmingCharacters(in: .whitespaces).lowercased()
      guard !host.isEmpty else { return nil }
      self.init(scheme: "https", host: host, port: nil, path: "/")
    case .url(let text):
      var t = text.trimmingCharacters(in: .whitespaces)
      if !t.contains("://") { t = "https://" + t }
      guard let c = URLComponents(string: t), let scheme = c.scheme?.lowercased(),
        scheme == "http" || scheme == "https", let host = c.host, !host.isEmpty
      else { return nil }
      let port = c.port.flatMap { $0 == (scheme == "https" ? 443 : 80) ? nil : $0 }
      self.init(
        scheme: scheme, host: host.lowercased(), port: port,
        path: c.path.isEmpty ? "/" : c.path)
    }
  }

  init(scheme: String, host: String, port: Int?, path: String) {
    self.scheme = scheme
    self.host = host
    self.port = port
    self.path = path
  }

  var isAddressOrLocalhost: Bool {
    host == "localhost" || host.hasSuffix(".localhost")
      || host.allSatisfy { $0.isNumber || $0 == "." } || host.contains(":")
  }
}

/// The level at which [url] of an entry under [rule] matches [page], as the
/// browser matches it (part-browser, URL matching): an `https` entry is not
/// offered on `http`; an address or `localhost` by host and port exactly;
/// `exact` by scheme, host, port and path prefix; `host` by the host;
/// `domain` by the host, else by the registrable domain. The app computed
/// the entry's registrable domain with the Public Suffix List; the page's
/// host is taken as of that domain when it is it or ends with `.` and it.
func matchLevel(
  _ url: TomSecretsAutofillEntry.Url, rule: String, page: Page
) -> TomSecretsMatchLevel? {
  if rule == "never" { return nil }
  if url.scheme == "https" && page.scheme == "http" { return nil }
  let sameHost = url.host == page.host
  if url.address == true || page.isAddressOrLocalhost {
    return sameHost && url.port == page.port ? .exactHost : nil
  }
  switch rule {
  case "exact":
    let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
    return url.scheme == page.scheme && sameHost && url.port == page.port
      && (page.path == url.path || page.path.hasPrefix(prefix)) ? .exactHost : nil
  case "host":
    return sameHost ? .exactHost : nil
  default:
    if sameHost { return .exactHost }
    guard let site = url.site else { return nil }
    return page.host == site || page.host.hasSuffix("." + site) ? .domain : nil
  }
}

/// The logins of [entries] for [identifiers], the closest match first, then
/// by title.
public func tomSecretsMatchingEntries(
  _ entries: [TomSecretsAutofillEntry],
  for identifiers: [TomSecretsServiceIdentifier]
) -> [TomSecretsAutofillEntry] {
  let pages = identifiers.compactMap(Page.init)
  var found: [(TomSecretsAutofillEntry, TomSecretsMatchLevel)] = []
  for entry in entries {
    var best: TomSecretsMatchLevel?
    for page in pages {
      for url in entry.urls {
        if let level = matchLevel(url, rule: entry.rule, page: page),
          best == nil || level < best!
        {
          best = level
        }
      }
    }
    if let best { found.append((entry, best)) }
  }
  return found.sorted {
    $0.1 != $1.1
      ? $0.1 < $1.1
      : $0.0.title.localizedCaseInsensitiveCompare($1.0.title) == .orderedAscending
  }.map(\.0)
}

/// The entries of [entries] whose title, user name or URL holds [query]
/// (any case); all of them for an empty query, by title.
public func tomSecretsSearchEntries(
  _ entries: [TomSecretsAutofillEntry], query: String
) -> [TomSecretsAutofillEntry] {
  let q = query.trimmingCharacters(in: .whitespaces).lowercased()
  return entries.filter { e in
    q.isEmpty || e.title.lowercased().contains(q) || e.userName.lowercased().contains(q)
      || e.urls.contains { $0.url.lowercased().contains(q) }
  }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
}
