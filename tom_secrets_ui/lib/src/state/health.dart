// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The health report and the breach check in the app (part-password-manager,
/// DP-39, DP-179): computed over the vaults open in the app's memory, never
/// in the service.
///
/// - **The report** ([TomSecretsHealth.report]): weak, reused, old,
///   expiring and breached passwords and short keys, recomputed when the
///   vaults change.
/// - **The breach check**, on by default: it checks new and changed
///   passwords at once and all of them once a week, while the app runs and
///   holds the vaults. Each run is announced on [TomSecretsHealth.runs]; the
///   app shows it as a notification with a "Turn off breach check" action.
///   Only the five-character SHA-1 prefixes leave the device
///   ([TomSecretsBreachCheck]).
/// - **What is kept on the device** (the preferences): whether the check is
///   on, the age after which a password counts as old, and the check's
///   record — when the last full run was, and per entry the time of the
///   password checked with its count. Never a password or a hash.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../ports/desktop_ports.dart';
import 'session_state.dart';

/// The preference keys of the health report.
abstract final class TomSecretsHealthPreferenceKeys {
  /// `off` turns the breach check off (it is on by default, DP-39).
  static const breachCheck = 'health.breachCheck';

  /// The days after which a password counts as old.
  static const oldAfterDays = 'health.oldAfterDays';

  /// The breach check's record (JSON).
  static const breachRecord = 'health.breachRecord';
}

/// One run of the breach check.
@immutable
final class TomSecretsBreachRun {
  /// [checked] passwords asked about, [breached] of them found, at [at];
  /// [full] for the weekly run over every password.
  const TomSecretsBreachRun({
    required this.checked,
    required this.breached,
    required this.full,
    required this.at,
  });

  /// How many passwords were checked.
  final int checked;

  /// How many of them were found in breaches.
  final int breached;

  /// Whether every password was checked (the weekly run).
  final bool full;

  /// When it ran.
  final DateTime at;

  /// The notification's title.
  String get title => breached == 0
      ? 'Breach check: nothing found'
      : 'Breach check: ${breached == 1 ? 'a password was' : '$breached passwords were'} found';

  /// The notification's text; never a password or a title.
  String get body {
    final what = full
        ? 'All $checked passwords checked'
        : '${checked == 1 ? 'A new or changed password' : '$checked new or changed passwords'} checked';
    return breached == 0
        ? '$what: none appears in known breaches.'
        : '$what: $breached ${breached == 1 ? 'appears' : 'appear'} in known '
              'breaches. Open Health to change ${breached == 1 ? 'it' : 'them'}.';
  }
}

/// The health report and the breach check over a [TomSecretsSession].
class TomSecretsHealth extends ChangeNotifier {
  /// Over [session], keeping its settings in [preferences]; [check] asks the
  /// range API (its owner closes it), [clock] tells the time.
  TomSecretsHealth({
    required this.session,
    required this.preferences,
    required TomSecretsBreachCheck check,
    DateTime Function()? clock,
  }) : _check = check,
       _clock = clock ?? DateTime.now;

  /// How often the full run comes round.
  static const fullRunEvery = Duration(days: 7);

  /// The vaults.
  final TomSecretsSession session;

  /// Where the settings and the record are kept.
  final TomSecretsPreferences preferences;

  final TomSecretsBreachCheck _check;
  final DateTime Function() _clock;
  // A run nobody listens to yet (it finished before the shell was built)
  // waits for the first listener.
  late final StreamController<TomSecretsBreachRun> _runs =
      StreamController.broadcast(
        onListen: () {
          final waiting = _unheard;
          _unheard = null;
          if (waiting != null) _runs.add(waiting);
        },
      );
  TomSecretsBreachRun? _unheard;
  TomSecretsHealthReport? _report;
  Timer? _hourly;
  bool _started = false;
  bool _disposed = false;
  int? _seenRevision;
  bool _scheduled = false;
  bool _running = false;
  bool _again = false;
  String? _lastError;
  TomSecretsBreachRun? _lastRun;

  /// Starts following the session: the report follows its vaults, the
  /// breach check runs on new and changed passwords, and an hourly look
  /// starts the weekly run when it is due.
  void start() {
    if (_started) return;
    _started = true;
    session.addListener(_onSession);
    _hourly = Timer.periodic(const Duration(hours: 1), (_) => _schedule());
    _onSession();
  }

  /// Each run of the breach check, for the notification; a run that ended
  /// before anyone listened goes to the first listener.
  Stream<TomSecretsBreachRun> get runs => _runs.stream;

  /// Whether the breach check is on (default on, DP-39).
  bool get breachEnabled =>
      preferences.read(TomSecretsHealthPreferenceKeys.breachCheck) != 'off';

  /// Turns the breach check on (it runs at once) or off.
  Future<void> setBreachEnabled(bool enabled) async {
    await preferences.write(
      TomSecretsHealthPreferenceKeys.breachCheck,
      enabled ? null : 'off',
    );
    _report = null;
    notifyListeners();
    if (enabled) _schedule();
  }

  /// The age after which a password counts as old (default one year).
  Duration get oldAfter {
    final days = int.tryParse(
      preferences.read(TomSecretsHealthPreferenceKeys.oldAfterDays) ?? '',
    );
    return Duration(days: days == null || days < 1 ? 365 : days);
  }

  /// Sets [oldAfter].
  Future<void> setOldAfter(Duration age) async {
    await preferences.write(
      TomSecretsHealthPreferenceKeys.oldAfterDays,
      '${age.inDays}',
    );
    _report = null;
    notifyListeners();
  }

  /// Counts the requests to show the Health screen (a notification's
  /// click); the shell follows it.
  int get showRequests => _showRequests;
  int _showRequests = 0;

  /// Asks the shell to show the Health screen.
  void requestShow() {
    _showRequests++;
    notifyListeners();
  }

  /// Whether a run is going on.
  bool get running => _running;

  /// Why the last run failed, or null.
  String? get lastError => _lastError;

  /// The last run in this session of the app, or null.
  TomSecretsBreachRun? get lastRun => _lastRun;

  /// When every password was last checked, or null.
  DateTime? get lastFullRun =>
      DateTime.tryParse(_record['lastFull'] as String? ?? '');

  /// The report over the open vaults (entries in the recycle bin left out).
  TomSecretsHealthReport get report => _report ??= tomSecretsHealthReport(
    _healthEntries(),
    now: _clock(),
    policy: TomSecretsHealthPolicy(oldAfter: oldAfter),
    breachCount: breachEnabled ? (e, _) => _breachCountOf(e) : null,
  );

  /// Keeps the entry [ref] out of the breach check, or lets it in again,
  /// and saves its vault.
  Future<void> setExcluded(TomSecretsEntryRef ref, bool excluded) async {
    await session.updateEntry(
      ref,
      (e) => tomSecretsSetBreachCheckExcluded(e, excluded),
    );
    _report = null;
    notifyListeners();
    if (!excluded) _schedule();
  }

  /// Checks the passwords now: all of them when [full], else the new and
  /// changed ones (and all of them when the weekly run is due). Answers the
  /// run, or null when there was nothing to check, the check is off or a
  /// run is going on.
  Future<TomSecretsBreachRun?> runNow({bool full = false}) async {
    if (_disposed || !breachEnabled || session.vaults.isEmpty) return null;
    if (_running) {
      _again = true;
      return null;
    }
    _running = true;
    _lastError = null;
    notifyListeners();
    TomSecretsBreachRun? run;
    try {
      do {
        _again = false;
        run = await _run(full: full) ?? run;
        full = false;
      } while (_again && breachEnabled && !_disposed);
    } finally {
      _running = false;
      _report = null;
      notifyListeners();
    }
    return run;
  }

  Future<TomSecretsBreachRun?> _run({required bool full}) async {
    final now = _clock();
    final record = _record;
    final entries =
        record.putIfAbsent('entries', () => <String, Object?>{})
            as Map<String, Object?>;
    final last = lastFullRun;
    final weekly = full || last == null || now.difference(last) >= fullRunEvery;
    final candidates = _candidates();
    final due = [
      for (final c in candidates)
        if (weekly || (entries[c.ref] as Map?)?['changed'] != c.changed) c,
    ];
    if (due.isEmpty) {
      if (weekly) {
        record['lastFull'] = now.toUtc().toIso8601String();
        await _save(record);
      }
      return null;
    }
    final Map<String, int> counts;
    try {
      counts = await _check.countAll(due.map((c) => c.password));
    } on TomSecretsBreachCheckException catch (e) {
      _lastError = e.message;
      return null;
    }
    var breached = 0;
    for (final c in due) {
      final count = counts[c.password] ?? 0;
      if (count > 0) breached++;
      entries[c.ref] = {'changed': c.changed, 'count': count};
    }
    if (weekly) {
      final present = {for (final c in candidates) c.ref};
      entries.removeWhere((ref, _) => !present.contains(ref));
      record['lastFull'] = now.toUtc().toIso8601String();
    }
    await _save(record);
    final run = TomSecretsBreachRun(
      checked: due.length,
      breached: breached,
      full: weekly,
      at: now,
    );
    _lastRun = run;
    if (_disposed) {
      // Dropped: nobody is left to show it.
    } else if (_runs.hasListener) {
      _runs.add(run);
    } else {
      _unheard = run;
    }
    return run;
  }

  Map<String, Object?> get _record {
    final text = preferences.read(TomSecretsHealthPreferenceKeys.breachRecord);
    if (text == null) return {};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // A record that cannot be read starts again.
    }
    return {};
  }

  Future<void> _save(Map<String, Object?> record) => preferences.write(
    TomSecretsHealthPreferenceKeys.breachRecord,
    jsonEncode(record),
  );

  int? _breachCountOf(TomSecretsHealthEntry e) {
    final entries = _record['entries'];
    if (entries is! Map) return null;
    final known = entries[_refOf(e.store, e.entry)];
    if (known is! Map) return null;
    if (known['changed'] != _changedOf(e.entry)) return null;
    return known['count'] as int?;
  }

  List<TomSecretsHealthEntry> _healthEntries() => [
    for (final view in session.index)
      if (!view.inRecycleBin) TomSecretsHealthEntry(view.ref.store, view.entry),
  ];

  List<({String ref, String changed, String password})> _candidates() => [
    for (final e in _healthEntries())
      if (e.password case final password?)
        if (!tomSecretsBreachCheckExcluded(e.entry))
          (
            ref: _refOf(e.store, e.entry),
            changed: _changedOf(e.entry),
            password: password,
          ),
  ];

  static String _refOf(String store, KdbxEntry entry) =>
      '$store/~${tomSecretsUuidHex(entry.uuid)}';

  static String _changedOf(KdbxEntry entry) =>
      tomSecretsPasswordChanged(entry)?.toUtc().toIso8601String() ?? '';

  void _onSession() {
    // The session notifies on every selection and search too; only a new
    // index (vaults loaded, saved, changed elsewhere, locked) matters here.
    if (session.indexRevision == _seenRevision) return;
    _seenRevision = session.indexRevision;
    _report = null;
    notifyListeners();
    _schedule();
  }

  /// A run after the session settles (one per burst of changes).
  void _schedule() {
    if (_scheduled || !_started) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (session.loading || session.vaults.isEmpty) return;
      unawaited(runNow());
    });
  }

  // A run outlives the app's last frame: what it finds after the dispose is
  // dropped.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _hourly?.cancel();
    if (_started) session.removeListener(_onSession);
    unawaited(_runs.close());
    super.dispose();
  }
}
