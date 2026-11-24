// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The Safari Web Extension's native side (part-browser, Safari): Safari
// hands each `browser.runtime.sendNativeMessage` of the extension to this
// handler, which bridges it to `tsm-browser-host` in the app's tools folder
// (TomSecretsSafariKit). The handler runs sandboxed: the host it starts
// inherits the sandbox and reaches the service through the client socket
// the service offers in the App Group container.

import Foundation
import SafariServices
import os

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
  private static let log = Logger(subsystem: "com.althebear.tomSecretsApp.safari", category: "host")

  /// One bridge per extension process: its sessions live as long as it.
  private static let bridge = SafariBridge(launch: launchHost)

  private static func launchHost() throws -> HostSession {
    let bundle = Bundle.main
    var environment = ProcessInfo.processInfo.environment
    if let group = bundle.object(forInfoDictionaryKey: "TSMAppGroup") as? String,
      !group.hasPrefix("."),
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: group)
    {
      environment["TSM_RUNTIME_DIR"] =
        SafariHostLocation.runtimeDirectory(groupContainer: container).path
    } else {
      log.error("no App Group: the service cannot be reached from Safari")
    }
    return try HostSession(
      executable: SafariHostLocation.host(extensionBundle: bundle.bundleURL),
      arguments: [
        SafariHostLocation.origin(
          extensionBundleId: bundle.bundleIdentifier ?? "com.althebear.tomSecretsApp.safari")
      ],
      environment: environment)
  }

  func beginRequest(with context: NSExtensionContext) {
    let item = context.inputItems.first as? NSExtensionItem
    let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
    // A host may wait for an unlock or an approval: off the caller's thread.
    DispatchQueue.global(qos: .userInitiated).async {
      let reply = Self.bridge.handle(message)
      let response = NSExtensionItem()
      response.userInfo = [SFExtensionMessageKey: reply]
      context.completeRequest(returningItems: [response], completionHandler: nil)
    }
  }
}
