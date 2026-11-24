// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Who started the host (part-browser, "The caller's origin"): Chromium
/// browsers pass the calling extension's origin (`chrome-extension://<id>/`)
/// as the first argument (on Windows a `--parent-window=` follows); Firefox
/// passes the manifest's path and the extension's id; in Safari the macOS
/// app's extension handler starts it with the extension's origin
/// (`safari-web-extension://<bundle id>`). The host serves only the
/// product's own extensions, compiled in (`tom_secrets_client`'s
/// [tomSecretsChromiumExtensionIds] and [tomSecretsFirefoxExtensionId], and
/// [tomSecretsSafariExtensionId]).
library;

import 'package:tom_secrets_client/admin.dart'
    show tomSecretsChromiumExtensionIds, tomSecretsFirefoxExtensionId;

/// The browser family of a caller.
enum TomSecretsBrowserFamily {
  /// Chrome, Chromium, Edge, Brave and the other Chromium browsers.
  chromium('a Chromium browser'),

  /// Firefox.
  firefox('Firefox'),

  /// Safari, through the macOS app's Safari Web Extension.
  safari('Safari');

  const TomSecretsBrowserFamily(this.label);

  /// For the user.
  final String label;
}

/// The bundle id of the macOS app's Safari Web Extension
/// (`tom_secrets_app/macos/TomSecretsSafari`).
const String tomSecretsSafariExtensionId = 'com.althebear.tomSecretsApp.safari';

/// The origin scheme the Safari handler passes.
const String tomSecretsSafariOriginScheme = 'safari-web-extension://';

/// The extension that started the host.
final class TomSecretsBrowserCaller {
  /// The extension [origin] of [family].
  const TomSecretsBrowserCaller(this.family, this.origin);

  /// From the host's command-line [arguments], or null when they name no
  /// extension (the host was started by something other than a browser).
  static TomSecretsBrowserCaller? fromArguments(List<String> arguments) {
    for (final a in arguments) {
      if (a.startsWith('chrome-extension://')) {
        return TomSecretsBrowserCaller(TomSecretsBrowserFamily.chromium, a);
      }
      if (a.startsWith(tomSecretsSafariOriginScheme)) {
        return TomSecretsBrowserCaller(TomSecretsBrowserFamily.safari, a);
      }
    }
    // Firefox: <manifest path> <extension id>.
    if (arguments.length >= 2 && arguments[0].endsWith('.json')) {
      return TomSecretsBrowserCaller(
        TomSecretsBrowserFamily.firefox,
        arguments[1],
      );
    }
    return null;
  }

  /// The browser family.
  final TomSecretsBrowserFamily family;

  /// The extension's origin (Chromium, Safari) or id (Firefox), as the
  /// browser passed it.
  final String origin;

  /// The extension's id.
  String get extensionId => switch (family) {
    TomSecretsBrowserFamily.chromium =>
      origin
          .substring('chrome-extension://'.length)
          .replaceAll(RegExp(r'/+$'), ''),
    TomSecretsBrowserFamily.safari =>
      origin
          .substring(tomSecretsSafariOriginScheme.length)
          .replaceAll(RegExp(r'/+$'), ''),
    TomSecretsBrowserFamily.firefox => origin,
  };

  /// Whether it is one of the product's own extensions.
  bool get isProducts => switch (family) {
    TomSecretsBrowserFamily.chromium => tomSecretsChromiumExtensionIds.contains(
      extensionId,
    ),
    TomSecretsBrowserFamily.firefox =>
      extensionId == tomSecretsFirefoxExtensionId,
    TomSecretsBrowserFamily.safari =>
      extensionId == tomSecretsSafariExtensionId,
  };

  /// The name `hello` gives the host: shown in the approval prompt, never
  /// trusted (the service matches the measured executable and its parent).
  String get clientName =>
      'Tom Secrets Manager browser extension in ${family.label} ($origin)';
}
