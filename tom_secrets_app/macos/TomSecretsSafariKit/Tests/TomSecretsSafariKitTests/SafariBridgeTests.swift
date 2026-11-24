// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The Safari handler's bridge against a fake host (Resources/fake_host.py):
// one host process per session, the requests answered in order, close
// ending it, a host that ends or never starts answered as `unreachable`,
// the host's refusal of the caller passed on, idle sessions ended, and
// where the host and the runtime directory are found in the app bundle.

import Foundation
import XCTest

@testable import TomSecretsSafariKit

final class SafariBridgeTests: XCTestCase {
  private let origin = SafariHostLocation.origin(
    extensionBundleId: "com.althebear.tomSecretsApp.safari")

  private func script() throws -> URL {
    try XCTUnwrap(Bundle.module.url(forResource: "Resources/fake_host", withExtension: "py"))
  }

  private func bridge(
    origin: String? = nil,
    idleLimit: TimeInterval = 300,
    now: @escaping () -> Date = Date.init
  ) throws -> SafariBridge {
    let script = try script()
    let arguments = [script.path, origin ?? self.origin]
    return SafariBridge(
      launch: {
        try HostSession(
          executable: URL(fileURLWithPath: "/usr/bin/python3"),
          arguments: arguments,
          environment: ["TSM_RUNTIME_DIR": "/demo/group/tsm"])
      },
      idleLimit: idleLimit,
      now: now)
  }

  private func answer(_ reply: [String: Any]) throws -> [String: Any] {
    try XCTUnwrap(reply["answer"] as? [String: Any])
  }

  func testOneHostPerSessionAnswersInOrderAndCloses() throws {
    let bridge = try bridge()
    let first = try answer(
      bridge.handle(["session": "a", "request": ["id": 1, "op": "status"]]))
    let second = try answer(
      bridge.handle(["session": "a", "request": ["id": 2, "op": "status"]]))
    let other = try answer(
      bridge.handle(["session": "b", "request": ["id": 1, "op": "status"]]))
    XCTAssertEqual(first["id"] as? Int, 1)
    XCTAssertEqual(first["status"] as? String, "unlocked")
    XCTAssertEqual(first["runtime"] as? String, "/demo/group/tsm")
    XCTAssertEqual(second["id"] as? Int, 2)
    XCTAssertEqual(first["pid"] as? Int, second["pid"] as? Int, "one host per session")
    XCTAssertNotEqual(first["pid"] as? Int, other["pid"] as? Int)
    XCTAssertEqual(bridge.sessionCount, 2)

    XCTAssertEqual(bridge.handle(["session": "a", "close": true])["closed"] as? Bool, true)
    XCTAssertEqual(bridge.sessionCount, 1)
  }

  func testTheHostsAnswerAndItsEndAreTheExtensionsAnswer() throws {
    let bridge = try bridge()
    let refused = try answer(
      bridge.handle(["session": "a", "request": ["id": 1, "op": "nothing"]]))
    XCTAssertEqual((refused["error"] as? [String: Any])?["kind"] as? String, "malformed")

    let ended = try answer(bridge.handle(["session": "a", "request": ["id": 2, "op": "die"]]))
    XCTAssertEqual(ended["id"] as? Int, 2)
    XCTAssertEqual((ended["error"] as? [String: Any])?["kind"] as? String, "unreachable")
    XCTAssertEqual(bridge.sessionCount, 0)

    // The next request of that session starts a new host.
    let again = try answer(bridge.handle(["session": "a", "request": ["id": 3, "op": "status"]]))
    XCTAssertEqual(again["status"] as? String, "unlocked")
  }

  func testTheHostsRefusalOfTheCallerIsPassedOn() throws {
    let bridge = try bridge(origin: "safari-web-extension://com.example.other/")
    let refused = try answer(
      bridge.handle(["session": "a", "request": ["id": 1, "op": "status"]]))
    XCTAssertNil(refused["id"])
    XCTAssertEqual((refused["error"] as? [String: Any])?["reason"] as? String, "origin")
  }

  func testAHostThatCannotStartIsUnreachable() {
    let bridge = SafariBridge(launch: {
      try HostSession(
        executable: URL(fileURLWithPath: "/nonexistent/tsm-browser-host"),
        arguments: [], environment: [:])
    })
    let reply = bridge.handle(["session": "a", "request": ["id": 7, "op": "status"]])
    let answer = reply["answer"] as? [String: Any]
    XCTAssertEqual(answer?["id"] as? Int, 7)
    XCTAssertEqual((answer?["error"] as? [String: Any])?["kind"] as? String, "unreachable")
  }

  func testMalformedMessagesAndIdleSessions() throws {
    var clock = Date(timeIntervalSince1970: 1_000_000)
    let bridge = try bridge(idleLimit: 60, now: { clock })
    XCTAssertNotNil(bridge.handle(["request": ["id": 1]])["error"])
    XCTAssertNotNil(bridge.handle(["session": "a"])["error"])
    _ = bridge.handle(["session": "a", "request": ["id": 1, "op": "status"]])
    XCTAssertEqual(bridge.sessionCount, 1)
    clock = clock.addingTimeInterval(120)
    _ = bridge.handle(["session": "b", "close": true])
    XCTAssertEqual(bridge.sessionCount, 0, "an idle session is ended")
  }

  func testWhereTheHostAndTheRuntimeDirectoryAre() {
    let appex = URL(
      fileURLWithPath:
        "/Applications/Tom Secrets Manager.app/Contents/PlugIns/TomSecretsSafari.appex")
    XCTAssertEqual(
      SafariHostLocation.host(extensionBundle: appex).path,
      "/Applications/Tom Secrets Manager.app/Contents/Resources/tsm/bin/tsm-browser-host")
    XCTAssertEqual(
      SafariHostLocation.runtimeDirectory(
        groupContainer: URL(
          fileURLWithPath: "/Users/demo/Library/Group Containers/ABCDE12345.tom.secrets")
      ).path,
      "/Users/demo/Library/Group Containers/ABCDE12345.tom.secrets/tsm")
    XCTAssertEqual(origin, "safari-web-extension://com.althebear.tomSecretsApp.safari/")
  }

  func testTheFramingIsNativeMessagings() throws {
    let frame = try NativeFraming.frame(["id": 1])
    XCTAssertEqual(NativeFraming.length(frame.prefix(4)), frame.count - 4)
    XCTAssertEqual(frame.count - 4, 8)  // {"id":1}
  }
}
