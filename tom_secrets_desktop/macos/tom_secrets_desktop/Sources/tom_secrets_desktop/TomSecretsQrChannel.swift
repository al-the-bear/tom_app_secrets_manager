// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

import Cocoa
import FlutterMacOS
import ScreenCaptureKit

/// `tom_secrets_desktop/qr`: the pictures a TOTP's QR code is read from.
///
/// - `clipboardImage`: the pasteboard's picture as RGBA pixels, or null when
///   it holds none;
/// - `captureScreen` (macOS 14+): the window or display the user picks in
///   ScreenCaptureKit's own picker (`SCContentSharingPicker`), captured once
///   by `SCScreenshotManager` into memory; null when cancelled.
///
/// Both answer `{width, height, pixels, order: "rgba"}`; nothing is written
/// to a file.
enum TomSecretsQrChannel {
  static var channel: FlutterMethodChannel?
  static var picker: AnyObject?

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "tom_secrets_desktop/qr", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "clipboardImage":
        guard let image = NSImage(pasteboard: NSPasteboard.general),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
          result(nil)
          return
        }
        result(rgba(cg))
      case "captureScreen":
        guard #available(macOS 14.0, *) else {
          result(
            FlutterError(
              code: "unsupported", message: "reading the screen needs macOS 14 or later",
              details: nil))
          return
        }
        if picker != nil {
          result(
            FlutterError(code: "busy", message: "a capture is already open", details: nil))
          return
        }
        let screen = TomSecretsScreenPicker { answer in
          picker = nil
          result(answer)
        }
        picker = screen
        screen.start()
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    TomSecretsQrChannel.channel = channel
  }

  /// The pixels of [image] drawn into an sRGB RGBA buffer.
  static func rgba(_ image: CGImage) -> [String: Any]? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }
    var bytes = Data(count: width * height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }
    defer { bytes.resetBytes(in: 0..<bytes.count) }
    return [
      "width": width, "height": height, "order": "rgba",
      "pixels": FlutterStandardTypedData(bytes: bytes),
    ]
  }
}

/// One capture through ScreenCaptureKit's picker: the picker is shown, the
/// content the user picks is captured once, and the picker is closed again.
@available(macOS 14.0, *)
final class TomSecretsScreenPicker: NSObject, SCContentSharingPickerObserver {
  init(done: @escaping (Any?) -> Void) {
    self.done = done
  }

  private let done: (Any?) -> Void
  private var finished = false

  func start() {
    let picker = SCContentSharingPicker.shared
    var configuration = SCContentSharingPickerConfiguration()
    configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
    if let own = Bundle.main.bundleIdentifier {
      configuration.excludedBundleIDs = [own]
    }
    picker.defaultConfiguration = configuration
    picker.add(self)
    picker.isActive = true
    picker.present()
  }

  private func finish(_ answer: Any?) {
    DispatchQueue.main.async {
      guard !self.finished else { return }
      self.finished = true
      let picker = SCContentSharingPicker.shared
      picker.remove(self)
      picker.isActive = false
      self.done(answer)
    }
  }

  func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
    finish(nil)
  }

  func contentSharingPicker(
    _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?
  ) {
    let configuration = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    configuration.width = max(1, Int(filter.contentRect.width * scale))
    configuration.height = max(1, Int(filter.contentRect.height * scale))
    configuration.showsCursor = false
    SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
      image, error in
      if let image {
        self.finish(TomSecretsQrChannel.rgba(image))
      } else {
        self.finish(
          FlutterError(
            code: "capture-failed",
            message: error.map { "the screen could not be captured: \($0.localizedDescription)" }
              ?? "the screen could not be captured",
            details: nil))
      }
    }
  }

  func contentSharingPickerStartDidFailWithError(_ error: Error) {
    finish(
      FlutterError(
        code: "picker-failed",
        message: "the screen picker could not open: \(error.localizedDescription)", details: nil))
  }
}
