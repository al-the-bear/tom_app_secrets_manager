// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TomSecretsClipboard")
    else { return }
    let channel = FlutterMethodChannel(
      name: "tom_secrets_mobile/clipboard", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler(TomSecretsClipboard.handle)
    let app = FlutterMethodChannel(
      name: "tom_secrets_mobile/app", binaryMessenger: registrar.messenger())
    app.setMethodCallHandler { call, result in
      switch call.method {
      case "profileExpiry": result(TomSecretsProfile.expiry())
      case "physicalMemory": result(Int(clamping: ProcessInfo.processInfo.physicalMemory))
      default: result(FlutterMethodNotImplemented)
      }
    }
    let documents = FlutterMethodChannel(
      name: "tom_secrets_mobile/documents", binaryMessenger: registrar.messenger())
    documents.setMethodCallHandler(TomSecretsDocuments.shared.handle)
  }
}

/// The phone's files: a vault file picked in Files (iCloud Drive, On My
/// iPhone) kept by a security-scoped bookmark and read and written in place
/// through NSFileCoordinator (which also brings an iCloud file down); a file
/// picked to attach (a copy, read once); an attachment handed to the share
/// sheet from the temporary folder, removed when the sheet closes.
final class TomSecretsDocuments: NSObject, UIDocumentPickerDelegate {
  static let shared = TomSecretsDocuments()

  private var pending: FlutterResult?
  private var pickingVault = true

  private static func key(_ id: String) -> String { "tsm.document.\(id)" }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "pickVault": pick(vault: true, result)
    case "pickFile": pick(vault: false, result)
    case "read":
      let id = args["id"] as? String ?? ""
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let data = try self.withAccess(id) { url in try Self.coordinatedRead(url) }
          DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: data)) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "document", message: error.localizedDescription, details: nil))
          }
        }
      }
    case "write":
      let id = args["id"] as? String ?? ""
      let bytes = (args["bytes"] as? FlutterStandardTypedData)?.data ?? Data()
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          try self.withAccess(id) { url in try Self.coordinatedWrite(bytes, to: url) }
          DispatchQueue.main.async { result(nil) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "document", message: error.localizedDescription, details: nil))
          }
        }
      }
    case "share":
      let name = (args["name"] as? String ?? "attachment")
        .replacingOccurrences(of: "/", with: "_")
      let bytes = (args["bytes"] as? FlutterStandardTypedData)?.data ?? Data()
      share(name: name, bytes: bytes, result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func pick(vault: Bool, _ result: @escaping FlutterResult) {
    guard let top = Self.topController() else {
      result(FlutterError(code: "document", message: "no window to show Files in", details: nil))
      return
    }
    pending = result
    pickingVault = vault
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: !vault)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    top.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pending, let url = urls.first else { return }
    pending = nil
    do {
      if pickingVault {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(
          options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let id = UUID().uuidString
        UserDefaults.standard.set(bookmark, forKey: Self.key(id))
        result(["id": id, "name": url.lastPathComponent])
      } else {
        // A copy in the app's inbox: read once, then removed.
        let data = try Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        result(["name": url.lastPathComponent, "bytes": FlutterStandardTypedData(bytes: data)])
      }
    } catch {
      result(FlutterError(code: "document", message: error.localizedDescription, details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pending?(nil)
    pending = nil
  }

  /// [body] on the bookmarked file of [id] while its security scope is open;
  /// a stale bookmark (the file moved) is renewed.
  private func withAccess<T>(_ id: String, _ body: (URL) throws -> T) throws -> T {
    guard let bookmark = UserDefaults.standard.data(forKey: Self.key(id)) else {
      throw NSError(
        domain: "tsm", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "the file is not kept on this device"])
    }
    var stale = false
    let url = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
    let ok = url.startAccessingSecurityScopedResource()
    defer { if ok { url.stopAccessingSecurityScopedResource() } }
    if stale, let renewed = try? url.bookmarkData() {
      UserDefaults.standard.set(renewed, forKey: Self.key(id))
    }
    return try body(url)
  }

  private static func coordinatedRead(_ url: URL) throws -> Data {
    var coordinatorError: NSError?
    var read: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) {
      source in
      read = Result { try Data(contentsOf: source) }
    }
    if let coordinatorError { throw coordinatorError }
    return try read.get()
  }

  private static func coordinatedWrite(_ data: Data, to url: URL) throws {
    var coordinatorError: NSError?
    var written: Result<Void, Error> = .failure(CocoaError(.fileWriteUnknown))
    NSFileCoordinator().coordinate(
      writingItemAt: url, options: .forReplacing, error: &coordinatorError
    ) { target in
      written = Result { try data.write(to: target, options: .atomic) }
    }
    if let coordinatorError { throw coordinatorError }
    try written.get()
  }

  private func share(name: String, bytes: Data, _ result: @escaping FlutterResult) {
    guard let top = Self.topController() else {
      result(false)
      return
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shared")
    try? FileManager.default.removeItem(at: folder)
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let file = folder.appendingPathComponent(name)
      try bytes.write(to: file, options: [.atomic, .completeFileProtection])
      let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
      sheet.completionWithItemsHandler = { _, _, _, _ in
        try? FileManager.default.removeItem(at: folder)
      }
      sheet.popoverPresentationController?.sourceView = top.view
      sheet.popoverPresentationController?.sourceRect = CGRect(
        x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
      top.present(sheet, animated: true)
      result(true)
    } catch {
      result(false)
    }
  }

  private static func topController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
    var top = window?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }
}

/// When this build stops starting: the ExpirationDate of the provisioning
/// profile embedded in the app (a free personal team's lasts 7 days, DP-130),
/// as ISO 8601; nil without one (the simulator, a store build).
enum TomSecretsProfile {
  static func expiry() -> String? {
    guard
      let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
      let data = FileManager.default.contents(atPath: path),
      let text = String(data: data, encoding: .isoLatin1),
      let start = text.range(of: "<?xml"),
      let end = text.range(of: "</plist>", range: start.lowerBound..<text.endIndex),
      let plist = String(text[start.lowerBound..<end.upperBound]).data(using: .isoLatin1),
      let dict = try? PropertyListSerialization.propertyList(from: plist, format: nil)
        as? [String: Any],
      let date = dict["ExpirationDate"] as? Date
    else { return nil }
    return ISO8601DateFormatter().string(from: date)
  }
}

/// The clipboard of a copied value: local only (never on the other devices
/// through Universal Clipboard) and expiring after the clipboard timeout, so
/// it goes even when the app is not running to clear it; the clear takes it
/// only while the pasteboard's change count is still the copy's.
enum TomSecretsClipboard {
  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let pasteboard = UIPasteboard.general
    switch call.method {
    case "place":
      let text = args["text"] as? String ?? ""
      let seconds = args["seconds"] as? Int ?? 30
      pasteboard.setItems(
        [[UTType.utf8PlainText.identifier: text]],
        options: [
          .localOnly: true,
          .expirationDate: Date().addingTimeInterval(TimeInterval(max(seconds, 1))),
        ])
      result(pasteboard.changeCount)
    case "clear":
      let generation = args["generation"] as? Int
      if generation != nil && generation != pasteboard.changeCount {
        result(false)
        return
      }
      pasteboard.items = []
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
