// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

import AuthenticationServices
import Cocoa
import CryptoKit
import FlutterMacOS
import LocalAuthentication
import Security

/// `tom_secrets_desktop/autofill`: the app's half of the macOS AutoFill
/// provider (part-os-integration, DP-50, DP-51).
///
/// - `state`: whether this build has the provider (the extension embedded,
///   the App Group and the keychain access group named by the team in the
///   app's Info.plist, `TSMAutofillAppGroup` / `TSMAutofillKeychainGroup`),
///   and whether the user turned it on in System Settings
///   (`ASCredentialIdentityStore.getState`);
/// - `storeKey`: the snapshot key into the data-protection keychain, in the
///   shared access group, released by Touch ID of the current fingerprints
///   (`biometryCurrentSet`; a Mac without Touch ID: `userPresence`, the login
///   password), this device only;
/// - `writeSnapshot`: the sealed snapshot into the App Group container,
///   atomically (a temporary file, then a rename);
/// - `remove`: the snapshot and its key deleted;
/// - `setIdentities`: the QuickType identities (domain and user name, no
///   password) replaced, or all removed;
/// - `openSettings`: System Settings at the AutoFill providers;
/// - **[C]** `readPending`: the pending file of the passkeys the extension
///   registered (its bytes and SHA-256) with the pending key, which
///   `storeKey` makes once (random, kept across unlocks in the shared
///   access group, this device only, readable while the Mac is unlocked);
///   `replacePending`: the file replaced (or deleted) only while it is still
///   the one read (`expected`), so a passkey the extension adds meanwhile
///   is never lost; passkey identities (`ASPasskeyCredentialIdentity`,
///   macOS 14) beside the password ones.
///
/// The extension (`tom_secrets_app/macos/TomSecretsAutofill`, its core
/// `TomSecretsAutofillKit`'s `TomSecretsAutofillPlaces`) reads the same
/// path and keychain item.
@available(macOS 11.0, *)
enum TomSecretsAutofillChannel {
  static let snapshotPath = "TomSecretsAutofill/snapshot.tsmaf"
  static let keyService = "tom.secrets.autofill"
  static let keyAccount = "snapshot-key"
  static let pendingPath = "TomSecretsAutofill/pending-passkeys.tsmaf"
  static let pendingKeyAccount = "pending-key"
  static let extensionName = "TomSecretsAutofill.appex"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "tom_secrets_desktop/autofill", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "state":
        state(result)
      case "storeKey":
        guard let key = (args["key"] as? FlutterStandardTypedData)?.data,
          let keyId = args["keyId"] as? String
        else { return bad(result) }
        result(storeKey(key, keyId: keyId))
      case "writeSnapshot":
        guard let bytes = (args["bytes"] as? FlutterStandardTypedData)?.data else {
          return bad(result)
        }
        result(writeSnapshot(bytes))
      case "remove":
        result(remove())
      case "setIdentities":
        guard let list = args["identities"] as? [[String: String]] else { return bad(result) }
        setIdentities(list, result)
      case "readPending":
        result(readPending())
      case "replacePending":
        guard let expected = args["expected"] as? String else { return bad(result) }
        result(replacePending((args["bytes"] as? FlutterStandardTypedData)?.data, expected: expected))
      case "openSettings":
        let url = URL(string: "x-apple.systempreferences:com.apple.Passwords-Settings.extension")!
        result(NSWorkspace.shared.open(url))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func bad(_ result: FlutterResult) {
    result(FlutterError(code: "bad_arguments", message: "unexpected arguments", details: nil))
  }

  /// The group named in the app's Info.plist; nil without a team (the
  /// setting then reads `.tom.secrets`).
  private static func group(_ key: String) -> String? {
    guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
      !value.isEmpty, !value.hasPrefix(".")
    else { return nil }
    return value
  }

  private static var appGroup: String? { group("TSMAutofillAppGroup") }
  private static var keychainGroup: String? { group("TSMAutofillKeychainGroup") }

  private static var snapshotURL: URL? {
    guard let appGroup,
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroup)
    else { return nil }
    return container.appendingPathComponent(snapshotPath)
  }

  private static func state(_ result: @escaping FlutterResult) {
    func unavailable(_ reason: String) {
      result(["available": false, "reason": reason, "providerEnabled": false])
    }
    let embedded =
      Bundle.main.builtInPlugInsURL.map {
        FileManager.default.fileExists(atPath: $0.appendingPathComponent(extensionName).path)
      } ?? false
    guard embedded else {
      return unavailable(
        "This build has no AutoFill provider: it comes with the team-signed build of Tom Secrets Manager.")
    }
    guard appGroup != nil, keychainGroup != nil else {
      return unavailable("This build names no App Group for AutoFill (no Apple team).")
    }
    guard snapshotURL != nil else {
      return unavailable("macOS gives this build no App Group container (not team-signed).")
    }
    ASCredentialIdentityStore.shared.getState { state in
      DispatchQueue.main.async {
        result(["available": true, "providerEnabled": state.isEnabled])
      }
    }
  }

  private static func keyQuery(account: String = keyAccount) -> [String: Any]? {
    guard let keychainGroup else { return nil }
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keyService,
      kSecAttrAccount as String: account,
      kSecAttrAccessGroup as String: keychainGroup,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }

  private static var pendingURL: URL? {
    snapshotURL?.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(pendingPath)
  }

  /// The pending key, made when there is none.
  private static func pendingKey() -> Data? {
    guard var query = keyQuery(account: pendingKeyAccount) else { return nil }
    var read = query
    read[kSecReturnData as String] = true
    var item: CFTypeRef?
    if SecItemCopyMatching(read as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
      return data
    }
    let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    query[kSecValueData as String] = key
    query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    query[kSecAttrLabel as String] = "Tom Secrets Manager AutoFill passkeys"
    return SecItemAdd(query as CFDictionary, nil) == errSecSuccess ? key : nil
  }

  private static func readPending() -> Any {
    guard let key = pendingKey() else { return error("no pending key") }
    guard let url = pendingURL, let bytes = try? Data(contentsOf: url) else {
      return ["key": FlutterStandardTypedData(bytes: key)]
    }
    return [
      "key": FlutterStandardTypedData(bytes: key),
      "bytes": FlutterStandardTypedData(bytes: bytes),
      "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
    ]
  }

  private static func replacePending(_ bytes: Data?, expected: String) -> Any {
    guard let url = pendingURL else { return error("no App Group container") }
    // Coordinated with the extension's append, so a passkey it adds between
    // the check and the write is never lost.
    var answer: Any = false
    var coordinatorError: NSError?
    NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinatorError) { at in
      let current = (try? Data(contentsOf: at)).map {
        SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
      }
      guard current == expected else { return }
      do {
        if let bytes {
          try bytes.write(to: at, options: [.atomic])
        } else {
          try FileManager.default.removeItem(at: at)
        }
        answer = true
      } catch let e {
        answer = error("\(e)")
      }
    }
    if let coordinatorError { return error("\(coordinatorError)") }
    return answer
  }

  private static func storeKey(_ key: Data, keyId: String) -> Any {
    guard var query = keyQuery() else { return error("no keychain access group") }
    SecItemDelete(query as CFDictionary)
    // The pending key outlives the unlock: made once, kept.
    _ = pendingKey()
    var biometrics: NSError?
    let flags: SecAccessControlCreateFlags =
      LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometrics)
      ? .biometryCurrentSet : .userPresence
    guard
      let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, nil)
    else { return error("no access control") }
    query[kSecValueData as String] = key
    query[kSecAttrAccessControl as String] = access
    query[kSecAttrLabel as String] = "Tom Secrets Manager AutoFill"
    query[kSecAttrGeneric as String] = Data(keyId.utf8)
    let status = SecItemAdd(query as CFDictionary, nil)
    return status == errSecSuccess ? true : error("keychain status \(status)")
  }

  private static func writeSnapshot(_ bytes: Data) -> Any {
    guard let url = snapshotURL else { return error("no App Group container") }
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try bytes.write(to: url, options: [.atomic])
      return true
    } catch let e {
      return error("\(e)")
    }
  }

  private static func remove() -> Any {
    if let url = snapshotURL { try? FileManager.default.removeItem(at: url) }
    if let query = keyQuery() { SecItemDelete(query as CFDictionary) }
    // AutoFill off: the passkeys not yet saved stay for the app to save,
    // the pending key with them.
    return true
  }

  private static func setIdentities(
    _ list: [[String: String]], _ result: @escaping FlutterResult
  ) {
    let store = ASCredentialIdentityStore.shared
    let done: (Bool, Error?) -> Void = { ok, e in
      DispatchQueue.main.async { result(ok ? true : error("\(e.map { "\($0)" } ?? "refused")")) }
    }
    store.getState { state in
      guard state.isEnabled else {
        // Nothing to register while the provider is off in System Settings.
        DispatchQueue.main.async { result(true) }
        return
      }
      if list.isEmpty {
        store.removeAllCredentialIdentities(done)
        return
      }
      let passwords = list.compactMap { item -> ASPasswordCredentialIdentity? in
        guard item["credentialId"] == nil, let domain = item["domain"],
          let user = item["userName"]
        else { return nil }
        return ASPasswordCredentialIdentity(
          serviceIdentifier: ASCredentialServiceIdentifier(identifier: domain, type: .domain),
          user: user, recordIdentifier: item["recordIdentifier"])
      }
      if #available(macOS 14.0, *) {
        let passkeys = list.compactMap { item -> ASPasskeyCredentialIdentity? in
          guard let id = item["credentialId"], let credentialID = base64url(id),
            let rp = item["domain"]
          else { return nil }
          return ASPasskeyCredentialIdentity(
            relyingPartyIdentifier: rp, userName: item["userName"] ?? "",
            credentialID: credentialID,
            userHandle: item["userHandle"].flatMap(base64url) ?? Data(),
            recordIdentifier: item["recordIdentifier"])
        }
        var all: [any ASCredentialIdentity] = passwords
        all.append(contentsOf: passkeys as [any ASCredentialIdentity])
        store.replaceCredentialIdentities(all, completion: done)
      } else {
        store.replaceCredentialIdentities(with: passwords, completion: done)
      }
    }
  }

  private static func base64url(_ text: String) -> Data? {
    var t = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    return Data(base64Encoded: t)
  }

  private static func error(_ message: String) -> FlutterError {
    FlutterError(code: "autofill", message: message, details: nil)
  }
}
