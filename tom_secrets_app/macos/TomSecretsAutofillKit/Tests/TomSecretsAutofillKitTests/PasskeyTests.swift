// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// **[C]** Passkeys in the provider (part-os-integration): keys as
// tom_secrets_core writes them sign here and verify; the pending file the
// Dart app seals opens here, and the one this kit seals opens in Dart
// (pending_swift_vector.json, written with TSM_UPDATE_VECTORS=1); a
// registration's authenticator data, COSE key and `none` attestation as
// tom_secrets_core writes them; an assertion that verifies with the
// registered key. With TSM_PASSKEY_VECTOR_OUT set, a registration and an
// assertion as WebAuthn JSON for a relying-party library's check. Demo keys.

import CryptoKit
import Foundation
import XCTest

@testable import TomSecretsAutofillKit

final class PasskeyTests: XCTestCase {
  struct Vector: Decodable {
    let es256Pem: String
    let ed25519Pem: String
    let pendingKey: String
    let pending: String
  }

  func vector() throws -> Vector {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "passkey_vector", withExtension: "json", subdirectory: "Resources"))
    return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
  }

  let clientHash = Data(SHA256.hash(data: Data("{\"type\":\"webauthn.get\"}".utf8)))

  func passkey(_ pem: String, rp: String = "site.example") -> TomSecretsAutofillPasskey {
    TomSecretsAutofillPasskey(
      id: "x", rpId: rp, credentialId: "ZGVtby1jcmVkZW50aWFs", userHandle: "dXNlcg",
      userName: "alice", privateKeyPem: pem)
  }

  func testAP256KeyAsCoreWritesItSignsAndVerifies() throws {
    let v = try vector()
    let (data, signature) = try TomSecretsWebAuthn.assertion(passkey(v.es256Pem), clientDataHash: clientHash)
    XCTAssertEqual(data.prefix(32), TomSecretsWebAuthn.rpIdHash("site.example"))
    XCTAssertEqual(data[32], 0x1D)
    XCTAssertEqual(data.count, 37)
    let key = try P256.Signing.PrivateKey(pemRepresentation: v.es256Pem).publicKey
    XCTAssertTrue(
      key.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: signature), for: data + clientHash))
  }

  func testAnEd25519KeyAsCoreWritesItSignsAndVerifies() throws {
    let v = try vector()
    let (data, signature) = try TomSecretsWebAuthn.assertion(passkey(v.ed25519Pem), clientDataHash: clientHash)
    XCTAssertEqual(signature.count, 64)
    let seed = try XCTUnwrap(TomSecretsWebAuthn.ed25519Seed(v.ed25519Pem))
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey
    XCTAssertTrue(key.isValidSignature(signature, for: data + clientHash))
    XCTAssertThrowsError(try TomSecretsWebAuthn.assertion(passkey(v.ed25519Pem), clientDataHash: Data([1])))
  }

  func testThePendingFileTheAppSealsOpens() throws {
    let v = try vector()
    let key = SymmetricKey(data: try XCTUnwrap(Data(base64Encoded: v.pendingKey)))
    let passkeys = try TomSecretsAutofillPending.open(
      try XCTUnwrap(Data(base64Encoded: v.pending)), key: key)
    XCTAssertEqual(passkeys.count, 1)
    XCTAssertEqual(passkeys[0].id, "pending-1")
    XCTAssertEqual(passkeys[0].rpId, "site.example")
    XCTAssertEqual(passkeys[0].userName, "alice")
    XCTAssertEqual(passkeys[0].privateKeyPem, v.es256Pem)
    XCTAssertThrowsError(
      try TomSecretsAutofillPending.open(
        try XCTUnwrap(Data(base64Encoded: v.pending)), key: SymmetricKey(size: .bits256)))
  }

  func parseRegistration(_ attestationObject: Data, credentialId: Data) throws -> Data {
    // The map of three: "fmt" "none", "attStmt" {}, "authData" <bytes>.
    let prefix = TomSecretsCbor.map([
      (.text("fmt"), .text("none")), (.text("attStmt"), .map([])),
    ])
    XCTAssertEqual(attestationObject[0], 0xA3)
    XCTAssertEqual(attestationObject[1..<prefix.count], prefix[1...])
    let rest = attestationObject.dropFirst(prefix.count)
    // "authData" then a byte string with a one- or two-byte length.
    let label = TomSecretsCbor.encode(.text("authData"))
    XCTAssertEqual(Data(rest.prefix(label.count)), label)
    let head = rest.dropFirst(label.count)
    let bytes = Array(head)
    let length: Int
    let start: Int
    switch bytes[0] {
    case 0x58: (length, start) = (Int(bytes[1]), 2)
    case 0x59: (length, start) = (Int(bytes[1]) << 8 | Int(bytes[2]), 3)
    default: throw TomSecretsWebAuthnError.unreadableKey
    }
    XCTAssertEqual(bytes.count, start + length)
    let data = Data(bytes[start...])
    XCTAssertEqual(data.prefix(32), TomSecretsWebAuthn.rpIdHash("swift.example"))
    XCTAssertEqual(data[32], 0x5D)
    XCTAssertEqual(Data(data[33..<37]), Data([0, 0, 0, 0]))
    XCTAssertEqual(Data(data[37..<53]), Data(count: 16))
    XCTAssertEqual(Int(data[53]) << 8 | Int(data[54]), credentialId.count)
    XCTAssertEqual(Data(data[55..<(55 + credentialId.count)]), credentialId)
    return Data(data[(55 + credentialId.count)...])
  }

  func testAnES256RegistrationAndItsAssertionVerify() throws {
    let made = try TomSecretsWebAuthn.register(
      rpId: "swift.example", userHandle: Data("bob-handle".utf8), userName: "bob",
      algorithms: [-257, -7], id: "p")
    XCTAssertEqual(made.credentialId.count, 32)
    let cose = try parseRegistration(made.attestationObject, credentialId: made.credentialId)
    // {1: 2, 3: -7, -1: 1, -2: x, -3: y}
    XCTAssertEqual(Array(cose.prefix(7)), [0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01])
    XCTAssertEqual(cose.count, 77)
    let x = cose[(cose.startIndex + 10)..<(cose.startIndex + 42)]
    let y = cose[(cose.startIndex + 45)..<(cose.startIndex + 77)]
    let key = try P256.Signing.PublicKey(rawRepresentation: x + y)
    let (data, signature) = try TomSecretsWebAuthn.assertion(made.passkey, clientDataHash: clientHash)
    XCTAssertTrue(
      key.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: signature), for: data + clientHash))
    XCTAssertEqual(made.passkey.userHandleData, Data("bob-handle".utf8))
    XCTAssertTrue(made.passkey.privateKeyPem.hasPrefix("-----BEGIN PRIVATE KEY-----"))
  }

  func testAnEd25519RegistrationAndItsAssertionVerify() throws {
    let made = try TomSecretsWebAuthn.register(
      rpId: "swift.example", userHandle: Data([1]), userName: nil, algorithms: [-8], id: "p")
    let cose = try parseRegistration(made.attestationObject, credentialId: made.credentialId)
    XCTAssertEqual(Array(cose.prefix(7)), [0xA4, 0x01, 0x01, 0x03, 0x27, 0x20, 0x06])
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: cose.suffix(32))
    let (data, signature) = try TomSecretsWebAuthn.assertion(made.passkey, clientDataHash: clientHash)
    XCTAssertTrue(key.isValidSignature(signature, for: data + clientHash))
    XCTAssertThrowsError(
      try TomSecretsWebAuthn.register(
        rpId: "swift.example", userHandle: Data([1]), userName: nil, algorithms: [-257], id: "p"))
  }

  func testMatchingPasskeysAndAppendingToThePendingFile() throws {
    let v = try vector()
    let a = passkey(v.es256Pem)
    let other = TomSecretsAutofillPasskey(
      id: "o", rpId: "Site.Example", credentialId: "b3RoZXI", userHandle: "b3RoZXI",
      userName: "carol", privateKeyPem: v.ed25519Pem)
    let foreign = passkey(v.es256Pem, rp: "other.example")
    let new = TomSecretsAutofillPasskey(
      id: "pending-2", rpId: "site.example", credentialId: "bmV3", userHandle: "bmV3",
      userName: "dave", privateKeyPem: v.es256Pem)
    XCTAssertEqual(
      tomSecretsMatchingPasskeys([a, other, foreign], pending: [a, new], rpId: "site.example").map(\.id),
      ["x", "o", "pending-2"])
    XCTAssertEqual(
      tomSecretsMatchingPasskeys(
        [a, other], rpId: "site.example", allowed: [Data("other".utf8)]
      ).map(\.id), ["o"])
    let key = SymmetricKey(size: .bits256)
    let first = try TomSecretsAutofillPending.appending(new, to: nil, key: key)
    let second = try TomSecretsAutofillPending.appending(other, to: first, key: key)
    let again = TomSecretsAutofillPasskey(
      id: "pending-3", rpId: "SITE.example", credentialId: "YWdhaW4", userHandle: "bmV3",
      userName: "dave", privateKeyPem: v.es256Pem)
    let third = try TomSecretsAutofillPending.appending(again, to: second, key: key)
    XCTAssertEqual(try TomSecretsAutofillPending.open(third, key: key).map(\.id), ["o", "pending-3"])
  }

  /// The pending file this kit seals, for the Dart test that opens it.
  func testThePendingFileThisKitSealsIsTheVector() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Resources/pending_swift_vector.json")
    guard ProcessInfo.processInfo.environment["TSM_UPDATE_VECTORS"] == "1" else {
      // Without the switch: the vector there must open here too.
      struct Swift: Decodable {
        let key: String
        let sealed: String
      }
      let v = try JSONDecoder().decode(Swift.self, from: Data(contentsOf: url))
      let opened = try TomSecretsAutofillPending.open(
        try XCTUnwrap(Data(base64Encoded: v.sealed)),
        key: SymmetricKey(data: try XCTUnwrap(Data(base64Encoded: v.key))))
      XCTAssertEqual(opened.map(\.id), ["swift-pending-1"])
      return
    }
    let made = try TomSecretsWebAuthn.register(
      rpId: "swift.example", userHandle: Data("bob-handle".utf8), userName: "bob",
      algorithms: [-7], id: "swift-pending-1")
    let key = SymmetricKey(size: .bits256)
    let sealed = try TomSecretsAutofillPending.seal([made.passkey], key: key)
    let json: [String: String] = [
      "key": key.withUnsafeBytes { Data($0) }.base64EncodedString(),
      "sealed": sealed.base64EncodedString(),
      "note": "Demo keys. Written by TomSecretsAutofillKit's PasskeyTests (TSM_UPDATE_VECTORS=1).",
    ]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(json).write(to: url)
  }

  /// A registration and an assertion as WebAuthn JSON, for a relying-party
  /// library to verify (TSM_PASSKEY_VECTOR_OUT names the file).
  func testWebAuthnJsonForARelyingPartyCheck() throws {
    guard let out = ProcessInfo.processInfo.environment["TSM_PASSKEY_VECTOR_OUT"] else { return }
    var result: [String: Any] = [:]
    for algorithm in [-7, -8] {
      let made = try TomSecretsWebAuthn.register(
        rpId: "demo.example", userHandle: Data("demo-user".utf8), userName: "alice",
        algorithms: [algorithm], id: "p")
      let create = Data(
        #"{"type":"webauthn.create","challenge":"cmVnaXN0ZXItY2hhbGxlbmdl","origin":"https://demo.example","crossOrigin":false}"#
          .utf8)
      let get = Data(
        #"{"type":"webauthn.get","challenge":"c2lnbmluLWNoYWxsZW5nZQ","origin":"https://demo.example","crossOrigin":false}"#
          .utf8)
      let (data, signature) = try TomSecretsWebAuthn.assertion(
        made.passkey, clientDataHash: Data(SHA256.hash(data: get)))
      let id = TomSecretsBase64Url.encode(made.credentialId)
      result["\(algorithm)"] = [
        "registration": [
          "id": id, "rawId": id, "type": "public-key",
          "response": [
            "clientDataJSON": TomSecretsBase64Url.encode(create),
            "attestationObject": TomSecretsBase64Url.encode(made.attestationObject),
          ],
          "clientExtensionResults": [String: String](),
        ],
        "assertion": [
          "id": id, "rawId": id, "type": "public-key",
          "response": [
            "clientDataJSON": TomSecretsBase64Url.encode(get),
            "authenticatorData": TomSecretsBase64Url.encode(data),
            "signature": TomSecretsBase64Url.encode(signature),
            "userHandle": made.passkey.userHandle ?? "",
          ],
          "clientExtensionResults": [String: String](),
        ],
      ]
    }
    try JSONSerialization.data(withJSONObject: result).write(to: URL(fileURLWithPath: out))
  }
}
