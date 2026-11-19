// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The provider's core (part-os-integration, DP-50): the snapshot the Dart
// app seals opened here (the vector tom_secrets_ui's autofill_test writes),
// a wrong key, a changed header and a foreign file refused; matching like
// the browser; the one-time codes (RFC 6238); staleness; search. Demo data.

import CryptoKit
import Foundation
import XCTest

@testable import TomSecretsAutofillKit

final class TomSecretsAutofillKitTests: XCTestCase {
  struct Vector: Decodable {
    let key: String
    let sealed: String
  }

  func vector() throws -> (SymmetricKey, Data) {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "snapshot_vector", withExtension: "json", subdirectory: "Resources"))
    let v = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    return (
      SymmetricKey(data: try XCTUnwrap(Data(base64Encoded: v.key))),
      try XCTUnwrap(Data(base64Encoded: v.sealed))
    )
  }

  func testTheSnapshotTheAppSealsOpens() throws {
    let (key, sealed) = try vector()
    let snapshot = try TomSecretsAutofillSnapshot.open(sealed, key: key)
    XCTAssertEqual(snapshot.header.keyId, "demo-key-1")
    XCTAssertEqual(snapshot.header.formatVersion, 1)
    XCTAssertEqual(snapshot.written, ISO8601DateFormatter().date(from: "2026-11-19T09:30:00Z"))
    let mail = try XCTUnwrap(snapshot.entries.first)
    XCTAssertEqual(mail.id, "team/~0123456789abcdef0123456789abcdef")
    XCTAssertEqual(mail.title, "Mail")
    XCTAssertEqual(mail.userName, "demo-user")
    XCTAssertEqual(mail.password, "demo-mail-pw")
    XCTAssertEqual(mail.urls.first?.site, "example.com")
    XCTAssertEqual(mail.totp?.digits, 6)
  }

  func testAWrongKeyAChangedHeaderAndAForeignFileAreRefused() throws {
    let (key, sealed) = try vector()
    XCTAssertThrowsError(
      try TomSecretsAutofillSnapshot.open(sealed, key: SymmetricKey(size: .bits256))
    ) { XCTAssertEqual($0 as? TomSecretsSnapshotError, .cannotOpen) }
    var header = sealed
    // The key id in the header: `demo-key-1` → `demo-key-2`.
    let range = try XCTUnwrap(header.range(of: Data("demo-key-1".utf8)))
    header[range.upperBound - 1] = UInt8(ascii: "2")
    XCTAssertThrowsError(try TomSecretsAutofillSnapshot.open(header, key: key)) {
      XCTAssertEqual($0 as? TomSecretsSnapshotError, .cannotOpen)
    }
    XCTAssertThrowsError(try TomSecretsAutofillSnapshot.open(Data(count: 64), key: key)) {
      XCTAssertEqual($0 as? TomSecretsSnapshotError, .notASnapshot)
    }
  }

  func entry(
    _ title: String, _ urls: [TomSecretsAutofillEntry.Url], rule: String = "domain"
  ) -> TomSecretsAutofillEntry {
    TomSecretsAutofillEntry(
      id: "team/~\(title)", store: "team", title: title, userName: "demo", password: "pw",
      rule: rule, urls: urls, totp: nil, modified: nil)
  }

  func url(
    _ host: String, site: String?, scheme: String = "https", port: Int? = nil,
    path: String = "/", address: Bool? = nil
  ) -> TomSecretsAutofillEntry.Url {
    TomSecretsAutofillEntry.Url(
      url: "\(scheme)://\(host)\(path)", scheme: scheme, host: host, port: port, path: path,
      site: site, address: address)
  }

  func testMatchingLikeTheBrowser() {
    let entries = [
      entry("Mail", [url("mail.example.com", site: "example.com")]),
      entry("Example", [url("example.com", site: "example.com")]),
      entry("Other pages", [url("other.github.io", site: "other.github.io")]),
      entry("Shop host", [url("shop.example.org", site: "example.org")], rule: "host"),
      entry(
        "Admin", [url("example.net", site: "example.net", path: "/admin")], rule: "exact"),
      entry("Router", [url("192.168.1.1", site: nil, scheme: "http", port: 8080, address: true)]),
      entry("Plain http", [url("plain.example", site: "plain.example", scheme: "https")]),
    ]
    func titles(_ ids: [TomSecretsServiceIdentifier]) -> [String] {
      tomSecretsMatchingEntries(entries, for: ids).map(\.title)
    }
    // The exact host first, then the domain.
    XCTAssertEqual(titles([.domain("mail.example.com")]), ["Mail", "Example"])
    XCTAssertEqual(titles([.url("https://login.example.com/x")]), ["Example", "Mail"])
    // github.io is a public suffix: another site.
    XCTAssertEqual(titles([.domain("example.github.io")]), [])
    XCTAssertEqual(titles([.domain("shop.example.org")]), ["Shop host"])
    XCTAssertEqual(titles([.domain("www.example.org")]), [])
    XCTAssertEqual(titles([.url("https://example.net/admin/users")]), ["Admin"])
    XCTAssertEqual(titles([.url("https://example.net/blog")]), [])
    XCTAssertEqual(titles([.url("http://192.168.1.1:8080/")]), ["Router"])
    XCTAssertEqual(titles([.url("http://192.168.1.1/")]), [])
    // An https entry is not offered on http.
    XCTAssertEqual(titles([.url("http://plain.example/")]), [])
  }

  func testOneTimeCodesFollowRfc6238() {
    // RFC 6238, appendix B: the ASCII secrets, 8 digits, 30 s.
    let secrets = [
      "SHA1": "12345678901234567890",
      "SHA256": "12345678901234567890123456789012",
      "SHA512": "1234567890123456789012345678901234567890123456789012345678901234",
    ]
    let expected: [(TimeInterval, [String: String])] = [
      (59, ["SHA1": "94287082", "SHA256": "46119246", "SHA512": "90693936"]),
      (1_111_111_109, ["SHA1": "07081804", "SHA256": "68084774", "SHA512": "25091201"]),
      (2_000_000_000, ["SHA1": "69279037", "SHA256": "90698825", "SHA512": "38618901"]),
    ]
    for (time, codes) in expected {
      for (algorithm, code) in codes {
        let totp = TomSecretsAutofillEntry.Totp(
          secret: Data(secrets[algorithm]!.utf8).base64EncodedString(), digits: 8, period: 30,
          algorithm: algorithm)
        XCTAssertEqual(totp.code(at: Date(timeIntervalSince1970: time)), code, "\(algorithm) \(time)")
      }
    }
    let six = TomSecretsAutofillEntry.Totp(
      secret: Data("12345678901234567890".utf8).base64EncodedString(), digits: 6, period: 30,
      algorithm: "SHA1")
    XCTAssertEqual(six.code(at: Date(timeIntervalSince1970: 59)), "287082")
    XCTAssertEqual(six.remaining(at: Date(timeIntervalSince1970: 59)), 1)
  }

  func testStalenessAndSearch() throws {
    let (key, sealed) = try vector()
    let snapshot = try TomSecretsAutofillSnapshot.open(sealed, key: key)
    XCTAssertFalse(snapshot.isStale(now: snapshot.written.addingTimeInterval(3600)))
    XCTAssertTrue(snapshot.isStale(now: snapshot.written.addingTimeInterval(25 * 3600)))
    XCTAssertEqual(snapshot.ageText(now: snapshot.written.addingTimeInterval(25 * 3600)), "25 hours")
    XCTAssertEqual(snapshot.ageText(now: snapshot.written.addingTimeInterval(72 * 3600)), "3 days")
    let entries = [
      entry("Mail", [url("mail.example.com", site: "example.com")]),
      entry("Bank", [url("bank.example", site: "bank.example")]),
    ]
    XCTAssertEqual(tomSecretsSearchEntries(entries, query: "").map(\.title), ["Bank", "Mail"])
    XCTAssertEqual(tomSecretsSearchEntries(entries, query: "MAIL.example").map(\.title), ["Mail"])
  }
}
