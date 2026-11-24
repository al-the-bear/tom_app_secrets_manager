// swift-tools-version: 5.9
// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The core of the Safari Web Extension's handler (part-browser, Safari):
// the extension's messages bridged to `tsm-browser-host`, one host process
// per session, over native messaging's framing. The extension target
// (`../TomSecretsSafari`, in Runner.xcodeproj) compiles these sources too;
// this package exists for `swift test`.

import PackageDescription

let package = Package(
  name: "TomSecretsSafariKit",
  platforms: [.macOS("12.0")],
  products: [
    .library(name: "TomSecretsSafariKit", targets: ["TomSecretsSafariKit"])
  ],
  targets: [
    .target(name: "TomSecretsSafariKit"),
    .testTarget(
      name: "TomSecretsSafariKitTests",
      dependencies: ["TomSecretsSafariKit"],
      resources: [.copy("Resources")]
    ),
  ]
)
