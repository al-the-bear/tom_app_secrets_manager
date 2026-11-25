// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The mobile app's engine in place of the secrets service (part-mobile: "no
/// secrets service, so the app is its own writer"): the admin requests the
/// screens send, answered in the app's own process over the service's vault
/// set and GitHub opener without an offline cache, so every vault is fetched
/// from GitHub into memory at the unlock and nothing of it is written to the
/// device.
///
/// Answered: `subscribe`, `status`, `unlock` (the master password and the key
/// file; the key files and repository keys pairing delivered come from the
/// keychain), the OS unlock's bundle (the composite key), `unlockStore`,
/// `lock`, `vaultKeys`, `vaultFile`, `save` (written to GitHub at once,
/// merged with a branch another device moved; a system vault refused,
/// BP-40), `reload`, `settings.get` / `settings.set` (the app's refresh
/// interval). Everything a phone does not do (approvals, grants, pairing as
/// the giving side, imports, the ssh-agent) answers `unsupported`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:tom_core_storage/settings.dart'
    show TomSecretStore, TomSecretStoreException;
import 'package:tom_core_storage/tom_core_storage.dart'
    show TomKeyRequiredException;
import 'package:tom_crypto/protected_value.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_service/tom_secrets_service.dart';
import 'mobile_documents.dart';
import 'mobile_kdf_guard.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart'
    show TomSecretsAdminChannel, TomSecretsPreferences;

/// The device preference keys of the mobile app.
abstract final class TomSecretsMobileKeys {
  /// The primary vault's locator, set by the setup (pairing).
  static const primary = 'mobile.primary';

  /// This device's name (`host` dimension, commit messages).
  static const device = 'mobile.device';

  /// The refresh interval, minutes (default 15, at least 5; DP-55).
  static const refreshMinutes = 'mobile.refreshMinutes';

  /// The lock timeout in the background, seconds (default 30; 0 locks at
  /// once).
  static const lockSeconds = 'mobile.lockSeconds';

  /// The clipboard timeout, seconds (default 30).
  static const clipboardSeconds = 'mobile.clipboardSeconds';

  /// `off` when the user turned the biometric unlock off (default on).
  static const biometric = 'mobile.biometric';

  /// The GitHub tokens' expiries the pairing delivered, JSON
  /// (`owner/repository` → ISO 8601).
  static const tokenExpires = 'mobile.tokenExpires';
}

/// The mobile app's settings (device preferences, never synced).
final class TomSecretsMobileSettings {
  /// The settings of [preferences].
  TomSecretsMobileSettings(this.preferences);

  /// The device's preferences.
  final TomSecretsPreferences preferences;

  /// The default refresh interval (DP-55).
  static const defaultRefreshMinutes = 15;

  /// The shortest refresh interval: three vaults every 5 minutes on three
  /// devices stay far below GitHub's shared rate limit (part-mobile).
  static const minRefreshMinutes = 5;

  int _int(String key, int fallback) =>
      int.tryParse(preferences.read(key) ?? '') ?? fallback;

  /// Minutes between refreshes while the app is open and unlocked.
  int get refreshMinutes {
    final v = _int(TomSecretsMobileKeys.refreshMinutes, defaultRefreshMinutes);
    return v < minRefreshMinutes ? minRefreshMinutes : v;
  }

  /// Seconds in the background before the app locks (0: at once).
  int get lockSeconds => _int(TomSecretsMobileKeys.lockSeconds, 30);

  /// Seconds a copied value stays on the clipboard.
  int get clipboardSeconds => _int(TomSecretsMobileKeys.clipboardSeconds, 30);

  /// Whether an unlock with the master password keeps it under the
  /// biometric check (Face ID, Touch ID, the fingerprint), so the next
  /// unlocks need no password (part-mobile; default on).
  bool get biometric =>
      preferences.read(TomSecretsMobileKeys.biometric) != 'off';

  /// Turns the biometric unlock on or off.
  Future<void> setBiometric(bool on) =>
      preferences.write(TomSecretsMobileKeys.biometric, on ? null : 'off');

  /// The days before a GitHub token's expiry its reminders start (as the
  /// desktop's `keyExpiryWarningDays`).
  static const int tokenWarningDays = 14;

  /// The GitHub tokens' expiries the pairing delivered.
  Map<String, DateTime> get pairedTokenExpiries {
    try {
      final json = jsonDecode(
        preferences.read(TomSecretsMobileKeys.tokenExpires) ?? '{}',
      );
      return {
        for (final MapEntry(:key, :value) in (json as Map).entries)
          if (DateTime.tryParse('$value') case final at?) '$key': at.toUtc(),
      };
    } on Object {
      return const {};
    }
  }

  /// Records [expiries] (`owner/repository` → expiry).
  Future<void> setPairedTokenExpiries(Map<String, DateTime> expiries) =>
      preferences.write(
        TomSecretsMobileKeys.tokenExpires,
        jsonEncode({
          for (final MapEntry(:key, :value) in expiries.entries)
            key: value.toUtc().toIso8601String(),
        }),
      );

  /// Sets [key] to [value].
  Future<void> set(String key, int value) => preferences.write(key, '$value');
}

/// The admin channel of the mobile app, answered in-process.
final class TomSecretsMobileEngine implements TomSecretsAdminChannel {
  /// The engine of the primary at [primaryLocator] for [device] on
  /// [platform] (`ios`, `android`), the keys and tokens in [keychain], its
  /// settings in [preferences]; GitHub at [githubBaseUrl] through
  /// [httpClient] (tests).
  TomSecretsMobileEngine({
    required this.primaryLocator,
    required this.device,
    required this.platform,
    required this.keychain,
    required TomSecretsPreferences preferences,
    http.Client? httpClient,
    String githubBaseUrl = 'https://api.github.com',
    DateTime Function()? clock,
    TomSecretsDocuments? documents,
    this.kdfMemoryLimit = defaultKdfMemoryLimit,
    this.unlockRetryEvery = const Duration(seconds: 15),
    this.unlockRetryFor = const Duration(minutes: 10),
  }) : settings = TomSecretsMobileSettings(preferences),
       documentRegistry = TomSecretsDocumentRegistry(preferences),
       _clock = clock ?? DateTime.now {
    _github = TomSecretsGitHubOpener(
      device: device,
      tokens: _token,
      // No offline cache: a phone keeps no copy of a vault (part-mobile).
      cacheDirectory: null,
      baseUrl: githubBaseUrl,
      httpClient: httpClient,
      clock: _clock,
    );
    this.documents = documents;
    _vaults =
        TomSecretsVaultSet(
            opener: TomSecretsKdfGuardedOpener(
              TomSecretsLocatorOpener(
                // Without documents no locator is this phone's: every `file:`
                // vault is another device's.
                file: TomSecretsDocumentOpener(
                  documents: documents ?? const TomSecretsNoDocuments(),
                  registry: documentRegistry,
                  clock: _clock,
                ),
                github: _github,
              ),
              limit: kdfMemoryLimit,
            ),
            clock: _clock,
          )
          ..onPrimaryKeysChanged = _primaryKeysChanged
          // The phone keeps nothing on the disk: a save GitHub cannot take
          // waits in memory (part-mobile, Saving).
          ..keepUnwrittenSaves = true;
  }

  /// The memory a vault's key derivation may take when the device's is not
  /// known: 256 MiB.
  static const int defaultKdfMemoryLimit = 256 << 20;

  /// The most memory a vault's Argon2 may take on this device (bytes); a
  /// vault asking more is refused at the unlock, not opened.
  final int kdfMemoryLimit;

  /// How often an unlock refused for no network is tried again by itself.
  final Duration unlockRetryEvery;

  /// How long it is tried again.
  final Duration unlockRetryFor;

  /// The phone's documents (`file:` vaults), or null.
  late final TomSecretsDocuments? documents;

  /// Which document each of this phone's `file:` vaults is.
  final TomSecretsDocumentRegistry documentRegistry;

  late final TomSecretsGitHubOpener _github;
  Timer? _retry;
  final Map<String, int> _sizes = {};

  /// The primary vault's locator.
  final String primaryLocator;

  /// This device's name.
  final String device;

  /// `ios` or `android`.
  final String platform;

  /// The keychain: key files, repository keys, GitHub tokens.
  final TomSecretStore keychain;

  /// The app's settings.
  final TomSecretsMobileSettings settings;

  final DateTime Function() _clock;
  late final TomSecretsVaultSet _vaults;
  final StreamController<Map<String, Object?>> _events =
      StreamController.broadcast();

  /// The engine's start, in place of the service's (the OS unlock keeps it
  /// with a session item).
  final int start = DateTime.now().millisecondsSinceEpoch;

  bool _closed = false;
  Future<void> _queue = Future<void>.value();

  /// [status] as the screens see it: a store with a save waiting in the
  /// vault set's memory (`keepUnwrittenSaves`) counts it in `notPushed`.
  Map<String, Object?> _stateOf(TomSecretsStoreStatus status) => {
    ...status.toJson(),
    'fetchedBytes': ?_sizes[status.name],
  };

  /// The size of every vault as held now: what the last fetch brought
  /// (part-mobile, Fetch: every unlock fetches them again, on mobile data
  /// too).
  Future<void> _recordSizes() async {
    _sizes.clear();
    for (final s in _vaults.status) {
      try {
        _sizes[s.name] = (await _vaults.vaultFile(s.name)).stored.length;
      } on Object {
        // Not open: no size.
      }
    }
  }

  /// Whether the vaults are closed.
  bool get isLocked => !_vaults.isUnlocked;

  /// The open stores the Android Autofill service answers from (DP-175),
  /// or null while locked.
  Iterable<TomSecretsStore>? get autofillStores =>
      isLocked ? null : _vaults.resolver?.stores;

  /// A login the Android Autofill service saw submitted (`onSaveRequest`):
  /// raised as the `proposal` event, as the desktop's service passes the
  /// browser's and git's (protocol.md 5.5); the Proposals screen saves it
  /// into a personal or shared vault once the user confirms (BP-28).
  void propose({
    required String url,
    required String userName,
    required String password,
    String? title,
  }) => _emit({
    'op': 'proposal',
    'url': url,
    'title': ?title,
    'userName': userName,
    'password': password,
  });

  /// **[C]** Keeps a passkey Credential Manager registered (DP-120): in
  /// the personal or shared vault `tomSecretsPasskeyHome` picks (the one
  /// holding the site's login), in the site's login entry or a new one
  /// (`tomSecretsKeepPasskey`), saved as every edit is (`save`: written to
  /// GitHub at once, else kept in memory as a change not written). Answers
  /// the vault. Refused while locked and without a personal or shared
  /// vault.
  Future<String> keepPasskey(TomSecretsPasskey passkey) async {
    _unlocked();
    final served = _vaults.resolver?.stores ?? const <TomSecretsStore>[];
    final candidates = {
      for (final s in served)
        if (!_isSystem(s.name)) s.name: s.file,
    };
    final store = tomSecretsPasskeyHome(candidates, passkey);
    if (store == null) {
      _refuse('denied', 'no personal or shared vault is open', {
        'reason': 'read_only',
      });
    }
    // Edited on a copy of the held file: the served one changes with the
    // save, as for an edit the screens send.
    final held = await _vaults.vaultFile(store);
    final (credentials, outerKey) = _keysOf(store);
    final file = await _vaults.opener.decode(
      held.location,
      held.stored,
      credentials,
      outerKey: outerKey,
    );
    tomSecretsKeepPasskey(file, passkey);
    final stored = await tomSecretsEncodeStored(
      held.location,
      file,
      outerKey: outerKey,
      like: held.stored,
    );
    await request('save', {
      'store': store,
      'bytes': base64.encode(stored),
      'baseRevision': held.revision,
    });
    return store;
  }

  Future<T> _serial<T>(Future<T> Function() body) {
    final result = _queue.then((_) => body());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  void _emit(Map<String, Object?> event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  /// The token for [vault]'s repository: the keychain's
  /// (`tsm.github-token.<owner>:<repository>`, delivered by pairing or
  /// entered), else the one the primary lists for it.
  Future<String?> _token(TomSecretsGitHubLocator vault) async {
    final kept = await keychain.read(
      tomSecretsGitHubTokenHandle(vault.owner, vault.repository),
    );
    if (kept != null && kept.isNotEmpty) return kept;
    for (final v in _vaults.listed) {
      final listed = v.githubToken;
      if (listed == null) continue;
      try {
        final l = TomSecretsVaultLocator.parse(v.locator);
        if (l is TomSecretsGitHubLocator &&
            l.repositorySlug == vault.repositorySlug) {
          return listed;
        }
      } on TomSecretsLocatorException {
        continue;
      }
    }
    return null;
  }

  static Never _refuse(
    String kind,
    String message, [
    Map<String, Object?> details = const {},
  ]) => throw TomSecretsAdminException(kind, message, details: details);

  void _unlocked() {
    if (isLocked) _refuse('locked', 'unlock first');
  }

  @override
  Future<void> unlockWithBundle(String vault, TomSecretsUnlockBundle bundle) =>
      _serial(() async {
        if (!isLocked) return;
        await _unlockOrRetry(
          () => TomSecretsHeldKeys.ofBundle(bundle),
          bundle: true,
        );
      });

  /// Unlocks with [keys]; refused for no network, tries again by itself
  /// every [unlockRetryEvery] for [unlockRetryFor] (part-mobile, Edge cases:
  /// the network returns), until it opens, the user locks or the time is up.
  Future<void> _unlockOrRetry(
    TomSecretsHeldKeys Function() keys, {
    bool bundle = false,
  }) async {
    try {
      await _unlock(keys(), bundle: bundle);
    } on TomSecretsAdminException catch (e) {
      if (e.kind == TomSecretsStoreState.offline.wireName) {
        _retryLater(keys, bundle: bundle);
      }
      rethrow;
    }
  }

  void _retryLater(TomSecretsHeldKeys Function() keys, {required bool bundle}) {
    _retry?.cancel();
    final until = _clock().add(unlockRetryFor);
    var trying = false;
    _retry = Timer.periodic(unlockRetryEvery, (timer) {
      if (_closed || !isLocked || _clock().isAfter(until)) {
        timer.cancel();
        return;
      }
      if (trying) return;
      trying = true;
      unawaited(
        _serial(() async {
          if (!isLocked || !timer.isActive) return;
          try {
            await _unlock(keys(), bundle: bundle);
            timer.cancel();
          } on Object {
            // Still no network (or refused for good: the user sees it at
            // the next attempt): tried again at the next tick.
          }
        }).whenComplete(() => trying = false),
      );
    });
  }

  /// The keys of [given] completed from the keychain for the primary: its
  /// key file (unless a composite key holds it) and a `.tsmx` primary's
  /// repository key.
  Future<TomSecretsHeldKeys> _withKeychainKeys(TomSecretsHeldKeys given) async {
    final locator = TomSecretsVaultLocator.parse(primaryLocator);
    final keyFile = given.keyFile == null && given.compositeKey == null
        ? await keychain.read(locator.keyFileHandle)
        : null;
    final outerKey =
        given.outerKey == null &&
            locator.fileName.endsWith(tomSecretsOuterSuffix)
        ? await keychain.read(locator.repositoryKeyHandle)
        : null;
    if (keyFile == null && outerKey == null) return given;
    return TomSecretsHeldKeys(
      password: given.password,
      keyFile: keyFile == null
          ? given.keyFile
          : TomProtectedValue.fromBytes(base64.decode(keyFile)),
      outerKey: outerKey == null
          ? given.outerKey
          : TomProtectedValue.of(outerKey),
      compositeKey: given.compositeKey,
    );
  }

  Future<void> _unlock(TomSecretsHeldKeys given, {bool bundle = false}) async {
    final keys = await _withKeychainKeys(given);
    try {
      await _openPrimary(keys);
      await _vaults.openStores(
        machine: TomSecretsMachine(host: device, platform: platform),
      );
    } on KdbxInvalidKeyException {
      _vaults.lock();
      _refuse(
        'denied',
        bundle
            ? 'the kept unlock no longer opens the vault'
            : 'the master password is wrong',
        {'reason': 'bad_password'},
      );
    } on TomKeyRequiredException {
      _vaults.lock();
      _refuse('denied', 'the repository key is missing', {
        'reason': 'bad_password',
      });
    } on TomSecretsAdminException {
      _vaults.lock();
      rethrow;
    } on TomSecretsVaultTooHeavyException catch (e) {
      _vaults.lock();
      _refuse('unavailable', e.message, {'reason': 'kdf_memory'});
    } on Object catch (e) {
      _vaults.lock();
      final failure = tomSecretsFetchFailureOf(e);
      if (failure != null) {
        final kind = TomSecretsStoreState.offlineFor(failure).wireName;
        _refuse(
          kind,
          kind == 'token_expired'
              ? 'GitHub refused this device\'s token: it expired or was '
                    'revoked. Make a new one and set this device up again '
                    '(below), by pairing or by hand.'
              : 'No connection: the vaults are only on GitHub. The unlock '
                    'is tried again by itself when the network is back.',
          {
            'reason': 'no_copy',
            'stores': [primaryLocator],
          },
        );
      }
      rethrow;
    }
    _retry?.cancel();
    _retry = null;
    await _takeNextKeys();
    await _recordSizes();
    _emit({'op': 'unlocked'});
  }

  /// Opens the primary with [keys]; when they no longer open it because
  /// another device switched a guided rotation of its keys
  /// (part-key-rotation), with the next keys this phone took into its
  /// keychain before (`<handle>.next`), which are its keys from then on.
  Future<void> _openPrimary(TomSecretsHeldKeys keys) async {
    try {
      await _vaults.openPrimary(primaryLocator, keys);
    } on Object catch (e) {
      if (e is! KdbxInvalidKeyException && e is! TomKeyRequiredException) {
        rethrow;
      }
      final next = await _withNextKeychainKeys(keys);
      if (next == null) rethrow;
      try {
        await _vaults.openPrimary(primaryLocator, next);
      } on Object {
        next.dispose();
        rethrow;
      }
      keys.dispose();
      await _keepPrimaryKeys(next);
    }
  }

  /// The phone taking the keys of the guided rotations running in the
  /// primary (part-key-rotation, step 1), at every unlock, refresh and save
  /// of the primary, as a desktop service does: the primary's own next keys
  /// into the keychain beside its keys (`<handle>.next`), where the unlock
  /// and the refresh find them after another device switched; the ids of
  /// the keys it holds into its device record, so the desktop's Keys screen
  /// stops listing it as missing. A finished rotation's next keys leave the
  /// keychain. A primary GitHub cannot take now is written at the next
  /// refresh.
  Future<void> _takeNextKeys() async {
    final primary = _vaults.primary;
    if (primary == null) return;
    final next = TomSecretsPrimaryNextKeys.of(primary.file);
    _vaults.primaryNextKeys = next;
    final ids = <String>[];
    final locator = TomSecretsVaultLocator.parse(primaryLocator);
    try {
      if (next != null) {
        if (next.keyFile != null) {
          await keychain.write(
            '${locator.keyFileHandle}.next',
            base64.encode(next.keyFile!),
          );
        }
        if (next.outerKey != null) {
          await keychain.write(
            '${locator.repositoryKeyHandle}.next',
            next.outerKey!,
          );
        }
        // Recorded only once the keychain holds them.
        ids.addAll(
          tomSecretsVaultKeyIds(keyFile: next.keyFile, outerKey: next.outerKey),
        );
      } else {
        await keychain.delete('${locator.keyFileHandle}.next');
        await keychain.delete('${locator.repositoryKeyHandle}.next');
      }
    } on TomSecretStoreException {
      // Without the keychain the phone does not claim the primary's keys.
      ids.clear();
    }
    await _vaults.adoptPrimaryNext();
    if (tomSecretsTakeNextKeys(
      primary.file,
      device: device,
      now: _clock().toUtc(),
      primaryKeyIds: ids,
    )) {
      try {
        await _vaults.writePrimary();
      } on Object {
        // Out of reach: the edit waits in the held copy
        // (primaryWritePending) and the next refresh writes it.
      }
    }
  }

  /// **[C]** The primary's keys the vault set took up during a refresh in
  /// the background, kept in the keychain at the next refresh in the
  /// foreground (the background writes nothing to the device, DP-151).
  TomSecretsHeldKeys? _keysToKeep;

  /// Whether a refresh in the background runs.
  bool _inBackground = false;

  Future<void> _primaryKeysChanged(TomSecretsHeldKeys keys) async {
    if (_inBackground) {
      _keysToKeep = keys;
      return;
    }
    _keysToKeep = null;
    await _keepPrimaryKeys(keys);
  }

  /// Keeps the primary's [keys] in the keychain, where the unlock takes
  /// them: its key file and a `.tsmx` primary's newest repository key.
  Future<void> _keepPrimaryKeys(TomSecretsHeldKeys keys) async {
    final locator = TomSecretsVaultLocator.parse(primaryLocator);
    try {
      final keyFile = keys.keyFile;
      if (keyFile == null) {
        await keychain.delete(locator.keyFileHandle);
      } else {
        await keychain.write(
          locator.keyFileHandle,
          keyFile.withRevealed(base64.encode),
        );
      }
      final outer = keys.newestOuterKey;
      if (outer != null && locator.fileName.endsWith(tomSecretsOuterSuffix)) {
        await keychain.write(locator.repositoryKeyHandle, outer);
      }
    } on TomSecretStoreException {
      // Held until the lock; the next unlock asks again.
    }
  }

  /// The primary's keys [held] with the next keys this phone took into its
  /// keychain, or null when it holds none (or an OS unlock's composite key
  /// binds the old key file).
  Future<TomSecretsHeldKeys?> _withNextKeychainKeys(
    TomSecretsHeldKeys held,
  ) async {
    final locator = TomSecretsVaultLocator.parse(primaryLocator);
    final String? keyFile;
    final String? outerKey;
    try {
      keyFile = await keychain.read('${locator.keyFileHandle}.next');
      outerKey = await keychain.read('${locator.repositoryKeyHandle}.next');
    } on TomSecretStoreException {
      return null;
    }
    final hasKeyFile = keyFile != null && keyFile.isNotEmpty;
    final hasOuter = outerKey != null && outerKey.isNotEmpty;
    if (!hasKeyFile && !hasOuter) return null;
    if (hasKeyFile && held.compositeKey != null) return null;
    return TomSecretsHeldKeys(
      password: held.password == null
          ? null
          : TomProtectedValue.of(held.password!.reveal()),
      keyFile: hasKeyFile
          ? TomProtectedValue.fromBytes(base64.decode(keyFile))
          : (held.keyFile == null
                ? null
                : TomProtectedValue.fromBytes(
                    held.keyFile!.withRevealed(Uint8List.fromList),
                  )),
      outerKey: hasOuter
          ? TomProtectedValue.of(outerKey)
          : (held.outerKey == null
                ? null
                : TomProtectedValue.of(held.outerKey!.reveal())),
      compositeKey: held.compositeKey == null
          ? null
          : TomProtectedValue.fromBytes(
              held.compositeKey!.withRevealed(Uint8List.fromList),
            ),
    );
  }

  /// Closes every vault: nothing of them stays on the device.
  void lock() {
    // The vault set's lock drops the saves that wait.
    // Keys a background refresh took up are dropped; the next unlock takes
    // them from the keychain's next keys.
    _keysToKeep = null;
    _nextKeysDue = false;
    _retry?.cancel();
    _retry = null;
    _sizes.clear();
    if (isLocked) return;
    _vaults.lock();
    _emit({'op': 'locked'});
  }

  /// Fetches every vault whose branch moved (one conditional request per
  /// vault) and tells the screens; [force] fetches all (pull to refresh).
  ///
  /// **[C]** [background]: the read-only refresh while the app's process
  /// lives in the background with the vaults in memory (DP-131, DP-151): it
  /// only brings the copies held in memory up to date. It writes nothing,
  /// neither to GitHub (the saves that wait, the primary's own edits: a
  /// refresh is skipped while the primary has one) nor to the device (the
  /// rotation keys go into the keychain at the next refresh in the
  /// foreground).
  Future<TomSecretsRefreshReport> refresh({
    bool force = false,
    bool background = false,
  }) => _serial(() async {
    if (isLocked) return const TomSecretsRefreshReport();
    if (background && _vaults.primaryWritePending) {
      return const TomSecretsRefreshReport();
    }
    _vaults.refreshInterval = Duration(minutes: settings.refreshMinutes);
    final waiting = {
      for (final s in _vaults.status)
        if (s.notPushed > 0) s.name,
    };
    final TomSecretsRefreshReport report;
    _inBackground = background;
    try {
      // In the background nothing is written: the saves that wait stay.
      report = await _vaults.refresh(force: force, writeUnwritten: !background);
    } finally {
      _inBackground = false;
    }
    if (report.reopened.contains(_vaults.primaryName) ||
        _vaults.primaryWritePending) {
      _nextKeysDue = true;
    }
    if (background) {
      final changed = report.reopened.toSet();
      if (changed.isNotEmpty) await _recordSizes();
      _report(report, waiting, changed);
      return report;
    }
    if (_keysToKeep case final keys?) {
      _keysToKeep = null;
      await _keepPrimaryKeys(keys);
    }
    if (_nextKeysDue) {
      _nextKeysDue = false;
      await _takeNextKeys();
    }
    final changed = report.reopened.toSet();
    if (changed.isNotEmpty) await _recordSizes();
    _report(report, waiting, changed);
    return report;
  });

  /// Whether the primary was fetched or written since its rotation keys
  /// were last taken ([_takeNextKeys], which the next refresh in the
  /// foreground does).
  bool _nextKeysDue = false;

  /// Tells the screens a refresh's states and the stores [changed].
  void _report(
    TomSecretsRefreshReport report,
    Set<String> waiting,
    Set<String> changed,
  ) {
    for (final s in report.states) {
      _emit({'op': 'store_state', ..._stateOf(s)});
    }
    for (final name in waiting.difference(
      report.states.map((s) => s.name).toSet(),
    )) {
      if (_vaults.statusOf(name) case final s?) {
        _emit({'op': 'store_state', ..._stateOf(s)});
      }
    }
    for (final name in changed) {
      _emit({
        'op': 'store_changed',
        'store': name,
        'revision': ?_vaults.statusOf(name)?.revision,
      });
    }
  }

  /// The credentials and outer key of [name] as the vault set holds them.
  (Credentials, String?) _keysOf(String name) {
    final keys =
        ((_plain(_vaults.vaultKeys(stores: [name])) as List).single
                as Map)['keys']!
            as Map;
    final keyFile = keys['keyFile'];
    final compositeKey = keys['compositeKey'];
    return (
      tomSecretsVaultCredentials(
        password: keys['password'] as String?,
        keyFile: keyFile is String ? base64.decode(keyFile) : null,
        compositeKey: compositeKey is String
            ? base64.decode(compositeKey)
            : null,
      ),
      keys['outerKey'] as String?,
    );
  }

  /// Adds the phone's [document] as the vault [name] opened with
  /// [password] (part-mobile, `file:` vaults): listed in the primary under
  /// a locator naming this device, so its keys are kept where every vault's
  /// are; then opened. Answers the vault's locator. Refused: a wrong
  /// password (`denied`, `bad_password`), a name already taken (`denied`,
  /// `exists`), a file too heavy for the device, the primary not writable
  /// now (no network: `offline`).
  Future<String> addDocumentVault({
    required String name,
    required TomSecretsPickedDocument document,
    required String password,
  }) async {
    final docs = documents;
    if (docs == null) _refuse('unsupported', 'this device has no files');
    _unlocked();
    final primary = _vaults.primaryName!;
    if (_vaults.status.any((s) => s.name == name) ||
        _vaults.listed.any((k) => k.name == name)) {
      _refuse('denied', 'a vault named $name is there already', {
        'reason': 'exists',
      });
    }
    final locator = documentRegistry.locatorFor(device, document.name);
    await documentRegistry.put(locator, document.id);
    try {
      final stored = await docs.read(document.id);
      try {
        await _vaults.opener.decode(
          locator,
          stored,
          tomSecretsVaultCredentials(password: password),
        );
      } on KdbxInvalidKeyException {
        _refuse('denied', 'the password does not open ${document.name}', {
          'reason': 'bad_password',
        });
      } on TomSecretsVaultTooHeavyException catch (e) {
        _refuse('unavailable', e.message, {'reason': 'kdf_memory'});
      }
      final held = await _vaults.vaultFile(primary);
      final (credentials, outerKey) = _keysOf(primary);
      final file = await _vaults.opener.decode(
        held.location,
        held.stored,
        credentials,
        outerKey: outerKey,
      );
      TomSecretsPrimaryVaults(file, primaryLocator: primaryLocator).put(
        TomSecretsVaultKeys(name: name, locator: locator, password: password),
      );
      await request('save', {
        'store': primary,
        'bytes': base64.encode(
          await tomSecretsEncodeStored(
            held.location,
            file,
            outerKey: outerKey,
            like: held.stored,
          ),
        ),
        'baseRevision': held.revision,
      });
      if (_vaults.hasUnwritten(primary)) {
        _vaults.dropUnwritten(primary);
        _refuse(
          'offline',
          'the primary could not be written to GitHub: add the file when '
              'the network is back',
          {'reason': 'no_copy'},
        );
      }
    } on Object {
      await documentRegistry.forget(locator);
      rethrow;
    }
    await refresh(force: true);
    return locator;
  }

  /// Every vault served, by name, with its locator (the settings' list).
  Map<String, String> get locators => {
    for (final s in _vaults.status) s.name: s.locator ?? '',
  };

  /// The GitHub tokens' expiries (`owner/repository` → UTC): the one GitHub
  /// reports on its answers, else the one the pairing delivered.
  Map<String, DateTime> get tokenExpiries => {
    ...settings.pairedTokenExpiries,
    ..._github.tokenExpiries,
  };

  /// The reminders due (`status.expiring`): this device's GitHub tokens,
  /// from two weeks before they expire (as the desktop's, DP-85).
  List<Map<String, Object?>> _expiring() {
    final now = _clock();
    return [
      for (final MapEntry(key: slug, value: at) in tokenExpiries.entries)
        ?TomSecretsKeyDate(
          kind: 'github_token',
          key: 'github-token:$slug',
          expiresAt: at,
          firstDays: TomSecretsMobileSettings.tokenWarningDays,
        ).dueAt(now)?.toJson(),
    ];
  }

  /// Whether [store] is a system vault (its metadata, as the vault set
  /// serves it): read-only on a phone (BP-40).
  bool _isSystem(String store) {
    final served = _vaults.resolver?.stores
        .where((s) => s.name == store)
        .firstOrNull;
    return served?.metadata.kind == TomSecretsVaultKind.system;
  }

  Map<String, Object?> _statusReport() => {
    'op': 'statusReport',
    'locked': isLocked,
    'lockMode': 'b',
    'protocol': 1,
    'service': {'version': 'mobile', 'start': start},
    'stores': [for (final s in _vaults.status) _stateOf(s)],
    'expiring': _expiring(),
    'admins': 1,
    'hardening': const <String, Object?>{},
    // A save GitHub cannot take waits in memory (part-mobile, Saving).
    if (!isLocked) 'keepsUnwritten': true,
  };

  static Object? _plain(Object? value) => switch (value) {
    TomSecretsSecretSlot slot => slot.read(
      (bytes) => slot.isBase64 ? base64.encode(bytes) : utf8.decode(bytes),
    ),
    Map m => {for (final e in m.entries) e.key as String: _plain(e.value)},
    List l => [for (final x in l) _plain(x)],
    _ => value,
  };

  @override
  Future<Map<String, Object?>> request(
    String op, [
    Map<String, Object?> args = const {},
  ]) async {
    if (_closed) _refuse('closed', 'the engine is closed');
    switch (op) {
      case 'subscribe':
        return {'op': 'ok'};
      case 'status':
        return _statusReport();
      case 'unlock':
        final password = args['password'];
        final keyFile = args['keyFile'];
        if (password is! String) {
          _refuse('malformed', 'unlock needs a password', {
            'reason': 'password',
          });
        }
        TomSecretsHeldKeys keys() => TomSecretsHeldKeys.of(
          password: password,
          keyFile: keyFile is String ? base64.decode(keyFile) : null,
        );
        await _serial(() async {
          if (!isLocked) return;
          await _unlockOrRetry(keys);
        });
        return {'op': 'ok'};
      case 'unlockStore':
        _unlocked();
        final store = args['store'];
        final password = args['password'];
        if (store is! String || password is! String) {
          _refuse('malformed', 'store and password', {'reason': 'store'});
        }
        final keyFile = args['keyFile'];
        try {
          await _serial(
            () => _vaults.unlockStore(
              store,
              TomSecretsHeldKeys.of(
                password: password,
                keyFile: keyFile is String ? base64.decode(keyFile) : null,
              ),
              machine: TomSecretsMachine(host: device, platform: platform),
            ),
          );
        } on KdbxInvalidKeyException {
          _refuse('denied', 'the password is wrong', {
            'reason': 'bad_password',
          });
        } on StateError {
          _refuse('not_found', 'no store $store');
        }
        return {'op': 'ok'};
      case 'lock':
        lock();
        return {'op': 'ok'};
      case 'vaultKeys':
        _unlocked();
        final stores = (args['stores'] as List?)?.cast<String>();
        try {
          return {
            'op': 'vaultKeySet',
            'stores': _plain(_vaults.vaultKeys(stores: stores)),
            'unserved': [
              for (final v in _vaults.unserved)
                {'store': v.name, 'location': v.locator},
            ],
          };
        } on StateError catch (e) {
          _refuse('not_found', 'no open store ${e.message}', {
            'store': e.message,
          });
        }
      case 'vaultFile':
        _unlocked();
        final store = args['store'];
        if (store is! String) {
          _refuse('malformed', 'vaultFile names a store', {'reason': 'store'});
        }
        try {
          // A save that waits is what the screens edit on: the vault set
          // answers it.
          final file = await _vaults.vaultFile(store);
          return {
            'op': 'vaultFileData',
            'store': store,
            'location': file.location,
            'revision': file.revision,
            if (!file.served) 'served': false,
            'bytes': base64.encode(file.stored),
          };
        } on StateError catch (e) {
          _refuse('not_found', 'no store ${e.message}');
        } on KdbxInvalidKeyException {
          _refuse('needs_unlock', 'the listed keys do not open $store', {
            'store': store,
          });
        }
      case 'save':
        _unlocked();
        final store = args['store'];
        final bytes = args['bytes'];
        final base = args['baseRevision'];
        if (store is! String || bytes is! String) {
          _refuse('malformed', 'save carries store and bytes', {
            'reason': 'save',
          });
        }
        if (args['keys'] != null) {
          _refuse('unsupported', 'keys are rotated in the desktop app');
        }
        if (_isSystem(store)) {
          _refuse('denied', 'a system vault is read-only on a phone', {
            'reason': 'read_only',
          });
        }
        final stored = base64.decode(bytes);
        try {
          // GitHub out of reach: the vault set keeps the change in memory
          // (a later save of the same vault replaces it; it carries the
          // first one's base) and answers it pending.
          final result = await _serial(() async {
            final saved = await _vaults.save(
              store,
              stored,
              baseRevision: base as String?,
            );
            if (!saved.pending && store == _vaults.primaryName) {
              await _takeNextKeys();
            }
            return saved;
          });
          _emit({
            'op': 'store_changed',
            'store': store,
            'revision': result.revision,
          });
          return {'op': 'ok', if (result.pending) 'pending': true};
        } on TomSecretsSaveException catch (e) {
          _refuse(e.kind, e.message, {'reason': ?e.reason});
        } finally {
          for (final s in _vaults.status) {
            if (s.name == store) _emit({'op': 'store_state', ..._stateOf(s)});
          }
        }
      case 'vault.recipients':
        // A shared vault's recipients file (part-sharing): read so the
        // session takes up the vault's new keys after another member
        // re-keyed it. Joining by a location, adding and removing members
        // are the desktop app's (BP-32).
        _unlocked();
        final store = args['store'];
        if (store is! String || args['location'] != null) {
          _refuse(
            'unsupported',
            'a phone reads the recipients file of a '
                'vault it lists only; join shared vaults in the desktop app',
          );
        }
        final location = _vaults.locatorOf(store);
        if (location == null) _refuse('not_found', 'no store $store');
        final ({Uint8List bytes, String revision})? read;
        try {
          read = await _vaults.recipientsAt(location);
        } on TomSecretsSaveException catch (e) {
          _refuse(e.kind, e.message, {'reason': ?e.reason});
        } on Object catch (e) {
          final failure = tomSecretsFetchFailureOf(e);
          if (failure == null) rethrow;
          _refuse(
            TomSecretsStoreState.offlineFor(failure).wireName,
            'the recipients file cannot be read now',
            {
              'stores': [store],
            },
          );
        }
        if (read == null) {
          _refuse('not_found', 'the vault has no recipients file', {
            'reason': 'no_recipients',
          });
        }
        return {
          'op': 'recipientsData',
          'store': store,
          'location': location,
          'revision': read.revision,
          'bytes': base64.encode(read.bytes),
        };
      case 'inbox.list' || 'inbox.read' || 'inbox.delete':
        // The inbox folders of shared vaults (part-sharing): a phone
        // receives shares (lists, reads and deletes its packages, and the
        // expired ones); sending them is the desktop app's (BP-32).
        _unlocked();
        return _inbox(op, args);
      case 'reload':
        _unlocked();
        await refresh(force: true);
        final offline = [
          for (final s in _vaults.status)
            if (s.state == TomSecretsStoreState.offline ||
                s.state == TomSecretsStoreState.tokenExpired)
              s.name,
        ];
        if (offline.isNotEmpty) {
          _refuse('offline', 'GitHub could not be reached', {
            'stores': offline,
          });
        }
        return {'op': 'ok'};
      case 'settings.get':
        return {
          'op': 'deviceSettings',
          'device': {
            'refreshMinutes': settings.refreshMinutes,
            'serviceLock': {
              'mode': 'idle',
              'idleSeconds': settings.lockSeconds,
            },
          },
          'cliApprovals': false,
          'stores': [for (final s in _vaults.status) s.name],
        };
      case 'settings.set':
        final device = (args['device'] as Map?)?.cast<String, Object?>();
        final minutes = device?['refreshMinutes'];
        if (minutes is int) {
          await settings.set(
            TomSecretsMobileKeys.refreshMinutes,
            minutes < TomSecretsMobileSettings.minRefreshMinutes
                ? TomSecretsMobileSettings.minRefreshMinutes
                : minutes,
          );
        }
        return {'op': 'deviceSettingsWritten', 'nextUnlock': const <String>[]};
      default:
        _refuse('unsupported', '$op is not done on a phone');
    }
  }

  Future<Map<String, Object?>> _inbox(
    String op,
    Map<String, Object?> args,
  ) async {
    final store = args['store'];
    if (store is! String) {
      _refuse('malformed', '$op names a store', {'reason': 'inbox'});
    }
    try {
      switch (op) {
        case 'inbox.list':
          final files = await _vaults.inbox(store);
          return {
            'op': 'inbox',
            'store': store,
            'files': [
              for (final f in files)
                {'member': f.member, 'name': f.name, 'revision': f.revision},
            ],
          };
        case 'inbox.read':
          final member = args['member'];
          final name = args['name'];
          if (member is! String || name is! String) {
            _refuse('malformed', 'inbox.read names a member and a name', {
              'reason': 'inbox',
            });
          }
          final file = await _vaults.inboxFile(store, member, name);
          if (file == null) {
            _refuse('not_found', 'the package is gone', {'reason': 'inbox'});
          }
          return {
            'op': 'inboxFile',
            'store': store,
            'member': member,
            'name': name,
            'revision': file.revision,
            'bytes': base64.encode(file.bytes),
          };
        default:
          final files = args['files'];
          if (files is! List ||
              files.any(
                (f) =>
                    f is! Map || f['member'] is! String || f['name'] is! String,
              )) {
            _refuse('malformed', 'inbox.delete carries files (member, name)', {
              'reason': 'inbox',
            });
          }
          await _vaults.inboxDelete(store, [
            for (final f in files.cast<Map<Object?, Object?>>())
              (member: f['member']! as String, name: f['name']! as String),
          ]);
          return {'op': 'ok'};
      }
    } on TomSecretsSaveException catch (e) {
      _refuse(e.kind, e.message, {'reason': ?e.reason});
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    lock();
    await _events.close();
  }

  /// Test support: the bytes held for [store].
  Future<Uint8List> heldBytesForTest(String store) async =>
      (await _vaults.vaultFile(store)).stored;
}
