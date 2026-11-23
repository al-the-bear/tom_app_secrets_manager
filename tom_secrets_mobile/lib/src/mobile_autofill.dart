// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Android Autofill service's Dart side (part-os-integration, DP-175):
/// which logins answer a request, and the two ways the service gets them.
///
/// - **Matching** ([tomSecretsAutofillLogins]): in a browser, the page's
///   web domain by the browser extension's rules (part-browser, URL
///   matching); in an app, the entries naming its package
///   (`androidapp://<package>` in `URL` or a `KP2A_URL_*` field). Only the
///   login entries of personal and shared vaults: a system vault is never
///   offered outside the app (DP-44, as for the browser and macOS).
/// - **Package names are not proof:** a login found by the app's package is
///   checked against the Digital Asset Links of the entry's web domain
///   ([TomSecretsAssetLinks]): when the site lists the app with the
///   requesting app's signing certificate, it is verified; else the dataset
///   says "unverified app".
/// - **From the app's memory:** while the app runs unlocked, the service's
///   native activity asks it over [tomSecretsAutofillChannelName] (`state`,
///   then `logins` after BiometricPrompt).
/// - **Fetching itself:** when the app's process holds no unlocked vault,
///   the native activity starts `autofillMain` (lib/main.dart), the app's
///   own unlock on an engine of its own: the vaults fetched through
///   GitHub's REST API and opened in memory, the logins answered, everything
///   dropped when the activity ends. Without network it says so.
/// - **Passkeys** (`mobile_passkeys.dart`): the same channel answers the
///   Credential Manager provider's `passkey` requests while the app runs
///   unlocked, and hands it the passkey identities.
/// - **Saving:** the service's `onSaveRequest` opens the app with the login,
///   which becomes a proposal (`proposal` event, the Proposals screen):
///   saved into a personal or shared vault once the user confirms (BP-28).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:tom_secrets_core/tom_secrets_core.dart';

/// The channel between the Android Autofill service and the app.
const String tomSecretsAutofillChannelName = 'tom_secrets_mobile/autofill';

/// What the system asks logins for.
final class TomSecretsAutofillRequest {
  /// A request of the app [packageName] (a browser's [webDomain] and
  /// [webScheme] when the form is in a page); [certificates] are the
  /// SHA-256 fingerprints of the requesting app's signing certificates
  /// (upper-case hex with colons, as Digital Asset Links write them).
  const TomSecretsAutofillRequest({
    required this.packageName,
    this.webDomain,
    this.webScheme,
    this.certificates = const [],
  });

  /// The request the native side sent.
  factory TomSecretsAutofillRequest.fromMap(Map<Object?, Object?> m) =>
      TomSecretsAutofillRequest(
        packageName: m['packageName'] as String? ?? '',
        webDomain: (m['webDomain'] as String?)?.trim().isEmpty ?? true
            ? null
            : m['webDomain'] as String,
        webScheme: m['webScheme'] as String?,
        certificates: [
          for (final c in (m['certificates'] as List? ?? const [])) '$c',
        ],
      );

  /// The requesting app.
  final String packageName;

  /// The page's domain, when the form is in a browser.
  final String? webDomain;

  /// The page's scheme (`https`), when the browser tells it.
  final String? webScheme;

  /// The requesting app's signing certificates.
  final List<String> certificates;

  /// What the user is told the logins are for.
  String get target => webDomain ?? packageName;
}

/// A login that answers a request: what fills the fields and what the
/// dataset shows.
final class TomSecretsAutofillLogin {
  /// The login [entryId] titled [title].
  const TomSecretsAutofillLogin({
    required this.entryId,
    required this.title,
    required this.userName,
    required this.password,
    required this.byPackage,
    this.verified = false,
    this.webHost,
  });

  final String entryId;
  final String title;
  final String userName;
  final String password;

  /// Found by the app's package, not by a web domain.
  final bool byPackage;

  /// For a [byPackage] login: the site's Digital Asset Links name the app
  /// with its signing certificate.
  final bool verified;

  /// For a [byPackage] login: the entry's web host checked for its links.
  final String? webHost;

  /// The dataset's line.
  String get label {
    final name = title.isEmpty ? userName : title;
    final user = userName.isEmpty || userName == name ? '' : ' ($userName)';
    final warning = byPackage && !verified ? ' · unverified app' : '';
    return '$name$user$warning';
  }

  TomSecretsAutofillLogin verifiedAs(bool v) => TomSecretsAutofillLogin(
    entryId: entryId,
    title: title,
    userName: userName,
    password: password,
    byPackage: byPackage,
    verified: v,
    webHost: webHost,
  );

  /// The native side's form.
  Map<String, Object?> toMap() => {
    'entryId': entryId,
    'label': label,
    'userName': userName,
    'password': password,
  };
}

/// The logins of [stores] (personal and shared, [isSystem] left out) that
/// answer [request], the closest first; not yet verified.
List<TomSecretsAutofillLogin> tomSecretsAutofillLogins(
  Iterable<TomSecretsStore> stores,
  TomSecretsAutofillRequest request,
) {
  final entries = [
    for (final s in stores)
      if (s.metadata.kind != TomSecretsVaultKind.system) ...s.entries,
  ];
  TomSecretsAutofillLogin login(
    TomSecretsIndexedEntry e, {
    required bool byPackage,
    String? webHost,
  }) => TomSecretsAutofillLogin(
    entryId: '${e.store}/~${tomSecretsUuidHex(e.entry.uuid)}',
    title: e.entry.label ?? '',
    userName: e.entry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '',
    password: e.entry.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '',
    byPackage: byPackage,
    webHost: webHost,
  );

  final domain = request.webDomain;
  if (domain != null) {
    final scheme = request.webScheme ?? 'https';
    return [
      for (final m in tomSecretsMatchLogins(entries, '$scheme://$domain/'))
        login(m.entry, byPackage: false),
    ];
  }
  final app = 'androidapp://${request.packageName.toLowerCase()}';
  final out = <TomSecretsAutofillLogin>[];
  for (final e in entries) {
    if (e.isOverlay) continue;
    final type = TomSecretsEntryType.of(
      e.entry.getString(TomSecretsEntryFields.type)?.getText(),
    );
    if (type != TomSecretsEntryType.login) continue;
    final rule = TomSecretsUrlMatchRule.of(
      e.entry.getString(TomSecretsEntryFields.urlMatch)?.getText(),
    );
    if (rule == TomSecretsUrlMatchRule.never) continue;
    final urls = tomSecretsEntryUrls(e.entry);
    if (!urls.any((u) => u.trim().toLowerCase() == app)) continue;
    final web = urls
        .map(TomSecretsSiteUrl.parse)
        .whereType<TomSecretsSiteUrl>()
        .firstOrNull;
    out.add(login(e, byPackage: true, webHost: web?.host));
  }
  out.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  return out;
}

/// Digital Asset Links (`https://<host>/.well-known/assetlinks.json`): which
/// apps a site lets fill its logins (`delegate_permission/common.get_login_creds`).
/// A site's answer is kept for the process; one that cannot be read
/// verifies nothing.
final class TomSecretsAssetLinks {
  /// Links read through [client], each within [timeout].
  TomSecretsAssetLinks({
    http.Client? client,
    this.timeout = const Duration(seconds: 3),
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// How long one site may take.
  final Duration timeout;

  final Map<String, Future<List<Map<String, Object?>>>> _statements = {};

  /// Whether [host] lists [packageName] signed with one of [certificates].
  Future<bool> verifies(
    String host,
    String packageName,
    List<String> certificates,
  ) async {
    if (certificates.isEmpty) return false;
    final wanted = {for (final c in certificates) c.toUpperCase()};
    final statements = await (_statements[host] ??= _read(host));
    for (final s in statements) {
      final relations = (s['relation'] as List? ?? const []).cast<Object?>();
      if (!relations.contains('delegate_permission/common.get_login_creds') &&
          !relations.contains('delegate_permission/common.handle_all_urls')) {
        continue;
      }
      final target = (s['target'] as Map?)?.cast<String, Object?>();
      if (target == null ||
          target['namespace'] != 'android_app' ||
          target['package_name'] != packageName) {
        continue;
      }
      final prints = (target['sha256_cert_fingerprints'] as List? ?? const [])
          .map((p) => '$p'.toUpperCase());
      if (prints.any(wanted.contains)) return true;
    }
    return false;
  }

  Future<List<Map<String, Object?>>> _read(String host) async {
    try {
      final response = await _client
          .get(Uri.https(host, '/.well-known/assetlinks.json'))
          .timeout(timeout);
      if (response.statusCode != 200) return const [];
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      return json is List
          ? [for (final s in json.whereType<Map>()) s.cast<String, Object?>()]
          : const [];
    } on Object {
      return const [];
    }
  }

  /// [logins] with the package matches checked.
  Future<List<TomSecretsAutofillLogin>> check(
    List<TomSecretsAutofillLogin> logins,
    TomSecretsAutofillRequest request,
  ) => Future.wait([
    for (final l in logins)
      if (!l.byPackage || l.webHost == null)
        Future.value(l)
      else
        verifies(
          l.webHost!,
          request.packageName,
          request.certificates,
        ).then(l.verifiedAs),
  ]);
}

/// What the app answers the service over the channel, from the vaults it
/// holds: [stores] null while locked.
final class TomSecretsAutofillResponder {
  /// A responder over [stores] (the open stores, or null while locked),
  /// checking package matches with [links].
  TomSecretsAutofillResponder({required this.stores, required this.links});

  /// The open stores now, or null while locked.
  final Iterable<TomSecretsStore>? Function() stores;

  /// The Digital Asset Links checker.
  final TomSecretsAssetLinks links;

  /// The channel's call [method] with [arguments]: `state` →
  /// `{unlocked}`; `logins` → the matching logins (`[]` while locked).
  Future<Object?> handle(String method, Object? arguments) async {
    switch (method) {
      case 'state':
        return {'unlocked': stores() != null};
      case 'logins':
        final open = stores();
        if (open == null) return const <Object?>[];
        final request = TomSecretsAutofillRequest.fromMap(
          arguments as Map<Object?, Object?>? ?? const {},
        );
        final found = await links.check(
          tomSecretsAutofillLogins(open, request),
          request,
        );
        return [for (final l in found) l.toMap()];
      default:
        throw MissingPluginException(method);
    }
  }
}

/// The running app's side of the service's channel: the service asks it
/// (`state`, `logins`, `proposal`); it asks the platform for a proposal the
/// app was opened with, whether the service is on, and opens the system's
/// picker of autofill services.
abstract interface class TomSecretsAutofillPlatform {
  /// Answers the service's calls with [handler] (null: none).
  void setHandler(
    Future<Object?> Function(String method, Object? arguments)? handler,
  );

  /// The login the app was opened with from `onSaveRequest`, once; null
  /// without one.
  Future<Map<String, Object?>?> takeProposal();

  /// Whether Tom Secrets Manager is the device's autofill service; null
  /// where there is none (iOS, Android before 8).
  Future<bool?> serviceEnabled();

  /// Opens the system's choice of the autofill service
  /// (`ACTION_REQUEST_SET_AUTOFILL_SERVICE`).
  Future<void> openSettings();

  /// **[C]** Hands the Credential Manager provider the passkey
  /// [identities] it lists without unlocking (relying party, user name,
  /// credential id; never a key), after every unlock and change; `[]` when
  /// the device is set up again.
  Future<void> setPasskeyIdentities(List<Map<String, Object?>> identities);
}

/// [TomSecretsAutofillPlatform] over [tomSecretsAutofillChannelName].
final class TomSecretsChannelAutofill implements TomSecretsAutofillPlatform {
  /// The platform side over [channel].
  const TomSecretsChannelAutofill({
    MethodChannel channel = const MethodChannel(tomSecretsAutofillChannelName),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  void setHandler(
    Future<Object?> Function(String method, Object? arguments)? handler,
  ) => _channel.setMethodCallHandler(
    handler == null ? null : (call) => handler(call.method, call.arguments),
  );

  @override
  Future<Map<String, Object?>?> takeProposal() async {
    try {
      return (await _channel.invokeMapMethod<String, Object?>('takeProposal'));
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<bool?> serviceEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('serviceEnabled');
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> openSettings() => _channel.invokeMethod<void>('openSettings');

  @override
  Future<void> setPasskeyIdentities(
    List<Map<String, Object?>> identities,
  ) async {
    try {
      await _channel.invokeMethod<void>('passkeyIdentities', identities);
    } on MissingPluginException {
      // No provider on this platform.
    }
  }
}

/// The channel of the unlock activity (`autofillMain`'s engine).
const String tomSecretsAutofillUnlockChannelName =
    'tom_secrets_mobile/autofill_unlock';

/// The unlock activity's side: what it was started for, and how the Dart
/// side ends it.
abstract interface class TomSecretsAutofillUnlockPlatform {
  /// The request the locked dataset was chosen for.
  Future<TomSecretsAutofillRequest> request();

  /// Ends it with [logins] filled as datasets.
  Future<void> done(List<TomSecretsAutofillLogin> logins);

  /// Ends it without filling.
  Future<void> cancel();
}

/// [TomSecretsAutofillUnlockPlatform] over
/// [tomSecretsAutofillUnlockChannelName].
final class TomSecretsChannelAutofillUnlock
    implements TomSecretsAutofillUnlockPlatform {
  /// The platform side over [channel].
  const TomSecretsChannelAutofillUnlock({
    MethodChannel channel = const MethodChannel(
      tomSecretsAutofillUnlockChannelName,
    ),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<TomSecretsAutofillRequest> request() async =>
      TomSecretsAutofillRequest.fromMap(
        await _channel.invokeMapMethod<Object?, Object?>('request') ?? const {},
      );

  @override
  Future<void> done(List<TomSecretsAutofillLogin> logins) =>
      _channel.invokeMethod<void>('done', {
        'logins': [for (final l in logins) l.toMap()],
      });

  @override
  Future<void> cancel() => _channel.invokeMethod<void>('cancel');
}
