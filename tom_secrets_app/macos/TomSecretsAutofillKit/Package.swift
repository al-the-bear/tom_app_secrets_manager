// swift-tools-version: 5.9
// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The core of the macOS AutoFill provider (part-os-integration, DP-50): the
// snapshot opened with CryptoKit, its entries, matching a service
// identifier like the browser, the one-time codes. The extension target
// (`../TomSecretsAutofill`, in Runner.xcodeproj) compiles these sources
// too; this package exists for `swift test`.

import PackageDescription

let package = Package(
  name: "TomSecretsAutofillKit",
  platforms: [.macOS("12.0")],
  products: [
    .library(name: "TomSecretsAutofillKit", targets: ["TomSecretsAutofillKit"])
  ],
  targets: [
    .target(name: "TomSecretsAutofillKit"),
    .testTarget(
      name: "TomSecretsAutofillKitTests",
      dependencies: ["TomSecretsAutofillKit"],
      resources: [.copy("Resources")]
    ),
  ]
)
