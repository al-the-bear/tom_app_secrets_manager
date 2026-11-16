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
        TomSecretsClientException;
import 'package:tom_secrets_core/tom_secrets_core.dart';

/// Where the value a request gets comes from.
enum TomSecretsValueSource {
  /// The shared entry itself.
  shared,

  /// An overlay of the entry (`@host:server1/…`).
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

  /// Every candidate as the core's resolver explains it
  /// (`TomSecretsResolver.explain`): kept ones first in rank order, then the
  /// dropped ones.
  final List<TomSecretsExplainedCandidate> steps;

  /// The entries ranking equal when [source] is ambiguous.
  final List<TomSecretsIndexedEntry> tied;

  /// Why the request failed, for [TomSecretsValueSource.malformed].
  final String? error;

  /// Where the value comes from.
  final TomSecretsValueSource source;

  /// Why [step] was dropped, for the user: the binding the request does not
  /// match; null for a kept candidate.
  String? dropReasonOf(TomSecretsExplainedCandidate step) {
    if (step.kept) return null;
    final requested = request[step.dropDimension];
    return requested == null
        ? 'bound ${step.dropDimension}:${step.dropBound}, a dimension not '
              'declared'
        : 'bound ${step.dropDimension}:${step.dropBound}, the request has '
              '$requested';
  }
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
  /// brackets: `[env:prod,host:server1]`. Throws [FormatException].
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
    try {
      reference = referenceOf(base, qualifiers);
    } on TomSecretsClientException catch (e) {
      return _failed(base, e.message);
    }
    final TomSecretsExplanation explanation;
    try {
      explanation = TomSecretsResolver(
        stores: stores,
        config: config,
        machine: _machine(const {}),
      ).explain(reference);
    } on TomSecretsResolveException catch (e) {
      return _failed(base, e.message, reference: reference);
    }
    final winner = explanation.winner;
    return TomSecretsResolved._(
      reference: reference,
      request: explanation.requestValues,
      winner: winner,
      steps: explanation.candidates,
      tied: explanation.tied,
      error: null,
      source: switch (explanation.outcome) {
        TomSecretsExplainOutcome.resolved => _sourceOf(base, winner!),
        TomSecretsExplainOutcome.ambiguous => TomSecretsValueSource.ambiguous,
        TomSecretsExplainOutcome.notFound => TomSecretsValueSource.none,
      },
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
      ).explain(secret).winner;
      return winner != null &&
          winner.store == base.store &&
          winner.hasPath(base.path);
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
