// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

import Cocoa
import FlutterMacOS
import ServiceManagement

/// The macOS half of tom_secrets_desktop's own platform code:
///
/// - `tom_secrets_desktop/capture` (DP-33): keeps the app's window out of
///   screenshots and screen sharing by setting `NSWindow.sharingType` to
///   `.none` (and back to `.readOnly`);
/// - `tom_secrets_desktop/clipboard`: the protected copy of
///   `tom_reusable_ui`'s `TomDesktopClipboardPort` (`placeConcealed`,
///   `clearIfUnchanged`);
/// - `tom_secrets_desktop/login`: starting the app at login (DP-30) through
///   `SMAppService.mainApp` (macOS 13 and later), in place of a plugin that
///   needs a package added to the app's runner by hand (DP-32);
/// - `tom_secrets_desktop/session`: the desktop session's screen lock and
///   sleep, which the app senses for the service (part-service): the
///   distributed notification `com.apple.screenIsLocked` and NSWorkspace's
///   `willSleepNotification`, each sent to Dart as `event` with
///   `screenLocked` or `sleep`.
public class TomSecretsDesktopPlugin: NSObject, FlutterPlugin {
  private weak var registrar: FlutterPluginRegistrar?

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "tom_secrets_desktop/capture",
      binaryMessenger: registrar.messenger)
    let instance = TomSecretsDesktopPlugin(registrar: registrar)
    registrar.addMethodCallDelegate(instance, channel: channel)
    TomSecretsClipboard.register(messenger: registrar.messenger)
    TomSecretsLoginItem.register(messenger: registrar.messenger)
    TomSecretsSessionEvents.register(messenger: registrar.messenger)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setCaptureExcluded":
      guard let excluded = call.arguments as? Bool else {
        result(FlutterError(code: "bad_arguments", message: "a bool", details: nil))
        return
      }
      // The window the Flutter view is in; before it is attached, the app's
      // main window.
      guard let window = registrar?.view?.window ?? NSApp.mainWindow ?? NSApp.windows.first
      else {
        result(false)
        return
      }
      window.sharingType = excluded ? .none : .readOnly
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// The protected copy: the text placed with the nspasteboard.org markers, so
/// clipboard managers do not record it, and cleared only while the
/// pasteboard still holds it (its change count unchanged).
enum TomSecretsClipboard {
  static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
  static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

  static var channel: FlutterMethodChannel?

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "tom_secrets_desktop/clipboard", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any]
      let board = NSPasteboard.general
      switch call.method {
      case "placeConcealed":
        guard let text = args?["text"] as? String else {
          result(FlutterError(code: "bad-args", message: "text", details: nil))
          return
        }
        board.clearContents()
        board.declareTypes([.string, concealed, transient], owner: nil)
        board.setString(text, forType: .string)
        board.setData(Data(), forType: concealed)
        board.setData(Data(), forType: transient)
        result(board.changeCount)
      case "clearIfUnchanged":
        guard let count = args?["changeCount"] as? Int else {
          result(FlutterError(code: "bad-args", message: "changeCount", details: nil))
          return
        }
        if board.changeCount == count {
          board.clearContents()
          result(true)
        } else {
          result(false)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    TomSecretsClipboard.channel = channel
  }
}

/// Starting the app at login with `SMAppService.mainApp` (macOS 13+):
/// `isEnabled` answers a bool, `setEnabled` (a bool) registers or
/// unregisters and answers whether it is enabled afterwards; an older macOS
/// answers `unsupported`.
enum TomSecretsLoginItem {
  static var channel: FlutterMethodChannel?

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "tom_secrets_desktop/login", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard #available(macOS 13.0, *) else {
        result(FlutterError(code: "unsupported", message: "macOS 13 or later", details: nil))
        return
      }
      let service = SMAppService.mainApp
      switch call.method {
      case "isEnabled":
        result(service.status == .enabled)
      case "setEnabled":
        guard let on = call.arguments as? Bool else {
          result(FlutterError(code: "bad-args", message: "a bool", details: nil))
          return
        }
        do {
          if on {
            try service.register()
          } else {
            try service.unregister()
          }
          result(service.status == .enabled)
        } catch {
          result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    TomSecretsLoginItem.channel = channel
  }
}

/// The session's screen lock and sleep, sent to Dart (`event`).
enum TomSecretsSessionEvents {
  static var channel: FlutterMethodChannel?
  static var observers: [NSObjectProtocol] = []

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "tom_secrets_desktop/session", binaryMessenger: messenger)
    TomSecretsSessionEvents.channel = channel
    let send: (String) -> Void = { event in
      DispatchQueue.main.async {
        TomSecretsSessionEvents.channel?.invokeMethod("event", arguments: event)
      }
    }
    observers.append(
      DistributedNotificationCenter.default().addObserver(
        forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil,
        queue: .main
      ) { _ in send("screenLocked") })
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
      ) { _ in send("sleep") })
  }
}
