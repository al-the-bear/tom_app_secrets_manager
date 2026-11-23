// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Why the provider has nothing to offer, in words for the user.
enum TomSecretsReaderError: Error {
  case notConfigured
  case noSnapshot
  case keyGone
  case cancelled
  case unreadable

  var message: String {
    switch self {
    case .notConfigured:
      return "This build of Tom Secrets Manager has no AutoFill configuration."
    case .noSnapshot:
      return "Open Tom Secrets Manager once and unlock it: it prepares the logins for AutoFill."
    case .keyGone:
      return "Open Tom Secrets Manager once: Touch ID changed, so it prepares the logins again."
    case .cancelled:
      return "Cancelled."
    case .unreadable:
      return "The logins prepared for AutoFill cannot be read: open Tom Secrets Manager once."
    }
  }
}

/// Reads the snapshot: its key from the data-protection keychain (Touch ID
/// or the login password releases it), the file from the App Group
/// container. The one file the extension writes is the pending file, where
/// a passkey made here waits until the app saves it into a vault; the data
/// it read lives in the extension's memory until it closes.
enum TomSecretsSnapshotReader {
  /// The App Group container and the keychain access group of this build.
  static func places() throws -> (container: URL, keychainGroup: String) {
    let info = Bundle.main.infoDictionary ?? [:]
    // Without a team the build setting leaves `.tom.secrets`: not configured.
    guard let group = info[TomSecretsAutofillPlaces.appGroupKey] as? String,
      !group.isEmpty, !group.hasPrefix("."),
      let keychainGroup = info[TomSecretsAutofillPlaces.keychainGroupKey] as? String,
      !keychainGroup.isEmpty, !keychainGroup.hasPrefix("."),
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: group)
    else { throw TomSecretsReaderError.notConfigured }
    return (container, keychainGroup)
  }

  static func read(reason: String) throws -> TomSecretsAutofillSnapshot {
    let (container, keychainGroup) = try places()
    let file = container.appendingPathComponent(TomSecretsAutofillPlaces.snapshotPath)
    guard let sealed = try? Data(contentsOf: file) else { throw TomSecretsReaderError.noSnapshot }

    let context = LAContext()
    context.localizedReason = reason
    var item: CFTypeRef?
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: TomSecretsAutofillPlaces.keyService,
      kSecAttrAccount as String: TomSecretsAutofillPlaces.keyAccount,
      kSecAttrAccessGroup as String: keychainGroup,
      kSecUseDataProtectionKeychain as String: true,
      kSecUseAuthenticationContext as String: context,
      kSecReturnData as String: true,
    ]
    switch SecItemCopyMatching(query as CFDictionary, &item) {
    case errSecSuccess:
      break
    case errSecItemNotFound:
      // A new fingerprint invalidated the key (biometryCurrentSet).
      throw TomSecretsReaderError.keyGone
    case errSecUserCanceled:
      throw TomSecretsReaderError.cancelled
    default:
      throw TomSecretsReaderError.unreadable
    }
    guard var keyData = item as? Data else { throw TomSecretsReaderError.unreadable }
    defer { keyData.resetBytes(in: 0..<keyData.count) }
    do {
      return try TomSecretsAutofillSnapshot.open(sealed, key: SymmetricKey(data: keyData))
    } catch {
      throw TomSecretsReaderError.unreadable
    }
  }

  // MARK: The pending passkeys.

  /// The pending key the app made. It has no Touch ID of its own: the
  /// extension reads the snapshot first, which verifies the user.
  static func pendingKey(_ keychainGroup: String) throws -> SymmetricKey {
    var item: CFTypeRef?
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: TomSecretsAutofillPlaces.keyService,
      kSecAttrAccount as String: TomSecretsAutofillPending.keyAccount,
      kSecAttrAccessGroup as String: keychainGroup,
      kSecUseDataProtectionKeychain as String: true,
      kSecReturnData as String: true,
    ]
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      var keyData = item as? Data
    else { throw TomSecretsReaderError.noSnapshot }
    defer { keyData.resetBytes(in: 0..<keyData.count) }
    return SymmetricKey(data: keyData)
  }

  /// The passkeys made here that the app has not saved into a vault yet.
  static func pendingPasskeys() -> [TomSecretsAutofillPasskey] {
    guard let (container, keychainGroup) = try? places(),
      let sealed = try? Data(
        contentsOf: container.appendingPathComponent(TomSecretsAutofillPending.path)),
      let key = try? pendingKey(keychainGroup)
    else { return [] }
    return (try? TomSecretsAutofillPending.open(sealed, key: key)) ?? []
  }

  /// Adds [passkey] to the pending file, which the app reads at its next
  /// sync and clears once the passkey is in a vault.
  static func addPending(_ passkey: TomSecretsAutofillPasskey) throws {
    let (container, keychainGroup) = try places()
    let key = try pendingKey(keychainGroup)
    let url = container.appendingPathComponent(TomSecretsAutofillPending.path)
    var failure: Error?
    var coordinatorError: NSError?
    NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinatorError) { at in
      do {
        let sealed = try TomSecretsAutofillPending.appending(
          passkey, to: try? Data(contentsOf: at), key: key)
        try FileManager.default.createDirectory(
          at: at.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sealed.write(to: at, options: .atomic)
      } catch {
        failure = error
      }
    }
    if let error = coordinatorError ?? failure { throw error }
  }
}
