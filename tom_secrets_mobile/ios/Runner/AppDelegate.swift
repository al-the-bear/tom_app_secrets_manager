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
      default: result(FlutterMethodNotImplemented)
      }
    }
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
