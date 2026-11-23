// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// **[C]** The mailboxes and the recipient's proof (part-relay, DP-67):
/// `age` packages waiting for one recipient up to 30 days, in a blob store
/// (one file per item, a small JSON index per recipient, no database), read
/// and deleted only by the holder of the recipient's member key.
///
/// - **Recipient:** the base32 SHA-256 of the hybrid recipient string
///   (`age1pq1…`), the member's fingerprint (52 lower-case characters).
/// - **Proof:** a challenge carries the full recipient string; the relay
///   checks it hashes to the recipient and answers a random token encrypted
///   with `age` to it. The token, sent back, opens the mailbox for 5
///   minutes.
/// - **Limits:** 1 MB per item, 200 items or 50 MB per recipient, at most
///   30 days; 20 challenges per recipient per hour.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:tom_core_server/tom_core_server.dart';
import 'package:tom_secrets_age/tom_secrets_age.dart';

import 'config.dart';

/// A refused mailbox or proof request: the HTTP [status] and the [message]
/// answered, with [retryAfter] for a 429.
final class TomSecretsRelayRefused implements Exception {
  /// A refusal.
  const TomSecretsRelayRefused(this.status, this.message, {this.retryAfter});

  /// The HTTP status.
  final int status;

  /// For people.
  final String message;

  /// When to try again (a 429).
  final Duration? retryAfter;

  @override
  String toString() => 'TomSecretsRelayRefused($status): $message';
}

/// One waiting item, as the index keeps it and a listing answers it.
final class TomSecretsRelayItem {
  /// The item [id] of [size] bytes, received at [received], kept until
  /// [expires].
  const TomSecretsRelayItem({
    required this.id,
    required this.size,
    required this.received,
    required this.expires,
  });

  /// From [toJson].
  factory TomSecretsRelayItem.fromJson(Map<String, Object?> json) =>
      TomSecretsRelayItem(
        id: json['id'] as String,
        size: json['size'] as int,
        received: DateTime.parse(json['received'] as String),
        expires: DateTime.parse(json['expires'] as String),
      );

  /// Its id.
  final String id;

  /// Its size in bytes.
  final int size;

  /// When it arrived.
  final DateTime received;

  /// When it is deleted.
  final DateTime expires;

  /// The index's and the listing's JSON.
  Map<String, Object?> toJson() => {
    'id': id,
    'size': size,
    'received': received.toUtc().toIso8601String(),
    'expires': expires.toUtc().toIso8601String(),
  };
}

/// Whether [text] is a recipient id: 52 lower-case base32 characters.
bool tomSecretsRelayIsRecipient(String text) => _recipient.hasMatch(text);

/// Whether [text] is an item id: 1–128 of `A-Z a-z 0-9 . _ -`, not
/// starting with a dot.
bool tomSecretsRelayIsItemId(String text) => _itemId.hasMatch(text);

final _recipient = RegExp(r'^[a-z2-7]{52}$');
final _itemId = RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$');

/// The recipient as the logs name it: its first 8 characters.
String tomSecretsRelayShortRecipient(String recipient) =>
    recipient.length <= 8 ? recipient : recipient.substring(0, 8);

/// The mailboxes over a blob store.
final class TomSecretsRelayMailbox {
  /// The mailboxes of [store] under [config], the time read from [clock].
  TomSecretsRelayMailbox(this.store, this.config, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// Where the items and the indexes are.
  final TomBlobStore store;

  /// The settings.
  final TomSecretsRelayConfig config;
  final DateTime Function() _clock;
  final Map<String, Future<void>> _locks = {};

  static const _recipientsKey = 'recipients.json';
  static String _indexKey(String r) => 'index/$r.json';
  static String _itemKey(String r, String id) => 'items/$r/$id';

  /// Runs [body] with [recipient]'s mailbox to itself (one change at a
  /// time per recipient).
  Future<T> _locked<T>(String recipient, Future<T> Function() body) {
    final before = _locks[recipient] ?? Future<void>.value();
    final result = before.then((_) => body());
    final done = result.then<void>((_) {}, onError: (_) {});
    _locks[recipient] = done;
    unawaited(
      done.then(
        (_) => _locks.removeWhere((k, v) => k == recipient && v == done),
      ),
    );
    return result;
  }

  Future<List<TomSecretsRelayItem>> _index(String recipient) async {
    if (!await store.exists(_indexKey(recipient))) return [];
    final json = jsonDecode(
      utf8.decode(await store.getBytes(_indexKey(recipient))),
    );
    return [
      for (final e in (json as Map)['items'] as List)
        TomSecretsRelayItem.fromJson((e as Map).cast()),
    ];
  }

  Future<void> _writeIndex(
    String recipient,
    List<TomSecretsRelayItem> items,
  ) async {
    if (items.isEmpty) {
      await store.delete(_indexKey(recipient));
      await _updateRecipients((s) => s.remove(recipient));
      return;
    }
    await store.putBytes(
      key: _indexKey(recipient),
      bytes: utf8.encode(
        jsonEncode({
          'items': [for (final i in items) i.toJson()],
        }),
      ),
      mediaType: 'application/json',
    );
    await _updateRecipients((s) => s.add(recipient));
  }

  Future<Set<String>> _recipients() async {
    if (!await store.exists(_recipientsKey)) return {};
    final json = jsonDecode(utf8.decode(await store.getBytes(_recipientsKey)));
    return {for (final r in json as List) '$r'};
  }

  Future<void> _recipientsLock = Future.value();

  Future<void> _updateRecipients(void Function(Set<String>) change) {
    final run = _recipientsLock.then((_) async {
      final set = await _recipients();
      final before = set.length;
      change(set);
      if (set.length == before) return;
      await store.putBytes(
        key: _recipientsKey,
        bytes: utf8.encode(jsonEncode(set.toList()..sort())),
        mediaType: 'application/json',
      );
    });
    _recipientsLock = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  /// Stores [bytes] as [itemId] for [recipient] until [expires]. Throws
  /// [TomSecretsRelayRefused]: 400 for a malformed id or expiry, 409 when
  /// the id exists, 413 for a large item, 429 when the mailbox is full.
  Future<void> put(
    String recipient,
    String itemId,
    Uint8List bytes,
    DateTime expires,
  ) {
    _checkIds(recipient, itemId);
    final now = _clock();
    if (!expires.isAfter(now)) {
      throw const TomSecretsRelayRefused(400, 'Tsm-Expires lies in the past');
    }
    if (expires.isAfter(now.add(config.maxExpiry))) {
      throw TomSecretsRelayRefused(
        400,
        'Tsm-Expires lies more than ${config.maxExpiry.inDays} days ahead',
      );
    }
    if (bytes.length > config.itemBytes) {
      throw TomSecretsRelayRefused(
        413,
        'an item has at most ${config.itemBytes} bytes',
      );
    }
    return _locked(recipient, () async {
      final items = await _index(recipient);
      if (items.any((i) => i.id == itemId)) {
        throw TomSecretsRelayRefused(409, 'the item $itemId exists');
      }
      final held = items.fold<int>(0, (n, i) => n + i.size);
      if (items.length >= config.itemsPerRecipient ||
          held + bytes.length > config.bytesPerRecipient) {
        final next = items.isEmpty
            ? const Duration(hours: 1)
            : items
                  .map((i) => i.expires)
                  .reduce((a, b) => a.isBefore(b) ? a : b)
                  .difference(now);
        throw TomSecretsRelayRefused(
          429,
          'the mailbox is full (${config.itemsPerRecipient} items or '
          '${config.bytesPerRecipient} bytes)',
          retryAfter: next.isNegative ? const Duration(minutes: 10) : next,
        );
      }
      await store.putBytes(key: _itemKey(recipient, itemId), bytes: bytes);
      await _writeIndex(recipient, [
        ...items,
        TomSecretsRelayItem(
          id: itemId,
          size: bytes.length,
          received: now,
          expires: expires,
        ),
      ]);
    });
  }

  /// The items waiting for [recipient] (expired ones left out).
  Future<List<TomSecretsRelayItem>> list(String recipient) async {
    _checkIds(recipient, null);
    final now = _clock();
    return [
      for (final i in await _index(recipient))
        if (i.expires.isAfter(now)) i,
    ];
  }

  /// The bytes of [itemId] for [recipient], or null.
  Future<Uint8List?> fetch(String recipient, String itemId) async {
    _checkIds(recipient, itemId);
    final items = await list(recipient);
    if (!items.any((i) => i.id == itemId)) return null;
    final key = _itemKey(recipient, itemId);
    if (!await store.exists(key)) return null;
    return store.getBytes(key);
  }

  /// Deletes [itemId] for [recipient]; whether it was there.
  Future<bool> delete(String recipient, String itemId) {
    _checkIds(recipient, itemId);
    return _locked(recipient, () async {
      final items = await _index(recipient);
      final kept = [
        for (final i in items)
          if (i.id != itemId) i,
      ];
      if (kept.length == items.length) return false;
      await store.delete(_itemKey(recipient, itemId));
      await _writeIndex(recipient, kept);
      return true;
    });
  }

  /// Deletes every expired item (the expiry job); answers how many.
  Future<int> expire() async {
    final now = _clock();
    var removed = 0;
    for (final recipient in await _recipients()) {
      removed += await _locked(recipient, () async {
        final items = await _index(recipient);
        final kept = <TomSecretsRelayItem>[];
        var n = 0;
        for (final i in items) {
          if (i.expires.isAfter(now)) {
            kept.add(i);
          } else {
            await store.delete(_itemKey(recipient, i.id));
            n++;
          }
        }
        if (n > 0) await _writeIndex(recipient, kept);
        return n;
      });
    }
    return removed;
  }

  void _checkIds(String recipient, String? itemId) {
    if (!tomSecretsRelayIsRecipient(recipient)) {
      throw const TomSecretsRelayRefused(
        400,
        'not a recipient id (the base32 SHA-256 of the recipient)',
      );
    }
    if (itemId != null && !tomSecretsRelayIsItemId(itemId)) {
      throw const TomSecretsRelayRefused(400, 'not an item id');
    }
  }
}

/// The recipients' proofs: challenges answered with an `age` file, and the
/// tokens they carry.
final class TomSecretsRelayProofs {
  /// The proofs under [config], the time read from [clock].
  TomSecretsRelayProofs(
    this.config, {
    DateTime Function()? clock,
    Random? random,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure() {
    _limiter = TomMemoryRateLimiter(clock: _clock);
    _rule = TomRateLimitRule(
      name: 'proof',
      scope: TomRateLimitScope.address,
      limit: config.challengesPerHour,
      window: const Duration(hours: 1),
    );
  }

  /// The settings.
  final TomSecretsRelayConfig config;
  final DateTime Function() _clock;
  final Random _random;
  late final TomMemoryRateLimiter _limiter;
  late final TomRateLimitRule _rule;

  /// Token hash → (recipient, valid until).
  final Map<String, (String, DateTime)> _proofs = {};

  /// The challenge for [recipient], whose full recipient string is
  /// [recipientText]: an `age` file to it holding a fresh token. Throws
  /// [TomSecretsRelayRefused]: 400 when the text is no hybrid recipient or
  /// does not hash to [recipient], 429 past 20 challenges an hour.
  Future<Uint8List> challenge(String recipient, String recipientText) async {
    if (!tomSecretsRelayIsRecipient(recipient)) {
      throw const TomSecretsRelayRefused(400, 'not a recipient id');
    }
    final TomSecretsAgeRecipient parsed;
    try {
      parsed = TomSecretsAgeRecipient.parse(recipientText.trim());
    } on Object {
      throw const TomSecretsRelayRefused(400, 'the body is no age recipient');
    }
    if (!parsed.isHybrid) {
      throw const TomSecretsRelayRefused(
        400,
        'a mailbox belongs to a hybrid member key (age1pq1…)',
      );
    }
    if (parsed.fingerprint != recipient) {
      throw const TomSecretsRelayRefused(
        400,
        'the recipient does not hash to the mailbox\'s id',
      );
    }
    final d = await _limiter.hit(recipient, _rule);
    if (!d.allowed) {
      throw TomSecretsRelayRefused(
        429,
        'at most ${config.challengesPerHour} challenges per hour',
        retryAfter: d.retryAfter,
      );
    }
    _expireProofs();
    final token = base64Url
        .encode(List.generate(32, (_) => _random.nextInt(256)))
        .replaceAll('=', '');
    _proofs[_hash(token)] = (recipient, _clock().add(config.proofLifetime));
    return tomSecretsAgeEncrypt(utf8.encode(token), [parsed]);
  }

  /// Whether [token] proves [recipient] now.
  bool verify(String recipient, String? token) {
    if (token == null || token.isEmpty) return false;
    final p = _proofs[_hash(token)];
    if (p == null) return false;
    return p.$1 == recipient && p.$2.isAfter(_clock());
  }

  /// Forgets the tokens that ran out (the expiry job).
  void expire() => _expireProofs();

  void _expireProofs() {
    final now = _clock();
    _proofs.removeWhere((_, p) => !p.$2.isAfter(now));
  }

  static String _hash(String token) =>
      sha256.convert(utf8.encode(token)).toString();
}
