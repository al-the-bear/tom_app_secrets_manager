// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

import CryptoKit
import Foundation

/// Where the app and the extension keep the snapshot and its key. The
/// desktop plugin (`tom_secrets_desktop`, `TomSecretsAutofillChannel`) names
/// the same values.
public enum TomSecretsAutofillPlaces {
  /// The snapshot's path inside the App Group container.
  public static let snapshotPath = "TomSecretsAutofill/snapshot.tsmaf"

  /// The keychain item's service and account (data-protection keychain, the
  /// shared access group).
  public static let keyService = "tom.secrets.autofill"
  public static let keyAccount = "snapshot-key"

  /// The Info.plist keys naming the App Group and the keychain access group
  /// (set from the build's team).
  public static let appGroupKey = "TSMAutofillAppGroup"
  public static let keychainGroupKey = "TSMAutofillKeychainGroup"
}

/// Why a snapshot cannot be read.
public enum TomSecretsSnapshotError: Error, Equatable {
  /// The file does not start with the magic, or is cut.
  case notASnapshot
  /// A format version this extension does not read.
  case unsupportedVersion(Int)
  /// The key does not open it, or the file was changed.
  case cannotOpen
}

/// The snapshot the desktop app writes (tom_secrets_ui's
/// `TomSecretsAutofillSnapshot`): the magic `TSM-AUTOFILL`, a big-endian
/// 32-bit header length, the header (JSON), a 12-byte nonce, the document
/// sealed with AES-256-GCM, the 16-byte tag; everything before the nonce is
/// the additional data.
public struct TomSecretsAutofillSnapshot: Equatable, Sendable {
  /// The header: the format version, the key id, when it was written.
  public struct Header: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let keyId: String
    public let written: String
  }

  /// The magic.
  public static let magic = Data("TSM-AUTOFILL".utf8)

  /// The format version this extension reads.
  public static let formatVersion = 1

  public let header: Header
  public let written: Date
  public let entries: [TomSecretsAutofillEntry]

  /// Opens [data] with [key].
  public static func open(_ data: Data, key: SymmetricKey) throws -> TomSecretsAutofillSnapshot {
    let m = magic.count
    guard data.count >= m + 4 + 12 + 16, data.prefix(m) == magic else {
      throw TomSecretsSnapshotError.notASnapshot
    }
    let bytes = [UInt8](data)
    let length =
      Int(bytes[m]) << 24 | Int(bytes[m + 1]) << 16 | Int(bytes[m + 2]) << 8 | Int(bytes[m + 3])
    let headerEnd = m + 4 + length
    guard headerEnd + 12 + 16 <= bytes.count else { throw TomSecretsSnapshotError.notASnapshot }
    let header: Header
    do {
      header = try JSONDecoder().decode(Header.self, from: Data(bytes[(m + 4)..<headerEnd]))
    } catch {
      throw TomSecretsSnapshotError.notASnapshot
    }
    guard header.formatVersion == formatVersion else {
      throw TomSecretsSnapshotError.unsupportedVersion(header.formatVersion)
    }
    let plain: Data
    do {
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: Data(bytes[headerEnd..<(headerEnd + 12)])),
        ciphertext: Data(bytes[(headerEnd + 12)..<(bytes.count - 16)]),
        tag: Data(bytes[(bytes.count - 16)...]))
      plain = try AES.GCM.open(box, using: key, authenticating: Data(bytes[0..<headerEnd]))
    } catch {
      throw TomSecretsSnapshotError.cannotOpen
    }
    struct Document: Decodable {
      let formatVersion: Int
      let entries: [TomSecretsAutofillEntry]
    }
    let document = try JSONDecoder().decode(Document.self, from: plain)
    return TomSecretsAutofillSnapshot(
      header: header,
      written: Self.date(header.written) ?? .distantPast,
      entries: document.entries)
  }

  /// Whether it is older than a day (the provider says how old then).
  public func isStale(now: Date = Date()) -> Bool {
    now.timeIntervalSince(written) > 24 * 60 * 60
  }

  /// Its age in words, for the provider's note.
  public func ageText(now: Date = Date()) -> String {
    let hours = Int(now.timeIntervalSince(written) / 3600)
    return hours < 48 ? "\(hours) hours" : "\(hours / 24) days"
  }

  static func date(_ text: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: text) ?? ISO8601DateFormatter().date(from: text)
  }
}

/// A login of the snapshot.
public struct TomSecretsAutofillEntry: Codable, Equatable, Sendable, Identifiable {
  /// One of its web URLs, with what matching needs.
  public struct Url: Codable, Equatable, Sendable {
    public let url: String
    public let scheme: String
    public let host: String
    public let port: Int?
    public let path: String
    /// The registrable domain (Public Suffix List, computed by the app), or
    /// nil for an address, `localhost` or a public suffix.
    public let site: String?
    /// An IP address or `localhost`: matched by host and port exactly.
    public let address: Bool?
  }

  /// A TOTP secret with its parameters.
  public struct Totp: Codable, Equatable, Sendable {
    /// The secret's bytes, base64.
    public let secret: String
    public let digits: Int
    public let period: Int
    /// `SHA1`, `SHA256` or `SHA512`.
    public let algorithm: String
  }

  /// `<store>/~<32 hex>`.
  public let id: String
  public let store: String
  public let title: String
  public let userName: String
  public let password: String
  /// `domain`, `host` or `exact` (`never` is left out by the app).
  public let rule: String
  public let urls: [Url]
  public let totp: Totp?
  public let modified: String?

  /// The site shown in the list: the first URL's host.
  public var site: String { urls.first?.host ?? "" }
}
