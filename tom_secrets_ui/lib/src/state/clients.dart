// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// What the Clients and Settings screens read and write through the service
/// (part-app, Screens › Clients and Settings; protocol.md 6.3, 7.3, 7.5): the
/// allow list of every host, pre-approvals, revocations, approval tokens, the
/// audit log, the command-line approval switch (DP-19) and the device
/// settings.
library;

import 'package:flutter/foundation.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart'
    show TomSecretsDeviceSettings;

import 'service_connection.dart';

/// A grant of the allow list (protocol.md 7.3).
@immutable
final class TomSecretsGrant {
  const TomSecretsGrant._(this.wire);

  /// The grant as `grants.list` answers it.
  factory TomSecretsGrant.fromWire(Map<String, Object?> wire) =>
      TomSecretsGrant._(Map.unmodifiable(wire));

  /// The grant as the service sent it.
  final Map<String, Object?> wire;

  /// Its id.
  String get id => wire['id'] as String? ?? '';

  /// The host it holds on.
  String get host => wire['host'] as String? ?? '';

  /// Who it covers: `exe <path>`, `script <interpreter> <path>`,
  /// `interpreter <path>`, `folder <path> [interpreter]`, `tsm-command …` or
  /// `exe-token <path> <tokenId>`.
  String get subject => wire['subject'] as String? ?? '';

  /// What it covers: a reference, `store <name>` or `all`.
  String get secret => wire['secret'] as String? ?? '';

  /// `allow` or `never`.
  String get decision => wire['decision'] as String? ?? '';

  /// When it was made.
  DateTime? get created => DateTime.tryParse(wire['created'] as String? ?? '');

  /// When it was last used.
  DateTime? get lastUsed =>
      DateTime.tryParse(wire['lastUsed'] as String? ?? '');

  /// The trusted device that made it.
  String? get approver => wire['approver'] as String?;

  /// Whether its signatures verify against a key the service recorded: only
  /// an accepted grant decides anything.
  bool get accepted => wire['accepted'] == true;

  /// The kind of its subject (`exe`, `script`, `folder`, …).
  String get subjectKind => subject.split(' ').first;

  /// The group the allow list shows it in (part-app, Clients): by
  /// executable (a token grant under its executable), by interpreter and
  /// script, by folder, by interpreter, by `tsm` command.
  String get group {
    final rest = subject.contains(' ')
        ? subject.substring(subject.indexOf(' ') + 1)
        : '';
    return switch (subjectKind) {
      'exe' => 'Executable $rest',
      'exe-token' =>
        'Executable ${rest.contains(' ') ? rest.substring(0, rest.lastIndexOf(' ')) : rest}',
      'script' => 'Script $rest',
      'folder' => 'Folder $rest',
      'interpreter' => 'Interpreter $rest',
      'tsm-command' => 'tsm command $rest',
      _ => subject,
    };
  }
}

/// A record of the audit log (`audit.query`).
@immutable
final class TomSecretsAuditEntry {
  const TomSecretsAuditEntry._(this.wire);

  /// The record as `audit.query` answers it.
  factory TomSecretsAuditEntry.fromWire(Map<String, Object?> wire) =>
      TomSecretsAuditEntry._(Map.unmodifiable(wire));

  /// The record as the service sent it.
  final Map<String, Object?> wire;

  /// When.
  DateTime get time =>
      DateTime.tryParse(wire['time'] as String? ?? '') ?? DateTime(0);

  /// The host.
  String get host => wire['host'] as String? ?? '';

  /// The client's identity.
  Map<String, Object?> get identity =>
      (wire['identity'] as Map? ?? const {}).cast<String, Object?>();

  /// The client in one line.
  String get client {
    final script = identity['script'];
    final exe = identity['exe'] as String? ?? '';
    return script is String ? '${identity['interpreter'] ?? exe} $script' : exe;
  }

  /// The references asked for.
  List<String> get refs => (wire['refs'] as List? ?? const []).cast<String>();

  /// The outcome (`allowed`, `denied`, `timeout`, …).
  String get outcome => wire['outcome'] as String? ?? '';

  /// The grant that decided it, or null.
  String? get grantId => wire['grantId'] as String?;

  /// The device that approved it, or null.
  String? get approver => wire['approver'] as String?;
}

/// A key the service knows a due date of (`keys`, protocol.md 6.3;
/// part-key-rotation, Keys and their expiry).
@immutable
final class TomSecretsKeyInfo {
  const TomSecretsKeyInfo._({
    required this.kind,
    required this.key,
    required this.vault,
    required this.expiresAt,
    required this.daysLeft,
    required this.reminding,
  });

  /// From a `keyList.keys[]` item.
  factory TomSecretsKeyInfo.fromWire(Map<String, Object?> wire) =>
      TomSecretsKeyInfo._(
        kind: wire['kind'] as String? ?? '',
        key: wire['key'] as String? ?? '',
        vault: wire['vault'] as String?,
        expiresAt:
            DateTime.tryParse(wire['expiresAt'] as String? ?? '') ??
            DateTime(0),
        daysLeft: wire['daysLeft'] is int ? wire['daysLeft']! as int : 0,
        reminding: wire['reminding'] == true,
      );

  /// `github_token`, `vault_keys`, `approver_key` or `link_key`.
  final String kind;

  /// Its id: `github-token:<owner>/<repository>`, `vault-keys:<vault>`,
  /// `approver-key:<device>`, `link-key:<device>`.
  final String key;

  /// The vault it belongs to, when one.
  final String? vault;

  /// When it expires or is due for rotation.
  final DateTime expiresAt;

  /// Whole days left (negative once expired).
  final int daysLeft;

  /// Whether a reminder is due now.
  final bool reminding;

  /// What follows the kind in [key]: the repository, vault or device.
  String get subject =>
      key.contains(':') ? key.substring(key.indexOf(':') + 1) : key;

  /// The key's use, for the user.
  String get title => switch (kind) {
    'github_token' => 'GitHub token for $subject',
    'vault_keys' => 'Key file and repository key of $subject',
    'approver_key' => 'Approver key pair of $subject',
    'link_key' => 'Approval-link key pair of $subject',
    _ => key,
  };

  /// Whether it is past its date.
  bool get expired => daysLeft < 0;

  /// Its reminder step now: `first`, `7`, `1` or `expired <date>` (the
  /// service's steps; a snooze lasts until the step changes).
  String get step => tomSecretsReminderStep(daysLeft, DateTime.now());
}

/// The reminder step of a key [daysLeft] days from its date at [now]: `first`,
/// `7`, `1`, or `expired <date>` (once a day once expired).
String tomSecretsReminderStep(int daysLeft, DateTime now) => daysLeft < 0
    ? 'expired ${now.toUtc().toIso8601String().substring(0, 10)}'
    : daysLeft <= 1
    ? '1'
    : daysLeft <= 7
    ? '7'
    : 'first';

/// The device settings as `settings.get` answers them.
@immutable
final class TomSecretsSettingsReport {
  const TomSecretsSettingsReport({
    required this.device,
    required this.cliApprovals,
    required this.stores,
  });

  /// From a `deviceSettings` answer.
  factory TomSecretsSettingsReport.fromWire(Map<String, Object?> wire) =>
      TomSecretsSettingsReport(
        device: TomSecretsDeviceSettings.fromJson(
          (wire['device'] as Map? ?? const {}).cast<String, Object?>(),
        ),
        cliApprovals: wire['cliApprovals'] == true,
        stores: (wire['stores'] as List? ?? const []).cast<String>(),
      );

  /// The settings.
  final TomSecretsDeviceSettings device;

  /// Whether `tsm` may pre-approve and issue approval tokens (DP-19).
  final bool cliApprovals;

  /// The stores the primary names, the primary first.
  final List<String> stores;
}

/// The requests of the Clients and Settings screens over [connection].
final class TomSecretsClientsApi {
  /// The requests over [connection].
  const TomSecretsClientsApi(this.connection);

  /// The admin connection.
  final TomSecretsServiceConnection connection;

  /// The allow list of [host], or of every host.
  Future<List<TomSecretsGrant>> grants({String? host}) async {
    final answer = await connection.request('grants.list', {'host': ?host});
    return [
      for (final g in (answer['grants'] as List? ?? const []).cast<Map>())
        TomSecretsGrant.fromWire(g.cast<String, Object?>()),
    ];
  }

  /// Revokes [grant] (of any host).
  Future<void> revoke(TomSecretsGrant grant) => connection.request(
    'grants.revoke',
    {'host': grant.host, 'grantId': grant.id},
  );

  /// Adds a grant for [host] before a client asks (a pre-approval): [subject]
  /// (`exe <path>`, `script <interpreter> <path>`, `interpreter <path>`,
  /// `folder <path>`), [secret] (a reference, `store <name>` or `all`),
  /// [decision] (`allow` or `never`), [pin] (`hash`, `off`).
  Future<void> addGrant({
    required String host,
    required String subject,
    required String secret,
    required String decision,
    String? pin,
  }) => connection.request('grants.add', {
    'grant': {
      'host': host,
      'subject': subject,
      'secret': secret,
      'decision': decision,
      'pin': ?pin,
    },
  });

  /// The approval token for [code] shown on [host] with [decision]
  /// (`approval.issue`, protocol.md 9.6).
  Future<String> issueToken({
    required String host,
    required String code,
    required String decision,
  }) async {
    final answer = await connection.request('approval.issue', {
      'host': host,
      'code': code.toUpperCase().replaceAll(RegExp(r'\s'), ''),
      'decision': decision,
    });
    return answer['token']! as String;
  }

  /// The audit records between [from] and [to], filtered by the service by
  /// [subject] and [ref].
  Future<List<TomSecretsAuditEntry>> audit({
    required DateTime from,
    required DateTime to,
    String? subject,
    String? ref,
  }) async {
    final answer = await connection.request('audit.query', {
      'from': from.toUtc().toIso8601String(),
      'to': to.toUtc().toIso8601String(),
      'subject': ?subject,
      'ref': ?ref,
    });
    return [
      for (final r in (answer['records'] as List? ?? const []).cast<Map>())
        TomSecretsAuditEntry.fromWire(r.cast<String, Object?>()),
    ]..sort((a, b) => b.time.compareTo(a.time));
  }

  /// Every key the service knows a due date of, soonest first.
  Future<List<TomSecretsKeyInfo>> keys() async {
    final answer = await connection.request('keys');
    return [
      for (final k in (answer['keys'] as List? ?? const []).cast<Map>())
        TomSecretsKeyInfo.fromWire(k.cast<String, Object?>()),
    ]..sort((a, b) => a.expiresAt.compareTo(b.expiresAt));
  }

  /// Switches command-line approvals on this device (DP-19).
  Future<void> setCliApprovals(bool on) =>
      connection.request('approvers.cliSwitch', {'on': on});

  /// The device settings.
  Future<TomSecretsSettingsReport> settings() async =>
      TomSecretsSettingsReport.fromWire(
        await connection.request('settings.get'),
      );

  /// Writes [device] as the device settings; answers the settings that
  /// apply at the next unlock.
  Future<List<String>> writeSettings(TomSecretsDeviceSettings device) async {
    final answer = await connection.request('settings.set', {
      'device': device.toJson(),
    });
    return (answer['nextUnlock'] as List? ?? const []).cast<String>();
  }
}
