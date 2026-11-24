// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

import Foundation

/// The extension's messages, bridged to the browser host (the extension's
/// `safari.ts` is the other side):
///
/// - `{session, request}`: the request sent to the session's host process,
///   started on the session's first request; answered `{answer}`.
/// - `{session, close: true}`: the session's host ends; answered
///   `{closed: true}`.
///
/// A host that cannot be started, or ends, is answered as the host's own
/// refusal (`unreachable`) for that request. Sessions idle longer than
/// [idleLimit] are ended at the next message.
public final class SafariBridge {
  /// Starts a host process for a new session.
  public typealias Launch = () throws -> HostSession

  private let launch: Launch
  private let idleLimit: TimeInterval
  private let now: () -> Date
  private var sessions: [String: HostSession] = [:]
  private let lock = NSLock()

  /// A bridge starting hosts with [launch].
  public init(
    launch: @escaping Launch,
    idleLimit: TimeInterval = 300,
    now: @escaping () -> Date = Date.init
  ) {
    self.launch = launch
    self.idleLimit = idleLimit
    self.now = now
  }

  /// The sessions with a running host.
  public var sessionCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return sessions.count
  }

  /// Answers one message of the extension.
  public func handle(_ message: [String: Any]) -> [String: Any] {
    guard let session = message["session"] as? String, !session.isEmpty else {
      return ["error": ["kind": "malformed", "message": "a message names its session"]]
    }
    endIdle()
    if message["close"] as? Bool == true {
      lock.lock()
      let host = sessions.removeValue(forKey: session)
      lock.unlock()
      host?.close()
      return ["closed": true]
    }
    guard let request = message["request"] as? [String: Any] else {
      return ["error": ["kind": "malformed", "message": "a message carries a request or close"]]
    }
    let host: HostSession
    do {
      host = try hostFor(session)
    } catch {
      return ["answer": unreachable(request, "the browser host could not be started: \(error)")]
    }
    do {
      return ["answer": try host.exchange(request, now: now())]
    } catch {
      lock.lock()
      sessions.removeValue(forKey: session)
      lock.unlock()
      host.close()
      return ["answer": unreachable(request, "the browser host ended: \(error)")]
    }
  }

  private func hostFor(_ session: String) throws -> HostSession {
    lock.lock()
    defer { lock.unlock() }
    if let running = sessions[session], running.isRunning { return running }
    let started = try launch()
    sessions[session] = started
    return started
  }

  private func endIdle() {
    let cutoff = now().addingTimeInterval(-idleLimit)
    lock.lock()
    let idle = sessions.filter { $0.value.lastUsed < cutoff }
    for key in idle.keys { sessions.removeValue(forKey: key) }
    lock.unlock()
    for host in idle.values { host.close() }
  }

  private func unreachable(_ request: [String: Any], _ message: String) -> [String: Any] {
    var answer: [String: Any] = ["error": ["kind": "unreachable", "message": message]]
    if let id = request["id"] { answer["id"] = id }
    return answer
  }
}

/// Where the handler finds the host and the service, from the extension's
/// bundle inside the app (`<App>.app/Contents/PlugIns/<ext>.appex`).
public enum SafariHostLocation {
  /// The browser host in the app's tools folder, beside the service, where
  /// the service recognises it (protocol.md 5.5).
  public static func host(extensionBundle: URL) -> URL {
    extensionBundle
      .deletingLastPathComponent()  // PlugIns
      .deletingLastPathComponent()  // Contents
      .appendingPathComponent("Resources/tsm/bin/tsm-browser-host")
  }

  /// The runtime directory in the App Group container: the client socket
  /// the service offers there (the extension's sandbox reaches no other).
  public static func runtimeDirectory(groupContainer: URL) -> URL {
    groupContainer.appendingPathComponent("tsm")
  }

  /// The origin the host is started with: the extension's bundle id.
  public static func origin(extensionBundleId: String) -> String {
    "safari-web-extension://\(extensionBundleId)/"
  }
}
