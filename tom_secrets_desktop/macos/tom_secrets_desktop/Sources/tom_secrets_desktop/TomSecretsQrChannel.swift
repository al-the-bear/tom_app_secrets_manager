// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

import Cocoa
import CoreMedia
import FlutterMacOS
import ScreenCaptureKit

/// `tom_secrets_desktop/qr`: the pictures a TOTP's QR code is read from.
///
/// - `clipboardImage`: the pasteboard's picture as RGBA pixels, or null when
///   it holds none;
/// - `captureScreen` (macOS 14+): the window or display the user picks in
///   ScreenCaptureKit's own picker (`SCContentSharingPicker`), captured by a
///   stream on the picked content (the capture the picker allows) whose
///   first frame is kept in memory; null when cancelled.
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

/// One capture through ScreenCaptureKit's picker: the picker is shown, a
/// stream on the content the user picks delivers one frame, and the stream
/// and the picker are closed again.
@available(macOS 14.0, *)
final class TomSecretsScreenPicker: NSObject, SCContentSharingPickerObserver, SCStreamOutput,
  SCStreamDelegate
{
  init(done: @escaping (Any?) -> Void) {
    self.done = done
  }

  private let done: (Any?) -> Void
  private var finished = false
  private var stream: SCStream?
  private let frames = DispatchQueue(label: "tom_secrets_desktop.qr.frames")

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
      if let stream = self.stream {
        stream.stopCapture { _ in }
        self.stream = nil
      }
      let picker = SCContentSharingPicker.shared
      picker.remove(self)
      picker.isActive = false
      self.done(answer)
    }
  }

  private func failed(_ what: String, _ error: Error?) -> FlutterError {
    FlutterError(
      code: "capture-failed",
      message: error.map { "\(what): \($0.localizedDescription)" } ?? what,
      details: nil)
  }

  func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
    finish(nil)
  }

  func contentSharingPicker(
    _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?
  ) {
    DispatchQueue.main.async {
      guard !self.finished, self.stream == nil else { return }
      let configuration = SCStreamConfiguration()
      let scale = CGFloat(filter.pointPixelScale)
      configuration.width = max(1, Int(filter.contentRect.width * scale))
      configuration.height = max(1, Int(filter.contentRect.height * scale))
      configuration.pixelFormat = kCVPixelFormatType_32BGRA
      configuration.showsCursor = false
      configuration.queueDepth = 3
      let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
      do {
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.frames)
      } catch {
        self.finish(self.failed("the screen could not be captured", error))
        return
      }
      self.stream = capture
      capture.startCapture { error in
        if let error {
          self.finish(self.failed("the screen could not be captured", error))
        }
      }
    }
  }

  func contentSharingPickerStartDidFailWithError(_ error: Error) {
    finish(failed("the screen picker could not open", error))
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    finish(failed("the screen capture stopped", error))
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen, sampleBuffer.isValid,
      let pixels = sampleBuffer.imageBuffer
    else { return }
    // A frame without new content (status idle) carries no picture yet.
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let raw = attachments.first?[.status] as? Int,
      let status = SCFrameStatus(rawValue: raw), status != .complete
    {
      return
    }
    finish(TomSecretsScreenPicker.bgra(pixels))
  }

  /// The pixels of a BGRA frame, rows packed, as the channel answers them.
  static func bgra(_ buffer: CVPixelBuffer) -> [String: Any]? {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(buffer) else {
      return nil
    }
    var bytes = Data(count: width * height * 4)
    bytes.withUnsafeMutableBytes { out in
      for y in 0..<height {
        memcpy(out.baseAddress! + y * width * 4, base + y * stride, width * 4)
      }
    }
    defer { bytes.resetBytes(in: 0..<bytes.count) }
    return [
      "width": width, "height": height, "order": "bgra",
      "pixels": FlutterStandardTypedData(bytes: bytes),
    ]
  }
}
