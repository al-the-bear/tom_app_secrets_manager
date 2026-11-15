// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Resolution as the app shows it (part-app, Overlay editor; part-structure):
/// the open vaults as the service's resolver sees them, the overlay matrix of
/// an entry, "which value does … get?" step by step, the dimension values a
/// matrix has rows for, and which clients read an entry (the vault-aware
/// view, BP-25).
library;

import 'package:tom_secrets_client/tom_secrets_client.dart'
    show
        TomSecretBinding,
        TomSecretKeyTarget,
        TomSecretPathTarget,
        TomSecretReference,
        TomSecretsClientException,
        TomSecretsErrorKind;
import 'package:tom_secrets_core/tom_secrets_core.dart';

/// Where the value a request gets comes from.
enum TomSecretsValueSource {
  /// The shared entry itself.
  shared,

  /// An overlay of the entry (`@host:bomber/…`).
  overlay,

  /// An entry with the same key in another file (an environment's file).
  otherFile,

  /// No entry serves the request.
  none,

  /// Several entries rank equal: resolution refuses (marked red).
  ambiguous,

  /// The request itself is malformed (an undeclared dimension).
  malformed,
}

/// The field resolution is asked for when only the winning entry matters:
/// every entry has a title (the overlays copy it).
const String _probeField = 'Title';

/// One step of "which value does … get?": a candidate and what resolution
/// did with it.
final class TomSecretsCandidateStep {
  const TomSecretsCandidateStep._(this.entry, this.vector, this.dropReason);

  /// The candidate.
  final TomSecretsIndexedEntry entry;

  /// Its rank vector (one rank per dimension in priority order), or null
  /// when it was dropped.
  final List<int>? vector;

  /// Why it was dropped: the binding the request does not match.
  final String? dropReason;

  /// Whether it was kept.
  bool get kept => vector != null;
}

/// What one request resolves to, with the steps that led there.
final class TomSecretsResolved {
  const TomSecretsResolved._({
    required this.reference,
    required this.request,
    required this.winner,
    required this.steps,
    required this.tied,
    required this.error,
    required this.source,
  });

  /// The reference asked (canonical form).
  final String reference;

  /// The request's value of every dimension, in priority order.
  final Map<String, String> request;

  /// The entry that serves it, or null.
  final TomSecretsIndexedEntry? winner;

  /// Every candidate, kept ones first in rank order, then the dropped.
  final List<TomSecretsCandidateStep> steps;

  /// The entries ranking equal when [source] is ambiguous.
  final List<TomSecretsIndexedEntry> tied;

  /// Why the request failed, for [TomSecretsValueSource.malformed].
  final String? error;

  /// Where the value comes from.
  final TomSecretsValueSource source;
}

/// One row of the overlay matrix: a dimension value and what it gets.
final class TomSecretsMatrixRow {
  const TomSecretsMatrixRow._(
    this.dimension,
    this.value,
    this.resolved,
    this.ownOverlay,
  );

  /// The dimension.
  final String dimension;

  /// Its value.
  final String value;

  /// What a request naming it gets.
  final TomSecretsResolved resolved;

  /// The entry's overlay bound to exactly this value (`@<dimension>:<value>`),
  /// or null: the cell to edit, or the one a click creates.
  final TomSecretsIndexedEntry? ownOverlay;
}

/// The open vaults as the resolver sees them: the configuration of the
/// primary (the first vault) and every vault as a store.
final class TomSecretsResolutionModel {
  TomSecretsResolutionModel._(this.config, this.stores, this.warnings);

  /// The model of [vaults] (store name and file, the primary first).
  factory TomSecretsResolutionModel.build(
    List<({String store, KdbxFile file})> vaults,
  ) {
    final warnings = <String>[];
    var config = TomSecretsConfig.builtIn();
    if (vaults.isNotEmpty) {
      try {
        config = TomSecretsMetadata.read(vaults.first.file).config ?? config;
      } on TomSecretsMetadataException catch (e) {
        warnings.add('the primary\'s metadata: ${e.message}');
      } on TomSecretsConfigException catch (e) {
        warnings.add('the configuration: ${e.message}');
      }
    }
    final stores = [
      for (final v in vaults) TomSecretsStore.fromFile(v.file, name: v.store),
    ];
    for (final s in stores) {
      warnings.addAll(s.warnings.map((w) => '${s.name}: $w'));
    }
    return TomSecretsResolutionModel._(config, stores, warnings);
  }

  /// The shared configuration (the dimensions in priority order).
  final TomSecretsConfig config;

  /// Every open vault as a store.
  final List<TomSecretsStore> stores;

  /// What the index skipped and why, and a configuration that did not read.
  final List<String> warnings;

  final Map<String, List<TomSecretsGrantUse>> _readers = {};

  /// The store [name], or null.
  TomSecretsStore? store(String name) =>
      stores.where((s) => s.name == name).firstOrNull;

  /// The indexed entry [uuid] of [storeName], or null (not indexed: the
  /// recycle bin, the product's own groups).
  TomSecretsIndexedEntry? indexed(String storeName, KdbxUuid uuid) =>
      store(storeName)?.entries.where((e) => e.entry.uuid == uuid).firstOrNull;

  /// The overlays of [base] in its store: the entries at its path bound by
  /// overlay groups.
  List<TomSecretsIndexedEntry> overlaysOf(TomSecretsIndexedEntry base) => [
    for (final e in store(base.store)?.entries ?? const [])
      if (e.isOverlay && e.hasPath(base.path)) e,
  ];

  /// The reference clients name [base] by: its key when it has one (so the
  /// other environments' files take part), else its path; with [qualifiers].
  String referenceOf(
    TomSecretsIndexedEntry base, [
    List<TomSecretBinding> qualifiers = const [],
  ]) => TomSecretReference.format(
    TomSecretReference(
      qualifiers: qualifiers,
      target: base.key != null
          ? TomSecretKeyTarget(base.key!)
          : TomSecretPathTarget(base.store, base.path),
    ),
  );

  /// The machine of a request that names [values]: every other dimension
  /// takes its configured default, else `default`.
  TomSecretsMachine _machine(Map<String, String> values) {
    String of(String d) =>
        values[d] ??
        config.dimension(d)?.defaultValue ??
        tomSecretsDefaultValue;
    return TomSecretsMachine(
      host: of('host'),
      platform: of('platform'),
      values: {
        for (final d in config.dimensions)
          if (d.name != 'host' && d.name != 'platform') d.name: of(d.name),
      },
    );
  }

  /// The values a dimension has rows for in the matrix: hosts from the
  /// grants and the devices of the primary (`@host:<host>` groups) and from
  /// every binding; platforms from the platform list; environments from the
  /// configured files; every dimension's configured default; and every value
  /// some entry or file is bound to.
  List<String> valuesOf(String dimension) {
    final values = <String>{};
    if (dimension == 'platform') values.addAll(tomSecretsPlatforms);
    if (dimension == 'env') values.addAll(config.stores.keys);
    if (config.dimension(dimension)?.defaultValue case final d?) values.add(d);
    if (dimension == 'host' && stores.isNotEmpty) {
      values.addAll(TomSecretsGrantsGroup(stores.first.file).hosts);
    }
    for (final s in stores) {
      if (s.metadata.binding[dimension] case final v?) values.add(v);
      for (final g in s.file.body.rootGroup.groups) {
        final binding = tomSecretsOverlayBinding(g.name.get() ?? '');
        if (binding != null && binding.$1 == dimension) values.add(binding.$2);
      }
      for (final e in s.entries) {
        if (e.bindings[dimension] case final v?) values.add(v);
      }
    }
    values.remove('');
    return values.toList()..sort();
  }

  /// The overlay matrix of [base]: per dimension (priority order) one row
  /// per value.
  List<TomSecretsMatrixRow> matrix(TomSecretsIndexedEntry base) {
    final overlays = overlaysOf(base);
    return [
      for (final d in config.dimensions)
        for (final value in valuesOf(d.name))
          TomSecretsMatrixRow._(
            d.name,
            value,
            resolve(base, [TomSecretBinding(d.name, value)]),
            overlays
                .where(
                  (o) =>
                      o.overlayBindings.length == 1 &&
                      o.overlayBindings[d.name] == value,
                )
                .firstOrNull,
          ),
    ];
  }

  /// Parses qualifiers as the reference writes them, with or without the
  /// brackets: `[env:prod,host:bomber]`. Throws [FormatException].
  static List<TomSecretBinding> parseQualifiers(String text) {
    var t = text.trim();
    if (t.startsWith('[')) t = t.substring(1);
    if (t.endsWith(']')) t = t.substring(0, t.length - 1);
    final out = <TomSecretBinding>[];
    for (final part in t.split(',')) {
      final p = part.trim();
      if (p.isEmpty) continue;
      final colon = p.indexOf(':');
      if (colon < 1 || colon == p.length - 1) {
        throw FormatException('"$p" is not <dimension>:<value>');
      }
      out.add(
        TomSecretBinding(
          p.substring(0, colon).trim(),
          p.substring(colon + 1).trim(),
        ),
      );
    }
    return out;
  }

  /// What a request for [base] with [qualifiers] gets, step by step; the
  /// dimensions it does not name take their defaults.
  TomSecretsResolved resolve(
    TomSecretsIndexedEntry base, [
    List<TomSecretBinding> qualifiers = const [],
  ]) {
    final String reference;
    final TomSecretReference parsed;
    try {
      reference = referenceOf(base, qualifiers);
      parsed = TomSecretReference.parse(reference);
    } on TomSecretsClientException catch (e) {
      return _failed(base, e.message);
    }
    final resolver = TomSecretsResolver(
      stores: stores,
      config: config,
      machine: _machine(const {}),
    );
    final Map<String, String> request;
    try {
      request = resolver.requestValues(parsed, const {});
    } on TomSecretsResolveException catch (e) {
      return _failed(base, e.message, reference: reference);
    }
    final steps = _steps(base, request);
    TomSecretsIndexedEntry? winner;
    var tied = const <TomSecretsIndexedEntry>[];
    TomSecretsValueSource source;
    try {
      winner = resolver.resolve(reference, field: _probeField).entry;
      source = _sourceOf(base, winner);
    } on TomSecretsResolveException catch (e) {
      switch (e.kind) {
        case TomSecretsErrorKind.ambiguous:
          tied = [
            for (final c
                in (e.details['candidates'] as List? ?? const []).cast<Map>())
              ?_byUuidHex(c['store'] as String?, c['uuid'] as String?),
          ];
          source = TomSecretsValueSource.ambiguous;
        case TomSecretsErrorKind.notFound:
          // The winner lacks the probe field: resolution names it.
          final entry = e.details['entry'];
          winner = entry is Map
              ? _byUuidHex(entry['store'] as String?, entry['uuid'] as String?)
              : null;
          source = winner == null
              ? TomSecretsValueSource.none
              : _sourceOf(base, winner);
        default:
          return _failed(base, e.message, reference: reference);
      }
    }
    return TomSecretsResolved._(
      reference: reference,
      request: request,
      winner: winner,
      steps: steps,
      tied: tied,
      error: null,
      source: source,
    );
  }

  TomSecretsResolved _failed(
    TomSecretsIndexedEntry base,
    String message, {
    String? reference,
  }) => TomSecretsResolved._(
    reference: reference ?? referenceOf(base),
    request: const {},
    winner: null,
    steps: const [],
    tied: const [],
    error: message,
    source: TomSecretsValueSource.malformed,
  );

  TomSecretsIndexedEntry? _byUuidHex(String? storeName, String? uuid) =>
      store(storeName ?? '')?.entries.where((e) => e.uuid == uuid).firstOrNull;

  TomSecretsValueSource _sourceOf(
    TomSecretsIndexedEntry base,
    TomSecretsIndexedEntry winner,
  ) {
    if (winner.store != base.store) return TomSecretsValueSource.otherFile;
    if (winner.entry.uuid == base.entry.uuid) {
      return TomSecretsValueSource.shared;
    }
    return winner.isOverlay
        ? TomSecretsValueSource.overlay
        : TomSecretsValueSource.otherFile;
  }

  /// The candidates of [base]'s reference with what ranking does to each.
  ///
  /// Why: the resolver reports only the kept candidates; the steps also show
  /// the dropped ones and why. Candidates and ranks follow part-structure's
  /// rules as `TomSecretsResolver` implements them (step 1: the entries at
  /// the path, or with the key and their overlays; step 2: drop a candidate
  /// bound to another value than the request's, unless bound to `default`
  /// with the fallback on; rank 2 bound to the request's value, 1 to
  /// `default`, 0 unbound).
  List<TomSecretsCandidateStep> _steps(
    TomSecretsIndexedEntry base,
    Map<String, String> request,
  ) {
    final candidates = <TomSecretsIndexedEntry>[];
    void add(TomSecretsIndexedEntry e) {
      if (!candidates.any((c) => identical(c, e))) candidates.add(e);
    }

    final key = base.key;
    if (key == null) {
      store(
        base.store,
      )?.entries.where((e) => e.hasPath(base.path)).forEach(add);
    } else {
      for (final s in stores) {
        for (final keyed in s.entries.where((e) => e.key == key)) {
          add(keyed);
          s.entries
              .where(
                (e) =>
                    e.isOverlay &&
                    e.hasPath(keyed.path) &&
                    (e.key == null || e.key == key),
              )
              .forEach(add);
        }
      }
    }
    final kept = <TomSecretsCandidateStep>[];
    final dropped = <TomSecretsCandidateStep>[];
    for (final c in candidates) {
      String? reason;
      for (final MapEntry(key: dimension, value: bound) in c.bindings.entries) {
        final d = config.dimension(dimension);
        final requested = request[dimension];
        if (d == null) {
          reason = 'bound $dimension:$bound, a dimension not declared';
          break;
        }
        if (bound != requested &&
            !(bound == tomSecretsDefaultValue && d.fallbackToDefault)) {
          reason = 'bound $dimension:$bound, the request has $requested';
          break;
        }
      }
      if (reason != null) {
        dropped.add(TomSecretsCandidateStep._(c, null, reason));
        continue;
      }
      kept.add(
        TomSecretsCandidateStep._(c, [
          for (final d in config.dimensions)
            switch (c.bindings[d.name]) {
              null => 0,
              final bound when bound == request[d.name] => 2,
              _ => 1,
            },
        ], null),
      );
    }
    int compare(List<int> a, List<int> b) {
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return b[i] - a[i];
      }
      return 0;
    }

    kept.sort((a, b) => compare(a.vector!, b.vector!));
    return [...kept, ...dropped];
  }

  /// The clients granted [base] on any host (`allow` grants of the primary
  /// not revoked): a grant for every secret, for the entry's store, or for a
  /// reference that resolves to the entry or one of its overlays on the
  /// grant's host. Cached for the model's life.
  List<TomSecretsGrantUse> readersOf(TomSecretsIndexedEntry base) =>
      _readers.putIfAbsent('${base.store}/${base.uuid}', () {
        if (stores.isEmpty) return const [];
        final grants = TomSecretsGrantsGroup(stores.first.file);
        final out = <TomSecretsGrantUse>[];
        for (final host in grants.hosts) {
          final revoked = {
            for (final r in grants.read(host, TomSecretsSignedKind.revocation))
              r['grantId'],
          };
          for (final g in grants.read(host, TomSecretsSignedKind.grant)) {
            if (g['decision'] != 'allow' || revoked.contains(g['id'])) {
              continue;
            }
            final secret = g['secret'] as String? ?? '';
            if (!_grantCovers(secret, host, base)) continue;
            out.add(
              TomSecretsGrantUse(
                host: host,
                subject: g['subject'] as String? ?? '',
                secret: secret,
                lastUsed: DateTime.tryParse(g['lastUsed'] as String? ?? ''),
              ),
            );
          }
        }
        out.sort(
          (a, b) =>
              (b.lastUsed ?? DateTime(0)).compareTo(a.lastUsed ?? DateTime(0)),
        );
        return out;
      });

  bool _grantCovers(String secret, String host, TomSecretsIndexedEntry base) {
    if (secret == 'all') return true;
    if (secret.startsWith('store ')) return secret.substring(6) == base.store;
    try {
      final winner = TomSecretsResolver(
        stores: stores,
        config: config,
        machine: _machine({'host': host}),
      ).resolve(secret, field: _probeField).entry;
      return winner.store == base.store && winner.hasPath(base.path);
    } on TomSecretsResolveException {
      return false;
    }
  }
}

/// A client granted an entry: on [host], [subject] (an executable, a
/// script, a folder), by the grant's [secret], last used at [lastUsed].
final class TomSecretsGrantUse {
  /// A use.
  const TomSecretsGrantUse({
    required this.host,
    required this.subject,
    required this.secret,
    required this.lastUsed,
  });

  /// The host the grant is for.
  final String host;

  /// Who.
  final String subject;

  /// What the grant names: `all`, `store <name>` or a reference.
  final String secret;

  /// When it was last used, or null.
  final DateTime? lastUsed;
}
