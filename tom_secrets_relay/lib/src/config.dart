// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// **[C]** The relay's own settings (part-relay, DP-65, DP-141): the
/// `relay:` section of the server's configuration, beside
/// `tom_core_server`'s own keys (`port`, `host`, ...). Every limit of the
/// relay has its default here; the configuration names only what differs.
library;

/// Who may put mailbox items and open approval links.
enum TomSecretsRelayMode {
  /// Anyone, limited per address and per recipient.
  open,

  /// Only holders of an instance token: the default (DP-141).
  token,
}

/// A setting that cannot be read.
final class TomSecretsRelayConfigException implements Exception {
  /// The setting [key] is wrong, told by [message].
  const TomSecretsRelayConfigException(this.key, this.message);

  /// The setting, as a dotted path under `relay`.
  final String key;

  /// For the operator.
  final String message;

  @override
  String toString() => 'relay.$key: $message';
}

/// The relay's settings.
final class TomSecretsRelayConfig {
  /// The settings; every argument defaults to part-relay's numbers.
  const TomSecretsRelayConfig({
    this.mode = TomSecretsRelayMode.token,
    this.tokens = const {},
    this.deny = const [],
    this.allow = const [],
    this.trustedProxies = const ['127.0.0.1', '::1'],
    this.storageDirectory = 'relay-data',
    this.requestsPerSecond = 10,
    this.requestsPerMinute = 120,
    this.requestsPerDay = 2000,
    this.blockDurations = const [
      Duration(hours: 24),
      Duration(hours: 48),
      Duration(days: 7),
    ],
    this.blockMemory = const Duration(days: 90),
    this.nameplatesPerHour = 10,
    this.nameplateLifetime = const Duration(minutes: 10),
    this.pairingFrameBytes = 64 * 1024,
    this.pairingChannelBytes = 1024 * 1024,
    this.linksPerToken = 10,
    this.linkFrameBytes = 64 * 1024,
    this.linkAloneTimeout = const Duration(hours: 24),
    this.putsPerHour = 30,
    this.itemBytes = 1024 * 1024,
    this.itemsPerRecipient = 200,
    this.bytesPerRecipient = 50 * 1024 * 1024,
    this.maxExpiry = const Duration(days: 30),
    this.challengesPerHour = 20,
    this.proofLifetime = const Duration(minutes: 5),
    this.expiryInterval = const Duration(minutes: 10),
  });

  /// The settings of the `relay` section [map] (null: every default).
  /// Throws [TomSecretsRelayConfigException] for a value that cannot be
  /// read.
  factory TomSecretsRelayConfig.fromMap(Map<Object?, Object?>? map) {
    final m = map ?? const {};
    const d = TomSecretsRelayConfig();
    Map<Object?, Object?> section(String key) {
      final v = m[key];
      if (v == null) return const {};
      if (v is Map) return v;
      throw TomSecretsRelayConfigException(key, 'a section is expected');
    }

    int number(Map<Object?, Object?> s, String path, String key, int def) {
      final v = s[key];
      if (v == null) return def;
      final n = v is int ? v : int.tryParse('$v');
      if (n == null || n <= 0) {
        throw TomSecretsRelayConfigException(
          '$path$key',
          'a positive whole number is expected, not "$v"',
        );
      }
      return n;
    }

    List<String> strings(String key) {
      final v = m[key];
      if (v == null) return const [];
      if (v is List) return [for (final e in v) '$e'];
      if (v is String) {
        return [
          for (final e in v.split(','))
            if (e.trim().isNotEmpty) e.trim(),
        ];
      }
      throw TomSecretsRelayConfigException(key, 'a list is expected');
    }

    final modeText = m['mode']?.toString() ?? d.mode.name;
    final mode = TomSecretsRelayMode.values
        .where((v) => v.name == modeText)
        .firstOrNull;
    if (mode == null) {
      throw TomSecretsRelayConfigException(
        'mode',
        '"$modeText" is no mode: token (the default) or open',
      );
    }

    final tokens = <String, String>{};
    final t = m['tokens'];
    if (t is Map) {
      for (final e in t.entries) {
        final token = '${e.value}'.trim();
        if (token.length < 16) {
          throw TomSecretsRelayConfigException(
            'tokens.${e.key}',
            'an instance token has at least 16 characters',
          );
        }
        tokens['${e.key}'] = token;
      }
    } else if (t != null) {
      throw TomSecretsRelayConfigException(
        'tokens',
        'a map of names to tokens is expected (one token per team or user)',
      );
    }

    final dos = section('dos');
    final pairing = section('pairing');
    final link = section('link');
    final mailbox = section('mailbox');
    final proof = section('proof');
    final blocks = dos['blockHours'];
    List<Duration> blockDurations = d.blockDurations;
    if (blocks != null) {
      if (blocks is! List || blocks.isEmpty) {
        throw const TomSecretsRelayConfigException(
          'dos.blockHours',
          'a list of hours is expected (the first, second, third block, ...)',
        );
      }
      blockDurations = [
        for (final b in blocks)
          Duration(hours: number({'h': b}, 'dos.blockHours', 'h', 1)),
      ];
    }

    return TomSecretsRelayConfig(
      mode: mode,
      tokens: tokens,
      deny: strings('deny'),
      allow: strings('allow'),
      trustedProxies: m.containsKey('trustedProxies')
          ? strings('trustedProxies')
          : d.trustedProxies,
      storageDirectory: m['storage']?.toString() ?? d.storageDirectory,
      requestsPerSecond: number(dos, 'dos.', 'perSecond', d.requestsPerSecond),
      requestsPerMinute: number(dos, 'dos.', 'perMinute', d.requestsPerMinute),
      requestsPerDay: number(dos, 'dos.', 'perDay', d.requestsPerDay),
      blockDurations: blockDurations,
      blockMemory: Duration(
        days: number(dos, 'dos.', 'rememberDays', d.blockMemory.inDays),
      ),
      nameplatesPerHour: number(
        pairing,
        'pairing.',
        'nameplatesPerHour',
        d.nameplatesPerHour,
      ),
      nameplateLifetime: Duration(
        minutes: number(
          pairing,
          'pairing.',
          'minutes',
          d.nameplateLifetime.inMinutes,
        ),
      ),
      pairingFrameBytes: number(
        pairing,
        'pairing.',
        'frameBytes',
        d.pairingFrameBytes,
      ),
      pairingChannelBytes: number(
        pairing,
        'pairing.',
        'channelBytes',
        d.pairingChannelBytes,
      ),
      linksPerToken: number(link, 'link.', 'perToken', d.linksPerToken),
      linkFrameBytes: number(link, 'link.', 'frameBytes', d.linkFrameBytes),
      linkAloneTimeout: Duration(
        hours: number(link, 'link.', 'aloneHours', d.linkAloneTimeout.inHours),
      ),
      putsPerHour: number(mailbox, 'mailbox.', 'putsPerHour', d.putsPerHour),
      itemBytes: number(mailbox, 'mailbox.', 'itemBytes', d.itemBytes),
      itemsPerRecipient: number(
        mailbox,
        'mailbox.',
        'itemsPerRecipient',
        d.itemsPerRecipient,
      ),
      bytesPerRecipient: number(
        mailbox,
        'mailbox.',
        'bytesPerRecipient',
        d.bytesPerRecipient,
      ),
      maxExpiry: Duration(
        days: number(mailbox, 'mailbox.', 'maxExpiryDays', d.maxExpiry.inDays),
      ),
      challengesPerHour: number(
        proof,
        'proof.',
        'challengesPerHour',
        d.challengesPerHour,
      ),
      proofLifetime: Duration(
        minutes: number(proof, 'proof.', 'minutes', d.proofLifetime.inMinutes),
      ),
      expiryInterval: Duration(
        minutes: number(m, '', 'expiryMinutes', d.expiryInterval.inMinutes),
      ),
    );
  }

  /// Who may put mailbox items and open links.
  final TomSecretsRelayMode mode;

  /// The instance tokens by name (a team or a user): the name is what the
  /// logs and the per-token limits use, never the token.
  final Map<String, String> tokens;

  /// Address ranges (CIDR, IPv4 and IPv6) that are refused.
  final List<String> deny;

  /// Address ranges that are served; empty: every address not denied.
  final List<String> allow;

  /// The reverse proxies whose `X-Forwarded-For` names the client.
  final List<String> trustedProxies;

  /// Where the mailbox and the block list are kept.
  final String storageDirectory;

  /// Denial-of-service protection: the requests one address may make in a
  /// second, a minute, a day before it is blocked.
  final int requestsPerSecond;

  /// See [requestsPerSecond].
  final int requestsPerMinute;

  /// See [requestsPerSecond].
  final int requestsPerDay;

  /// How long the first, second, third ... block lasts; each block past the
  /// list lasts twice the one before.
  final List<Duration> blockDurations;

  /// How long a past block counts towards the next one's length.
  final Duration blockMemory;

  /// Nameplates one address may allocate per hour.
  final int nameplatesPerHour;

  /// How long a nameplate stays open.
  final Duration nameplateLifetime;

  /// The largest frame on a pairing channel.
  final int pairingFrameBytes;

  /// The most bytes a pairing channel carries.
  final int pairingChannelBytes;

  /// Approval links open at once per instance token.
  final int linksPerToken;

  /// The largest frame on an approval link.
  final int linkFrameBytes;

  /// How long one side of a link waits alone for the other.
  final Duration linkAloneTimeout;

  /// Mailbox puts per instance token (open mode: per address) per hour.
  final int putsPerHour;

  /// The largest mailbox item.
  final int itemBytes;

  /// The most items waiting for one recipient.
  final int itemsPerRecipient;

  /// The most bytes waiting for one recipient.
  final int bytesPerRecipient;

  /// The latest expiry a put may ask for.
  final Duration maxExpiry;

  /// Proof challenges per recipient per hour.
  final int challengesPerHour;

  /// How long an answered proof is accepted.
  final Duration proofLifetime;

  /// How often the expiry job runs.
  final Duration expiryInterval;

  /// These settings with the storage directory [directory].
  TomSecretsRelayConfig withStorage(String directory) => TomSecretsRelayConfig(
    mode: mode,
    tokens: tokens,
    deny: deny,
    allow: allow,
    trustedProxies: trustedProxies,
    storageDirectory: directory,
    requestsPerSecond: requestsPerSecond,
    requestsPerMinute: requestsPerMinute,
    requestsPerDay: requestsPerDay,
    blockDurations: blockDurations,
    blockMemory: blockMemory,
    nameplatesPerHour: nameplatesPerHour,
    nameplateLifetime: nameplateLifetime,
    pairingFrameBytes: pairingFrameBytes,
    pairingChannelBytes: pairingChannelBytes,
    linksPerToken: linksPerToken,
    linkFrameBytes: linkFrameBytes,
    linkAloneTimeout: linkAloneTimeout,
    putsPerHour: putsPerHour,
    itemBytes: itemBytes,
    itemsPerRecipient: itemsPerRecipient,
    bytesPerRecipient: bytesPerRecipient,
    maxExpiry: maxExpiry,
    challengesPerHour: challengesPerHour,
    proofLifetime: proofLifetime,
    expiryInterval: expiryInterval,
  );

  /// The name of the instance token [token], or null when it is none.
  String? tokenName(String? token) {
    if (token == null || token.isEmpty) return null;
    for (final e in tokens.entries) {
      if (_sameText(e.value, token)) return e.key;
    }
    return null;
  }

  /// How long the [n]th block (1 the first) lasts.
  Duration blockDuration(int n) {
    if (n <= blockDurations.length) return blockDurations[n - 1];
    var d = blockDurations.last;
    for (var i = blockDurations.length; i < n; i++) {
      d *= 2;
    }
    return d;
  }
}

/// Compares two texts in time that does not depend on where they differ.
bool _sameText(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}
