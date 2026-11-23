// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// **[C]** Passkeys in the AutoFill provider (part-os-integration,
// part-password-manager): the passkeys the snapshot carries, the pending
// file the extension keeps new ones in until the app saves them, and the
// provider as a WebAuthn authenticator — the same bytes as tom_secrets_core's
// `webauthn.dart`: the authenticator data (the relying party's SHA-256, the
// flags user present, verified, backup eligible and backed up, the counter
// 0, the attested credential with an all-zero AAGUID and the COSE key), the
// `none` attestation, ES256 (DER) and Ed25519 signatures.

import CryptoKit
import Foundation

/// A passkey as the snapshot and the pending file name it (tom_secrets_ui's
/// `tomSecretsAutofillPasskeyJson`): the base64url credential id and user
/// handle, the PKCS#8 PEM private key.
public struct TomSecretsAutofillPasskey: Codable, Equatable, Sendable {
  /// The entry (`<store>/~<32 hex>`), or the pending passkey's id.
  public let id: String
  public let store: String?
  public let title: String?
  public let rpId: String
  public let credentialId: String
  public let userHandle: String?
  public let userName: String?
  public let privateKeyPem: String

  public init(
    id: String, store: String? = nil, title: String? = nil, rpId: String,
    credentialId: String, userHandle: String?, userName: String?, privateKeyPem: String
  ) {
    self.id = id
    self.store = store
    self.title = title
    self.rpId = rpId
    self.credentialId = credentialId
    self.userHandle = userHandle
    self.userName = userName
    self.privateKeyPem = privateKeyPem
  }

  /// The credential id's bytes.
  public var credentialIdData: Data? { TomSecretsBase64Url.decode(credentialId) }

  /// The user handle's bytes, when it has one.
  public var userHandleData: Data? { userHandle.flatMap(TomSecretsBase64Url.decode) }
}

/// base64url without padding, as WebAuthn and KeePassXC write it.
public enum TomSecretsBase64Url {
  public static func encode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public static func decode(_ text: String) -> Data? {
    var t = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    return Data(base64Encoded: t)
  }
}

/// The pending file (tom_secrets_ui's `TomSecretsAutofillPending`): the
/// snapshot's sealed format, header key id `pending`, under the pending key.
public enum TomSecretsAutofillPending {
  /// Its path inside the App Group container.
  public static let path = "TomSecretsAutofill/pending-passkeys.tsmaf"

  /// The pending key's keychain account (service `tom.secrets.autofill`).
  public static let keyAccount = "pending-key"

  /// The passkeys of [data], opened with [key].
  public static func open(_ data: Data, key: SymmetricKey) throws -> [TomSecretsAutofillPasskey] {
    try TomSecretsAutofillSnapshot.open(data, key: key).passkeys
  }

  /// [passkeys] sealed under [key] at [written].
  public static func seal(
    _ passkeys: [TomSecretsAutofillPasskey], key: SymmetricKey, written: Date = Date()
  ) throws -> Data {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let header = try JSONEncoder().encode(
      TomSecretsAutofillSnapshot.Header(
        formatVersion: TomSecretsAutofillSnapshot.formatVersion, keyId: "pending",
        written: f.string(from: written)))
    struct Document: Encodable {
      let formatVersion: Int
      let entries: [String]
      let passkeys: [TomSecretsAutofillPasskey]
    }
    let plain = try JSONEncoder().encode(
      Document(
        formatVersion: TomSecretsAutofillSnapshot.formatVersion, entries: [], passkeys: passkeys))
    var prefix = TomSecretsAutofillSnapshot.magic
    let n = UInt32(header.count)
    prefix.append(contentsOf: [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
    prefix.append(header)
    let box = try AES.GCM.seal(plain, using: key, authenticating: prefix)
    var out = prefix
    out.append(contentsOf: box.nonce)
    out.append(box.ciphertext)
    out.append(box.tag)
    return out
  }
}

extension TomSecretsAutofillPending {
  /// The pending file [existing] (nil: none yet) with [passkey] added; a
  /// pending passkey of the same site and user handle is replaced, as the
  /// vault replaces it.
  public static func appending(
    _ passkey: TomSecretsAutofillPasskey, to existing: Data?, key: SymmetricKey
  ) throws -> Data {
    var passkeys = try existing.map { try open($0, key: key) } ?? []
    passkeys.removeAll {
      $0.rpId.lowercased() == passkey.rpId.lowercased() && $0.userHandle == passkey.userHandle
    }
    passkeys.append(passkey)
    return try seal(passkeys, key: key)
  }
}

/// The passkeys a sign-in at [rpId] may use: the relying party's own, and
/// of those only the [allowed] credential ids when the site names some.
/// [pending] ones the app has not saved yet count too, after the
/// snapshot's; one already in the snapshot is not listed twice.
public func tomSecretsMatchingPasskeys(
  _ passkeys: [TomSecretsAutofillPasskey], pending: [TomSecretsAutofillPasskey] = [],
  rpId: String, allowed: [Data] = []
) -> [TomSecretsAutofillPasskey] {
  let known = Set(passkeys.map(\.credentialId))
  return (passkeys + pending.filter { !known.contains($0.credentialId) }).filter { p in
    guard p.rpId.lowercased() == rpId.lowercased() else { return false }
    guard !allowed.isEmpty else { return true }
    return p.credentialIdData.map(allowed.contains) ?? false
  }
}

/// Why a passkey request cannot be answered.
public enum TomSecretsWebAuthnError: Error, Equatable {
  /// The site offers no algorithm this authenticator makes.
  case unsupportedAlgorithms([Int])
  /// The passkey's private key cannot be read.
  case unreadableKey
  /// A client data hash that is not 32 bytes.
  case badClientDataHash
}

/// The provider as a WebAuthn authenticator.
public enum TomSecretsWebAuthn {
  /// COSE ES256 and EdDSA.
  public static let es256 = -7
  public static let edDsa = -8

  /// User present, verified, backup eligible, backed up.
  public static let flags: UInt8 = 0x01 | 0x04 | 0x08 | 0x10

  /// Attested credential data included.
  public static let attested: UInt8 = 0x40

  /// SHA-256 of [rpId].
  public static func rpIdHash(_ rpId: String) -> Data { Data(SHA256.hash(data: Data(rpId.utf8))) }

  /// The authenticator data and signature of a sign-in with [passkey] over
  /// [clientDataHash].
  public static func assertion(
    _ passkey: TomSecretsAutofillPasskey, clientDataHash: Data
  ) throws -> (authenticatorData: Data, signature: Data) {
    guard clientDataHash.count == 32 else { throw TomSecretsWebAuthnError.badClientDataHash }
    var authenticatorData = rpIdHash(passkey.rpId)
    authenticatorData.append(flags)
    authenticatorData.append(contentsOf: [0, 0, 0, 0])
    let signed = authenticatorData + clientDataHash
    if let seed = ed25519Seed(passkey.privateKeyPem) {
      let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
      return (authenticatorData, try key.signature(for: signed))
    }
    guard let key = try? P256.Signing.PrivateKey(pemRepresentation: passkey.privateKeyPem) else {
      throw TomSecretsWebAuthnError.unreadableKey
    }
    return (authenticatorData, try key.signature(for: signed).derRepresentation)
  }

  /// A new passkey for [rpId] and [userHandle] / [userName] with the first
  /// of [algorithms] (the site's order) this authenticator makes; its
  /// credential id and `none` attestation object.
  public static func register(
    rpId: String, userHandle: Data, userName: String?, algorithms: [Int], id: String
  ) throws -> (passkey: TomSecretsAutofillPasskey, credentialId: Data, attestationObject: Data) {
    guard let algorithm = algorithms.first(where: { $0 == es256 || $0 == edDsa }) else {
      throw TomSecretsWebAuthnError.unsupportedAlgorithms(algorithms)
    }
    var credentialId = Data(count: 32)
    credentialId.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
    let cose: Data
    let pem: String
    if algorithm == es256 {
      let key = P256.Signing.PrivateKey()
      let raw = key.publicKey.rawRepresentation  // x || y
      cose = TomSecretsCbor.map([
        (.int(1), .int(2)), (.int(3), .int(-7)), (.int(-1), .int(1)),
        (.int(-2), .bytes(raw.prefix(32))), (.int(-3), .bytes(raw.suffix(32))),
      ])
      pem = key.pemRepresentation
    } else {
      let key = Curve25519.Signing.PrivateKey()
      cose = TomSecretsCbor.map([
        (.int(1), .int(1)), (.int(3), .int(-8)), (.int(-1), .int(6)),
        (.int(-2), .bytes(key.publicKey.rawRepresentation)),
      ])
      pem = ed25519Pem(key.rawRepresentation)
    }
    var authenticatorData = rpIdHash(rpId)
    authenticatorData.append(flags | attested)
    authenticatorData.append(contentsOf: [0, 0, 0, 0])
    authenticatorData.append(Data(count: 16))
    authenticatorData.append(contentsOf: [UInt8(credentialId.count >> 8), UInt8(credentialId.count & 0xFF)])
    authenticatorData.append(credentialId)
    authenticatorData.append(cose)
    let attestationObject = TomSecretsCbor.map([
      (.text("fmt"), .text("none")), (.text("attStmt"), .map([])),
      (.text("authData"), .bytes(authenticatorData)),
    ])
    let passkey = TomSecretsAutofillPasskey(
      id: id, rpId: rpId, credentialId: TomSecretsBase64Url.encode(credentialId),
      userHandle: TomSecretsBase64Url.encode(userHandle), userName: userName, privateKeyPem: pem)
    return (passkey, credentialId, attestationObject)
  }

  /// PKCS#8 of an Ed25519 key: a fixed 16-byte prefix and the seed.
  static let ed25519Prefix = Data([
    0x30, 0x2E, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
  ])

  static func ed25519Pem(_ seed: Data) -> String {
    let body = (ed25519Prefix + seed).base64EncodedString()
    return "-----BEGIN PRIVATE KEY-----\n\(body)\n-----END PRIVATE KEY-----"
  }

  /// The Ed25519 seed of a PKCS#8 PEM, or nil for another key.
  static func ed25519Seed(_ pem: String) -> Data? {
    let body = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
    guard let der = Data(base64Encoded: body), der.count == 48, der.prefix(16) == ed25519Prefix
    else { return nil }
    return der.suffix(32)
  }
}

/// The CBOR the authenticator writes (RFC 8949): integers, byte and text
/// strings, maps in the order given (CTAP2's canonical order by the caller).
public enum TomSecretsCbor {
  public indirect enum Value {
    case int(Int)
    case bytes(Data)
    case text(String)
    case map([(Value, Value)])
  }

  public static func map(_ pairs: [(Value, Value)]) -> Data { encode(.map(pairs)) }

  public static func encode(_ value: Value) -> Data {
    var out = Data()
    func head(_ major: UInt8, _ n: Int) {
      if n < 24 {
        out.append(major << 5 | UInt8(n))
      } else if n < 0x100 {
        out.append(contentsOf: [major << 5 | 24, UInt8(n)])
      } else if n < 0x10000 {
        out.append(contentsOf: [major << 5 | 25, UInt8(n >> 8), UInt8(n & 0xFF)])
      } else {
        out.append(contentsOf: [
          major << 5 | 26, UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF),
          UInt8(n & 0xFF),
        ])
      }
    }
    func write(_ v: Value) {
      switch v {
      case .int(let i) where i >= 0: head(0, i)
      case .int(let i): head(1, -1 - i)
      case .bytes(let b):
        head(2, b.count)
        out.append(b)
      case .text(let s):
        let b = Data(s.utf8)
        head(3, b.count)
        out.append(b)
      case .map(let pairs):
        head(5, pairs.count)
        for (k, value) in pairs {
          write(k)
          write(value)
        }
      }
    }
    write(value)
    return out
  }
}
