// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Who started the host (part-browser, "The caller's origin"): Chromium
/// browsers pass the calling extension's origin (`chrome-extension://<id>/`)
/// as the first argument (on Windows a `--parent-window=` follows); Firefox
/// passes the manifest's path and the extension's id. The host serves only
/// the product's own extensions, compiled in (`tom_secrets_client`'s
/// [tomSecretsChromiumExtensionIds] and [tomSecretsFirefoxExtensionId]).
library;

import 'package:tom_secrets_client/admin.dart'
    show tomSecretsChromiumExtensionIds, tomSecretsFirefoxExtensionId;

/// The browser family of a caller.
enum TomSecretsBrowserFamily {
  /// Chrome, Chromium, Edge, Brave and the other Chromium browsers.
  chromium('a Chromium browser'),

  /// Firefox.
  firefox('Firefox');

  const TomSecretsBrowserFamily(this.label);

  /// For the user.
  final String label;
}

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

  /// The extension's origin (Chromium) or id (Firefox), as the browser
  /// passed it.
  final String origin;

  /// The extension's id.
  String get extensionId => family == TomSecretsBrowserFamily.chromium
      ? origin
            .substring('chrome-extension://'.length)
            .replaceAll(RegExp(r'/+$'), '')
      : origin;

  /// Whether it is one of the product's own extensions.
  bool get isProducts => family == TomSecretsBrowserFamily.chromium
      ? tomSecretsChromiumExtensionIds.contains(extensionId)
      : extensionId == tomSecretsFirefoxExtensionId;

  /// The name `hello` gives the host: shown in the approval prompt, never
  /// trusted (the service matches the measured executable and its parent).
  String get clientName =>
      'Tom Secrets Manager browser extension in ${family.label} ($origin)';
}
