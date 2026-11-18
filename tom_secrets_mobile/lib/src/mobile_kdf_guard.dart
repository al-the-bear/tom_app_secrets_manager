// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// A vault too heavy for the device (part-mobile, Edge cases): Argon2's
/// memory is read from the KDBX 4 header before the key derivation runs,
/// and a file asking more than the device can spare is refused with a
/// message, instead of the system ending the app mid-derivation.
library;

import 'dart:typed_data';

import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_service/tom_secrets_service.dart';

/// The memory Argon2 takes to open the KDBX file [kdbx] (its header's
/// KdfParameters `M`), or null: a KDBX 3 file (AES-KDF), an AES-KDF KDBX 4
/// file, or bytes that are no KDBX.
int? tomSecretsArgon2MemoryOf(Uint8List kdbx) {
  final data = ByteData.sublistView(kdbx);
  if (kdbx.length < 12 ||
      data.getUint32(0, Endian.little) != 0x9AA2D903 ||
      data.getUint32(4, Endian.little) != 0xB54BFB67 ||
      data.getUint16(10, Endian.little) < 4) {
    return null;
  }
  var at = 12;
  while (at + 5 <= kdbx.length) {
    final id = kdbx[at];
    final size = data.getUint32(at + 1, Endian.little);
    at += 5;
    if (id == 0 || at + size > kdbx.length) return null;
    if (id == 11) return _memoryOfKdfParameters(kdbx, at, at + size);
    at += size;
  }
  return null;
}

int? _memoryOfKdfParameters(Uint8List bytes, int start, int end) {
  final data = ByteData.sublistView(bytes);
  var at = start + 2; // the VariantDictionary's version
  while (at + 1 <= end) {
    final type = bytes[at];
    if (type == 0 || at + 5 > end) return null;
    final keyLength = data.getInt32(at + 1, Endian.little);
    at += 5;
    if (keyLength < 0 || at + keyLength + 4 > end) return null;
    final key = String.fromCharCodes(bytes, at, at + keyLength);
    at += keyLength;
    final valueLength = data.getInt32(at, Endian.little);
    at += 4;
    if (valueLength < 0 || at + valueLength > end) return null;
    if (key == 'M' && type == 0x05 && valueLength == 8) {
      return data.getUint64(at, Endian.little);
    }
    at += valueLength;
  }
  return null;
}

/// A vault whose Argon2 asks more memory than the device can spare.
final class TomSecretsVaultTooHeavyException implements Exception {
  /// [locator] needs [needed] bytes, the device allows [limit].
  const TomSecretsVaultTooHeavyException(this.locator, this.needed, this.limit);

  /// The vault.
  final String locator;

  /// The memory its key derivation takes, in bytes.
  final int needed;

  /// What the device allows, in bytes.
  final int limit;

  /// For the user.
  String get message {
    final name = TomSecretsVaultLocator.parse(locator).fileName;
    return '$name needs ${needed >> 20} MiB of memory to open (its Argon2 '
        'setting), more than this device can spare (${limit >> 20} MiB): '
        'open it in the desktop app and lower its key derivation memory';
  }

  @override
  String toString() => 'TomSecretsVaultTooHeavyException: $message';
}

/// [inner], with every vault's Argon2 memory checked against [limit] (bytes)
/// before it is opened.
final class TomSecretsKdfGuardedOpener implements TomSecretsVaultOpener {
  /// The guard of [inner].
  const TomSecretsKdfGuardedOpener(this.inner, {required this.limit});

  /// The opener guarded.
  final TomSecretsVaultOpener inner;

  /// The most memory a key derivation may take, in bytes.
  final int limit;

  Future<void> _check(
    String locator,
    Uint8List stored, {
    String? outerKey,
  }) async {
    var kdbx = stored;
    final outer = tomSecretsOuterCodecFor(
      TomSecretsVaultLocator.parse(locator).fileName,
      outerKey,
    );
    if (outer != null) {
      try {
        kdbx = await outer.decode(stored);
      } on Object {
        // Not opened here: the opening says why (a missing or wrong key).
        return;
      }
    }
    final needed = tomSecretsArgon2MemoryOf(kdbx);
    if (needed != null && needed > limit) {
      throw TomSecretsVaultTooHeavyException(locator, needed, limit);
    }
  }

  /// The file is read first and checked, then opened: one more read of it
  /// at an unlock, which a phone holding no copy pays anyway.
  @override
  Future<TomSecretsOpenedVault> open(
    String locator,
    Credentials credentials, {
    String? outerKey,
  }) async {
    await _check(locator, await inner.read(locator), outerKey: outerKey);
    return inner.open(locator, credentials, outerKey: outerKey);
  }

  @override
  Future<KdbxFile> decode(
    String locator,
    Uint8List stored,
    Credentials credentials, {
    String? outerKey,
  }) async {
    await _check(locator, stored, outerKey: outerKey);
    return inner.decode(locator, stored, credentials, outerKey: outerKey);
  }

  @override
  Future<Uint8List> read(String locator) => inner.read(locator);

  @override
  Future<String> revision(String locator) => inner.revision(locator);

  @override
  Future<Uint8List> encode(String locator, KdbxFile file, {String? outerKey}) =>
      inner.encode(locator, file, outerKey: outerKey);

  @override
  Future<TomSecretsCommitted> commit(
    String locator,
    KdbxFile file, {
    required Uint8List base,
    required Credentials credentials,
    String? outerKey,
    Uint8List? stored,
  }) => inner.commit(
    locator,
    file,
    base: base,
    credentials: credentials,
    outerKey: outerKey,
    stored: stored,
  );

  @override
  Future<TomSecretsCommitted> rekey(
    String locator,
    KdbxFile file, {
    required Uint8List base,
    required Uint8List stored,
    String? outerKey,
  }) => inner.rekey(
    locator,
    file,
    base: base,
    stored: stored,
    outerKey: outerKey,
  );

  @override
  Future<TomSecretsOpenedVault> move(
    String from,
    String to,
    KdbxFile file, {
    required Uint8List base,
    required Uint8List stored,
    required Credentials credentials,
    String? outerKey,
  }) => inner.move(
    from,
    to,
    file,
    base: base,
    stored: stored,
    credentials: credentials,
    outerKey: outerKey,
  );

  @override
  Future<TomSecretsOpenedVault> create(
    String locator,
    KdbxFile file, {
    required Uint8List stored,
    required Credentials credentials,
    String? outerKey,
  }) => inner.create(
    locator,
    file,
    stored: stored,
    credentials: credentials,
    outerKey: outerKey,
  );

  @override
  String? rewrittenHeadOf(String locator) => inner.rewrittenHeadOf(locator);

  @override
  Future<TomSecretsCommitted> resolveRewritten(
    String locator, {
    required bool takeRemote,
  }) => inner.resolveRewritten(locator, takeRemote: takeRemote);

  @override
  void drop() => inner.drop();
}
