// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// **[C]** The address filters and the denial-of-service protection
/// (part-relay, DP-65): checked before anything else, for every request
/// and every WebSocket opened.
///
/// - **Filters:** an address in a deny range is refused; when allow ranges
///   are set, only addresses inside one are served.
/// - **Blocks:** an address that makes more requests than any of three
///   limits allows (2 in a second, 100 in a minute, 500 in a day) is
///   blocked: 24 hours the first time, 48 the second, a week the third,
///   each further block twice the one before. A blocked address is ignored
///   (its connection closed without an answer). The block list is kept in
///   a file, so a restart lifts no block.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tom_core_server/tom_core_server.dart';

import 'config.dart';

/// An address range in CIDR notation, IPv4 or IPv6 (`10.0.0.0/8`,
/// `fd00::/8`; a bare address is the range of that one address).
final class TomSecretsRelayCidr {
  TomSecretsRelayCidr._(this.text, this._network, this._prefix);

  /// The range [text] names; throws [FormatException] for anything else.
  factory TomSecretsRelayCidr.parse(String text) {
    final t = text.trim();
    final slash = t.indexOf('/');
    final address = InternetAddress.tryParse(
      slash < 0 ? t : t.substring(0, slash),
    );
    if (address == null) throw FormatException('not an address range: $text');
    final bits = address.rawAddress.length * 8;
    final prefix = slash < 0 ? bits : int.tryParse(t.substring(slash + 1));
    if (prefix == null || prefix < 0 || prefix > bits) {
      throw FormatException('not an address range: $text');
    }
    return TomSecretsRelayCidr._(t, address.rawAddress, prefix);
  }

  /// The range as written.
  final String text;
  final Uint8List _network;
  final int _prefix;

  /// Whether [address] lies in the range (an IPv4 address mapped into IPv6,
  /// `::ffff:a.b.c.d`, counts as its IPv4 address).
  bool contains(InternetAddress address) {
    var raw = address.rawAddress;
    if (raw.length == 16 && _network.length == 4 && _isMapped(raw)) {
      raw = raw.sublist(12);
    }
    if (raw.length != _network.length) return false;
    var left = _prefix;
    for (var i = 0; i < raw.length && left > 0; i++) {
      final take = left >= 8 ? 8 : left;
      final mask = (0xff << (8 - take)) & 0xff;
      if ((raw[i] & mask) != (_network[i] & mask)) return false;
      left -= take;
    }
    return true;
  }

  static bool _isMapped(Uint8List raw) {
    for (var i = 0; i < 10; i++) {
      if (raw[i] != 0) return false;
    }
    return raw[10] == 0xff && raw[11] == 0xff;
  }

  @override
  String toString() => text;
}

/// What the guard says about a request.
enum TomSecretsRelayVerdict {
  /// Served.
  serve,

  /// Refused by the address filters (answered 403).
  refuse,

  /// Blocked: the connection is closed without an answer.
  ignore,
}

/// One address's block record.
final class _Block {
  _Block(this.count, this.until, this.last);

  /// How many blocks it had within the remembered time.
  int count;

  /// Until when the current block lasts.
  DateTime until;

  /// When the last block began.
  DateTime last;

  Map<String, Object?> toJson() => {
    'count': count,
    'until': until.toUtc().toIso8601String(),
    'last': last.toUtc().toIso8601String(),
  };
}

/// The filters and the block list.
final class TomSecretsRelayAddressGuard {
  /// The guard of [config], its block list kept in [blockFile] (null: in
  /// memory only), the time read from [clock].
  TomSecretsRelayAddressGuard(
    this.config, {
    this.blockFile,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _deny = [for (final c in config.deny) TomSecretsRelayCidr.parse(c)],
       _allow = [for (final c in config.allow) TomSecretsRelayCidr.parse(c)] {
    _limiter = TomMemoryRateLimiter(clock: _clock);
    _rules = [
      TomRateLimitRule(
        name: 'second',
        scope: TomRateLimitScope.address,
        limit: config.requestsPerSecond,
        window: const Duration(seconds: 1),
      ),
      TomRateLimitRule(
        name: 'minute',
        scope: TomRateLimitScope.address,
        limit: config.requestsPerMinute,
        window: const Duration(minutes: 1),
      ),
      TomRateLimitRule(
        name: 'day',
        scope: TomRateLimitScope.address,
        limit: config.requestsPerDay,
        window: const Duration(days: 1),
      ),
    ];
    _load();
  }

  /// The settings.
  final TomSecretsRelayConfig config;

  /// Where the block list is kept.
  final File? blockFile;

  final DateTime Function() _clock;
  final List<TomSecretsRelayCidr> _deny;
  final List<TomSecretsRelayCidr> _allow;
  late final TomMemoryRateLimiter _limiter;
  late final List<TomRateLimitRule> _rules;
  final Map<String, _Block> _blocks = {};

  void _load() {
    final file = blockFile;
    if (file == null || !file.existsSync()) return;
    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map) return;
      for (final e in json.entries) {
        final v = e.value;
        if (v is! Map) continue;
        final until = DateTime.tryParse('${v['until']}');
        final last = DateTime.tryParse('${v['last']}');
        final count = v['count'];
        if (until == null || last == null || count is! int) continue;
        _blocks['${e.key}'] = _Block(count, until, last);
      }
    } on FormatException {
      tomLog.warn(
        'relay: the block list ${file.path} cannot be read; it starts empty',
      );
    }
  }

  void _save() {
    final file = blockFile;
    if (file == null) return;
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp')
      ..writeAsStringSync(
        jsonEncode({for (final e in _blocks.entries) e.key: e.value.toJson()}),
      );
    tmp.renameSync(file.path);
  }

  /// Whether [address] passes the filters (an unparsable one does not when
  /// allow ranges are set).
  bool admitted(String address) {
    final a = InternetAddress.tryParse(address);
    if (a == null) return _allow.isEmpty;
    if (_deny.any((c) => c.contains(a))) return false;
    return _allow.isEmpty || _allow.any((c) => c.contains(a));
  }

  /// Until when [address] is blocked, or null.
  DateTime? blockedUntil(String address) {
    final b = _blocks[address];
    if (b == null) return null;
    return b.until.isAfter(_clock()) ? b.until : null;
  }

  /// How many blocks [address] had within the remembered time.
  int blockCount(String address) => _blocks[address]?.count ?? 0;

  /// Checks a request (or a WebSocket opened) from [address] and counts
  /// it.
  Future<TomSecretsRelayVerdict> check(String address) async {
    if (!admitted(address)) return TomSecretsRelayVerdict.refuse;
    if (blockedUntil(address) != null) return TomSecretsRelayVerdict.ignore;
    var exceeded = false;
    for (final rule in _rules) {
      final d = await _limiter.hit('${rule.name}|$address', rule);
      if (!d.allowed) exceeded = true;
    }
    if (!exceeded) return TomSecretsRelayVerdict.serve;
    _block(address);
    return TomSecretsRelayVerdict.ignore;
  }

  void _block(String address) {
    final now = _clock();
    final old = _blocks[address];
    final count = old == null || now.difference(old.last) > config.blockMemory
        ? 1
        : old.count + 1;
    final duration = config.blockDuration(count);
    _blocks[address] = _Block(count, now.add(duration), now);
    tomLog.warn(
      'relay: blocked an address (block $count, ${duration.inHours} hours): '
      'more requests than the denial-of-service limits allow',
    );
    _save();
  }

  /// Forgets records whose block is over and older than the remembered
  /// time (the expiry job).
  void expire() {
    final now = _clock();
    final before = _blocks.length;
    _blocks.removeWhere(
      (_, b) =>
          !b.until.isAfter(now) && now.difference(b.last) > config.blockMemory,
    );
    if (_blocks.length != before) _save();
  }
}
