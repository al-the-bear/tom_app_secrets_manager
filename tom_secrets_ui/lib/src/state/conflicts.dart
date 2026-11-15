// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Conflicts screen's model (part-app, Screens › Conflicts; part-stores):
/// every attribute a merge recorded as changed differently on both sides
/// (`tsm.conflict`), as rows of `TomMergeView`: the value the merge kept (the
/// newer side) and the one it replaced (kept in the entry's history). A
/// confirmed decision is written into the entry and its attribute leaves the
/// record; the last one clears the record.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:tom_reusable_ui/tom_reusable_ui.dart'
    show TomMergeResolution, TomMergeRow, TomMergeSide;
import 'package:tom_secrets_core/tom_secrets_core.dart';

import 'session_state.dart';

/// The renderer kind of a conflict row.
const String tomSecretsConflictKind = 'tsm-attribute';

/// The label of the side the merge kept.
const String tomSecretsKeptSide = 'kept (newer)';

/// The label of the side the merge replaced.
const String tomSecretsReplacedSide = 'replaced (older)';

/// One version of a conflicted attribute.
final class TomSecretsConflictValue {
  /// A version: its [text] (for an attachment its name and size), whether
  /// it is [isProtected], and an attachment's [bytes].
  TomSecretsConflictValue(this.text, {this.isProtected = false, this.bytes});

  /// The text; the result pane edits it in place.
  String text;

  /// Whether the value is protected (shown masked).
  final bool isProtected;

  /// An attachment's bytes, or null.
  final Uint8List? bytes;

  /// A copy, so editing the result cannot write through to a side.
  TomSecretsConflictValue copy() =>
      TomSecretsConflictValue(text, isProtected: isProtected, bytes: bytes);
}

/// One conflicted attribute of an entry.
final class TomSecretsConflictRow extends TomMergeRow {
  TomSecretsConflictRow._({
    required this.ref,
    required this.attribute,
    required this.title,
    required this.where,
    required this.kept,
    required this.replaced,
    required this.replacedAbsent,
  });

  /// The entry.
  final TomSecretsEntryRef ref;

  /// The attribute as the record names it (`field:Password`, `tags`, …).
  final String attribute;

  /// The entry's title.
  final String title;

  /// Its store and groups.
  final String where;

  /// The value the merge kept, or null when that side removed it.
  final TomSecretsConflictValue? kept;

  /// The value the merge replaced, or null when that side removed it.
  final TomSecretsConflictValue? replaced;

  /// Why the replaced value cannot be shown, or null.
  final String? replacedAbsent;

  @override
  String get kind => tomSecretsConflictKind;

  @override
  String get locator => where;

  @override
  String get key => TomMergeRow.joinKey([ref.store, ref.uuid.uuid, attribute]);

  @override
  String get headline =>
      '${title.isEmpty ? '(untitled)' : title} · '
      '${tomSecretsAttributeLabel(attribute)}';

  @override
  String get subtitle => where;

  @override
  List<TomMergeSide> get sides => [
    TomMergeSide(tomSecretsKeptSide, kept),
    TomMergeSide(
      tomSecretsReplacedSide,
      replaced,
      absentBecause: replacedAbsent,
    ),
  ];

  @override
  TomMergeResolution get seed =>
      TomMergeResolution(value: kept?.copy(), source: tomSecretsKeptSide);

  /// Text attributes are edited in the result; an attachment or the group
  /// is taken from a side as it is.
  @override
  bool get resultEditable =>
      !attribute.startsWith('binary:') && attribute != 'group';

  @override
  Object? take(TomMergeSide side) => switch (side.value) {
    final TomSecretsConflictValue v => v.copy(),
    final other => other,
  };
}

/// An attribute as the user reads it.
String tomSecretsAttributeLabel(String attribute) => switch (attribute) {
  'tags' => 'Tags',
  'expiry' => 'Expiry',
  'group' => 'Group',
  _ when attribute.startsWith('field:') => attribute.substring(6),
  _ when attribute.startsWith('binary:') =>
    'Attachment ${attribute.substring(7)}',
  _ when attribute.startsWith('custom:') =>
    'Custom data ${attribute.substring(7)}',
  _ => attribute,
};

/// The value of [attribute] in [entry], or null when it has none.
TomSecretsConflictValue? tomSecretsAttributeOf(
  KdbxEntry entry,
  String attribute,
) {
  if (attribute.startsWith('field:')) {
    final value = entry.getString(KdbxKey(attribute.substring(6)));
    if (value == null) return null;
    return TomSecretsConflictValue(
      value.getText() ?? '',
      isProtected: value is ProtectedValue,
    );
  }
  if (attribute.startsWith('binary:')) {
    final name = attribute.substring(7);
    final binary = entry.getBinary(KdbxKey(name));
    if (binary == null) return null;
    return TomSecretsConflictValue(
      '$name (${binary.value.length} bytes)',
      isProtected: binary.isProtected,
      bytes: binary.value,
    );
  }
  if (attribute.startsWith('custom:')) {
    final value = entry.customData[attribute.substring(7)];
    return value == null ? null : TomSecretsConflictValue(value);
  }
  return switch (attribute) {
    'tags' => TomSecretsConflictValue(entry.tags.get() ?? ''),
    'expiry' => TomSecretsConflictValue(
      entry.times.expires.get() == true
          ? entry.times.expiryTime.get()?.toUtc().toIso8601String() ?? ''
          : '',
    ),
    _ => null,
  };
}

/// Writes [value] (null: remove) as [attribute] of [entry]; the group is
/// never written (the history keeps none to take).
void tomSecretsWriteAttribute(
  KdbxEntry entry,
  String attribute,
  TomSecretsConflictValue? value,
) {
  if (attribute.startsWith('field:')) {
    final key = KdbxKey(attribute.substring(6));
    if (value == null) {
      entry.removeString(key);
    } else {
      entry.setString(
        key,
        value.isProtected
            ? ProtectedValue.fromString(value.text)
            : PlainValue(value.text),
      );
    }
  } else if (attribute.startsWith('binary:')) {
    final name = attribute.substring(7);
    final current = entry.getBinary(KdbxKey(name))?.value;
    final bytes = value?.bytes;
    if (bytes != null && current != null && _same(bytes, current)) return;
    entry.removeBinary(KdbxKey(name));
    if (bytes != null) {
      entry.createBinary(
        isProtected: value!.isProtected,
        name: name,
        bytes: bytes,
      );
    }
  } else if (attribute.startsWith('custom:')) {
    final key = attribute.substring(7);
    if (value == null) {
      entry.customData.remove(key);
    } else {
      entry.customData[key] = value.text;
    }
  } else if (attribute == 'tags') {
    final text = value?.text.trim() ?? '';
    entry.tags.set(text.isEmpty ? null : text);
  } else if (attribute == 'expiry') {
    final at = DateTime.tryParse(value?.text.trim() ?? '');
    entry.times.expires.set(at != null);
    if (at != null) entry.times.expiryTime.set(at);
  }
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Removes [attribute] from [entry]'s conflict record; the record goes with
/// its last attribute.
void tomSecretsSettleAttribute(KdbxEntry entry, String attribute) {
  final left = [
    for (final c in tomSecretsConflictsOf(entry))
      if (c.fields.where((f) => f != attribute).toList() case final fields
          when fields.isNotEmpty)
        TomSecretsEntryConflict(
          entryUuid: c.entryUuid,
          fields: fields,
          loserModified: c.loserModified,
          at: c.at,
        ),
  ];
  if (left.isEmpty) {
    tomSecretsSettleConflicts(entry);
  } else {
    entry.customData[tomSecretsConflictKey] = jsonEncode([
      for (final c in left) c.toJson(),
    ]);
  }
}

/// The conflict rows of [file] (the vault of [store]), entry by entry, one
/// row per attribute; an attribute named by several records takes the most
/// recent record's replaced version. The recycle bin is left out.
List<TomSecretsConflictRow> tomSecretsConflictRows(
  String store,
  KdbxFile file,
) {
  final bin = file.recycleBin;
  final rows = <TomSecretsConflictRow>[];
  void walk(KdbxGroup group, List<String> path) {
    for (final entry in group.entries) {
      final conflicts = [...tomSecretsConflictsOf(entry)]
        ..sort((a, b) => b.at.compareTo(a.at));
      final seen = <String>{};
      for (final c in conflicts) {
        final loser = entry.history
            .where((h) => h.times.lastModificationTime.get() == c.loserModified)
            .firstOrNull;
        for (final attribute in c.fields) {
          if (!seen.add(attribute)) continue;
          final String? absent;
          if (attribute == 'group') {
            absent = 'The history keeps no group: the entry stays where it is.';
          } else if (loser == null) {
            absent = 'The replaced version is no longer in the history.';
          } else {
            absent = null;
          }
          rows.add(
            TomSecretsConflictRow._(
              ref: TomSecretsEntryRef(store, entry.uuid),
              attribute: attribute,
              title: entry.label ?? '',
              where: [store, ...path].join(' / '),
              kept: attribute == 'group'
                  ? TomSecretsConflictValue(path.join(' / '))
                  : tomSecretsAttributeOf(entry, attribute),
              replaced: absent != null
                  ? null
                  : tomSecretsAttributeOf(loser!, attribute),
              replacedAbsent: absent,
            ),
          );
        }
      }
    }
    for (final child in group.groups) {
      if (bin != null && child.uuid == bin.uuid) continue;
      walk(child, [...path, child.name.get() ?? '']);
    }
  }

  walk(file.body.rootGroup, const []);
  return rows;
}
