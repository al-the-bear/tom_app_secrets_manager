// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

import Foundation

/// Why a host exchange failed.
public enum HostSessionError: Error, Equatable {
  /// The host could not be started.
  case notStarted(String)
  /// The host ended, or wrote what is not native messaging.
  case ended(String)
}

/// Native messaging's framing: a 32-bit length in the machine's byte order,
/// then that many bytes of UTF-8 JSON.
public enum NativeFraming {
  /// The largest frame read from the host (native messaging's 1 MB to the
  /// browser).
  public static let maxFrame = 1024 * 1024

  /// [object] as one frame.
  public static func frame(_ object: [String: Any]) throws -> Data {
    let json = try JSONSerialization.data(withJSONObject: object)
    var length = UInt32(json.count)
    var out = Data(bytes: &length, count: 4)
    out.append(json)
    return out
  }

  /// The length of a frame from its 4-byte header.
  public static func length(_ header: Data) -> Int {
    precondition(header.count == 4)
    var value: UInt32 = 0
    _ = withUnsafeMutableBytes(of: &value) { header.copyBytes(to: $0) }
    return Int(value)
  }
}

/// One `tsm-browser-host` process: a session of the extension. Requests are
/// answered in order, one answer each, so an exchange writes one request
/// and reads frames until the one carrying its id (or the host's refusal
/// of the caller, which carries none).
public final class HostSession {
  private let process: Process
  private let input: FileHandle
  private let output: FileHandle
  private let lock = NSLock()

  /// When the session last exchanged a message.
  public private(set) var lastUsed: Date

  /// Starts [executable] with [arguments] and [environment].
  public init(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    now: Date = Date()
  ) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      throw HostSessionError.notStarted("\(executable.path): \(error.localizedDescription)")
    }
    self.process = process
    self.input = stdin.fileHandleForWriting
    self.output = stdout.fileHandleForReading
    self.lastUsed = now
  }

  /// Whether the host process still runs.
  public var isRunning: Bool { process.isRunning }

  /// Sends [request] and answers the host's answer to it.
  public func exchange(_ request: [String: Any], now: Date = Date()) throws -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    lastUsed = now
    let id = request["id"] as? Int
    do {
      try input.write(contentsOf: NativeFraming.frame(request))
    } catch {
      throw HostSessionError.ended("the host does not read: \(error.localizedDescription)")
    }
    while true {
      let message = try readFrame()
      if let answerId = message["id"] as? Int, answerId == id { return message }
      if message["id"] == nil, message["error"] != nil { return message }
      // An answer to an earlier request nobody waits for: skipped.
    }
  }

  /// Ends the host: its standard input closes, and it exits.
  public func close() {
    try? input.close()
    if process.isRunning {
      DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
        if process.isRunning { process.terminate() }
      }
    }
  }

  private func readExactly(_ count: Int) throws -> Data {
    var data = Data()
    while data.count < count {
      let chunk: Data?
      do {
        chunk = try output.read(upToCount: count - data.count)
      } catch {
        throw HostSessionError.ended("reading the host failed: \(error.localizedDescription)")
      }
      guard let chunk, !chunk.isEmpty else {
        throw HostSessionError.ended("the host ended")
      }
      data.append(chunk)
    }
    return data
  }

  private func readFrame() throws -> [String: Any] {
    let length = NativeFraming.length(try readExactly(4))
    guard length <= NativeFraming.maxFrame else {
      throw HostSessionError.ended("the host wrote a frame of \(length) bytes")
    }
    let body = try readExactly(length)
    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      throw HostSessionError.ended("the host wrote what is not a JSON object")
    }
    return object
  }
}
