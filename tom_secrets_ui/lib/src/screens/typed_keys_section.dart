// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// **[C]** The entry editor's sections for the typed certificate and PGP
/// key entries (part-app, part-structure, BP-33, DP-179): what the key says
/// (validity, key length, fingerprint, expiry), generating one (ECDSA P-384,
/// RSA 4096 where a tool needs RSA), taking a file, and copying the public
/// part (the certificate, its request for a CA, the public key) to hand on.
/// Rotating is generating again: the key there before stays in the entry's
/// history.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_ui_support/tom_ui_support.dart' show tomShowNotice;

import '../ports/desktop_ports.dart';
import '../state/session_state.dart';
import '../widgets/style.dart';
import 'gate_screens.dart' show tomSecretsDescribeAdminError;

String _day(DateTime d) => d.toLocal().toIso8601String().substring(0, 10);

String _describe(Object e) => switch (e) {
  TomSecretsAdminException() => tomSecretsDescribeAdminError(e),
  TomSecretsCertificateException(:final message) => message,
  TomSecretsPgpKeyException(:final message) => message,
  FormatException(:final message) => message,
  StateError(:final message) => message,
  _ => '$e',
};

Future<void> _copy(BuildContext context, String text, String what) async {
  // Public material is no secret: the plain clipboard.
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  tomShowNotice(
    ScaffoldMessenger.maybeOf(context),
    kind: 'copied',
    message: '$what is copied.',
  );
}

Future<bool> _confirmReplace(BuildContext context, String what) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('tsm-typed-replace'),
        title: Text('Replace the $what?'),
        content: Text(
          'The entry has a $what. The new one replaces it; the old one stays '
          'in the entry\'s history. Whatever trusts the old one needs the '
          'new public part.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('tsm-typed-replace-ok'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Replace'),
          ),
        ],
      ),
    ) ??
    false;

/// A text field of [_FormDialog].
typedef _Field = ({
  String key,
  String label,
  String initial,
  bool number,
  bool obscure,
});

_Field _field(
  String key,
  String label, {
  String initial = '',
  bool number = false,
  bool obscure = false,
}) => (
  key: key,
  label: label,
  initial: initial,
  number: number,
  obscure: obscure,
);

/// A dialog of text fields and an optional checkbox, owning its
/// controllers (disposed with the dialog, after its closing animation).
/// Answers the fields' texts and the checkbox, or null when cancelled.
class _FormDialog extends StatefulWidget {
  const _FormDialog({
    super.key,
    required this.title,
    required this.fields,
    required this.okKey,
    required this.okLabel,
    this.check,
  });

  final String title;
  final List<_Field> fields;
  final String okKey;
  final String okLabel;
  final ({String key, String title, String subtitle})? check;

  @override
  State<_FormDialog> createState() => _FormDialogState();
}

class _FormDialogState extends State<_FormDialog> {
  late final List<TextEditingController> _texts = [
    for (final f in widget.fields) TextEditingController(text: f.initial),
  ];
  bool _checked = false;

  @override
  void dispose() {
    for (final t in _texts) {
      t.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final check = widget.check;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < widget.fields.length; i++)
              TextField(
                key: Key(widget.fields[i].key),
                controller: _texts[i],
                obscureText: widget.fields[i].obscure,
                keyboardType: widget.fields[i].number
                    ? TextInputType.number
                    : null,
                decoration: InputDecoration(labelText: widget.fields[i].label),
              ),
            if (check != null)
              CheckboxListTile(
                key: Key(check.key),
                value: _checked,
                contentPadding: EdgeInsets.zero,
                title: Text(check.title),
                subtitle: Text(check.subtitle),
                onChanged: (v) => setState(() => _checked = v ?? false),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: Key(widget.okKey),
          onPressed: () => Navigator.pop(context, (
            values: [for (final t in _texts) t.text.trim()],
            checked: _checked,
          )),
          child: Text(widget.okLabel),
        ),
      ],
    );
  }
}

typedef _FormAnswer = ({List<String> values, bool checked});

Future<String?> _askPassphrase(BuildContext context, String title) async {
  final answer = await showDialog<_FormAnswer>(
    context: context,
    builder: (context) => _FormDialog(
      title: title,
      fields: [
        _field(
          'tsm-typed-passphrase',
          'Its passphrase (empty when it has none)',
          obscure: true,
        ),
      ],
      okKey: 'tsm-typed-passphrase-ok',
      okLabel: 'OK',
    ),
  );
  return answer?.values.single;
}

/// The certificate section of the entry editor.
class TomSecretsCertificateSection extends StatefulWidget {
  /// The section of the entry [entryRef].
  const TomSecretsCertificateSection({
    super.key,
    required this.entryRef,
    required this.readOnly,
    this.onWritten,
  });

  /// The entry.
  final TomSecretsEntryRef entryRef;

  /// Whether its vault is read-only here.
  final bool readOnly;

  /// Called after a key was written into the entry (its type, Password and
  /// Expires changed), so the editor takes them over.
  final VoidCallback? onWritten;

  @override
  State<TomSecretsCertificateSection> createState() =>
      _CertificateSectionState();
}

class _CertificateSectionState extends State<TomSecretsCertificateSection> {
  bool _busy = false;
  String? _error;
  String? _csr;

  Future<void> _generate() async {
    final session = context.read<TomSecretsSession>();
    final entry = session.entryOf(widget.entryRef);
    if (entry == null) return;
    if (tomSecretsCertificateOf(entry) != null &&
        !await _confirmReplace(context, 'certificate')) {
      return;
    }
    if (!mounted) return;
    final answer = await showDialog<_FormAnswer>(
      context: context,
      builder: (context) => _FormDialog(
        key: const Key('tsm-cert-generate-dialog'),
        title: 'Generate a certificate',
        fields: [
          _field(
            'tsm-cert-name',
            'Common name (e.g. api.example.com)',
            initial: entry.label ?? '',
          ),
          _field('tsm-cert-sans', 'Other names, comma-separated (optional)'),
          _field(
            'tsm-cert-days',
            'Valid for days',
            initial: '365',
            number: true,
          ),
        ],
        okKey: 'tsm-cert-generate-go',
        okLabel: 'Generate',
        check: (
          key: 'tsm-cert-rsa',
          title: 'RSA 4096 (for a tool that needs RSA)',
          subtitle: 'Otherwise ECDSA on P-384.',
        ),
      ),
    );
    if (answer == null) return;
    final commonName = answer.values[0];
    final others = [
      for (final s in answer.values[1].split(','))
        if (s.trim().isNotEmpty) s.trim(),
    ];
    final valid = int.tryParse(answer.values[2]) ?? 365;
    final rsa = answer.checked;
    if (commonName.isEmpty || !mounted) return;
    await _run(() async {
      final generated = await session.generateCertificate(
        widget.entryRef,
        commonName: commonName,
        subjectAlternativeNames: others.isEmpty
            ? const []
            : [commonName, ...others],
        days: valid < 1 ? 365 : valid,
        algorithm: rsa
            ? TomSecretsCertificateAlgorithm.rsa
            : TomSecretsCertificateAlgorithm.ecdsaP384,
      );
      if (mounted) setState(() => _csr = generated.csrPem);
    });
  }

  Future<void> _pick(TomSecretsFiles files) async {
    final session = context.read<TomSecretsSession>();
    final entry = session.entryOf(widget.entryRef);
    if (entry == null) return;
    if (tomSecretsCertificateOf(entry) != null &&
        !await _confirmReplace(context, 'certificate')) {
      return;
    }
    final picked = await files.pick();
    if (picked == null || !mounted) return;
    String? passphrase;
    if (tomSecretsIsPkcs12(picked.bytes) ||
        utf8
            .decode(picked.bytes, allowMalformed: true)
            .contains('ENCRYPTED PRIVATE KEY')) {
      passphrase = await _askPassphrase(context, 'The passphrase of the key');
      if (passphrase == null || !mounted) return;
    }
    await _run(
      () => session.setCertificateFile(
        widget.entryRef,
        picked.bytes,
        passphrase: passphrase == null || passphrase.isEmpty
            ? null
            : passphrase,
      ),
    );
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
      widget.onWritten?.call();
    } on Object catch (e) {
      if (mounted) setState(() => _error = _describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    final theme = Theme.of(context);
    final entry = session.entryOf(widget.entryRef);
    final info = entry == null ? null : tomSecretsCertificateOf(entry);
    final bundle =
        entry?.getBinary(const KdbxKey(tomSecretsPkcs12Attachment)) != null;
    final certificate = entry
        ?.getBinary(const KdbxKey(tomSecretsCertificateAttachment))
        ?.value;
    final files = context.read<TomSecretsHost>().files;
    final soon =
        info != null &&
        info.notAfter.difference(DateTime.now().toUtc()).inDays < 30;
    return TomSecretsSection(
      key: const Key('tsm-cert-section'),
      title: 'Certificate',
      icon: Icons.verified_rounded,
      children: [
        if (info == null && !bundle)
          const Text(
            'No certificate yet: generate one, or choose a certificate file '
            '(PEM, or a PKCS#12 bundle).',
            key: Key('tsm-cert-none'),
          ),
        if (bundle)
          Text(
            'A PKCS#12 bundle (certificate.p12), its passphrase below. Its '
            'validity is not read: set Expires by hand.',
            key: const Key('tsm-cert-bundle'),
            style: theme.textTheme.bodySmall,
          ),
        if (info != null) ...[
          Text(
            [
              info.subject,
              info.keyDescription,
              info.selfSigned ? 'self-signed' : 'issued by ${info.issuer}',
              if (!info.hasPrivateKey) 'no private key',
            ].join(' · '),
            key: const Key('tsm-cert-summary'),
          ),
          Text(
            'Valid from ${_day(info.notBefore)} until ${_day(info.notAfter)}',
            key: const Key('tsm-cert-validity'),
            style: soon ? TextStyle(color: theme.colorScheme.error) : null,
          ),
          if (info.subjectAlternativeNames.isNotEmpty)
            Text('Names: ${info.subjectAlternativeNames.join(', ')}'),
          if (info.shortness case final why?)
            Text(
              'Short key ($why): generate a new one when the tool allows.',
              key: const Key('tsm-cert-short'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          SelectableText(
            info.sha256Fingerprint,
            key: const Key('tsm-cert-fingerprint'),
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (!widget.readOnly)
              FilledButton.tonalIcon(
                key: const Key('tsm-cert-generate'),
                icon: const Icon(Icons.auto_awesome_rounded),
                label: Text(
                  info == null
                      ? 'Generate a certificate…'
                      : 'Generate a new one…',
                ),
                onPressed: _busy ? null : () => unawaited(_generate()),
              ),
            if (!widget.readOnly && files != null)
              OutlinedButton(
                key: const Key('tsm-cert-file'),
                onPressed: _busy ? null : () => unawaited(_pick(files)),
                child: const Text('Choose a certificate file…'),
              ),
            if (certificate != null)
              OutlinedButton.icon(
                key: const Key('tsm-cert-copy'),
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Copy the certificate'),
                onPressed: () => unawaited(
                  _copy(context, utf8.decode(certificate), 'The certificate'),
                ),
              ),
            if (_csr != null)
              OutlinedButton.icon(
                key: const Key('tsm-cert-copy-csr'),
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Copy the request for a CA'),
                onPressed: () => unawaited(
                  _copy(context, _csr!, 'The certificate signing request'),
                ),
              ),
          ],
        ),
        if (_busy) const LinearProgressIndicator(key: Key('tsm-cert-busy')),
        if (_error != null)
          Text(
            _error!,
            key: const Key('tsm-cert-error'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
      ],
    );
  }
}

/// The PGP key section of the entry editor.
class TomSecretsPgpKeySection extends StatefulWidget {
  /// The section of the entry [entryRef].
  const TomSecretsPgpKeySection({
    super.key,
    required this.entryRef,
    required this.readOnly,
    this.onWritten,
  });

  /// The entry.
  final TomSecretsEntryRef entryRef;

  /// Whether its vault is read-only here.
  final bool readOnly;

  /// Called after a key was written into the entry (its type, Password and
  /// Expires changed), so the editor takes them over.
  final VoidCallback? onWritten;

  @override
  State<TomSecretsPgpKeySection> createState() => _PgpKeySectionState();
}

class _PgpKeySectionState extends State<TomSecretsPgpKeySection> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
      widget.onWritten?.call();
    } on Object catch (e) {
      if (mounted) setState(() => _error = _describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _hasKey(KdbxEntry entry) =>
      entry.getBinary(const KdbxKey(tomSecretsPgpPrivateAttachment)) != null ||
      entry.getBinary(const KdbxKey(tomSecretsPgpPublicAttachment)) != null;

  Future<void> _generate() async {
    final session = context.read<TomSecretsSession>();
    final entry = session.entryOf(widget.entryRef);
    if (entry == null) return;
    if (_hasKey(entry) && !await _confirmReplace(context, 'PGP key')) return;
    if (!mounted) return;
    final user = entry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '';
    final answer = await showDialog<_FormAnswer>(
      context: context,
      builder: (context) => _FormDialog(
        key: const Key('tsm-pgp-generate-dialog'),
        title: 'Generate a PGP key',
        fields: [
          _field(
            'tsm-pgp-user-id',
            'User id (Name <mail@example.com>)',
            initial: user.contains('@') ? '${entry.label ?? ''} <$user>' : '',
          ),
          _field(
            'tsm-pgp-years',
            'Expires after years (0: never)',
            initial: '2',
            number: true,
          ),
        ],
        okKey: 'tsm-pgp-generate-go',
        okLabel: 'Generate',
        check: (
          key: 'tsm-pgp-rsa',
          title: 'RSA 4096 (for a tool that needs RSA)',
          subtitle: 'Otherwise ECDSA on P-384 with an ECDH subkey.',
        ),
      ),
    );
    if (answer == null) return;
    final userId = answer.values[0];
    final y = int.tryParse(answer.values[1]) ?? 2;
    final rsa = answer.checked;
    if (userId.isEmpty || !mounted) return;
    await _run(
      () => session.generatePgpKey(
        widget.entryRef,
        userId: userId,
        algorithm: rsa
            ? TomSecretsPgpKeyAlgorithm.rsa
            : TomSecretsPgpKeyAlgorithm.ecdsaP384,
        expiresAfter: y <= 0 ? null : Duration(days: 365 * y),
      ),
    );
  }

  Future<void> _pick(TomSecretsFiles files) async {
    final session = context.read<TomSecretsSession>();
    final entry = session.entryOf(widget.entryRef);
    if (entry == null) return;
    if (_hasKey(entry) && !await _confirmReplace(context, 'PGP key')) return;
    final picked = await files.pick();
    if (picked == null || !mounted) return;
    String? passphrase;
    if (utf8
        .decode(picked.bytes, allowMalformed: true)
        .contains('PRIVATE KEY BLOCK')) {
      passphrase = await _askPassphrase(context, 'The passphrase of the key');
      if (passphrase == null || !mounted) return;
    }
    await _run(
      () => session.setPgpKeyFile(
        widget.entryRef,
        Uint8List.fromList(picked.bytes),
        passphrase: passphrase == null || passphrase.isEmpty
            ? null
            : passphrase,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    final theme = Theme.of(context);
    final entry = session.entryOf(widget.entryRef);
    final info = entry == null ? null : tomSecretsPgpKeyOf(entry);
    final public = entry
        ?.getBinary(const KdbxKey(tomSecretsPgpPublicAttachment))
        ?.value;
    final files = context.read<TomSecretsHost>().files;
    String grouped(String hex) => [
      for (var i = 0; i < hex.length; i += 4)
        hex.substring(i, i + 4 > hex.length ? hex.length : i + 4),
    ].join(' ');
    return TomSecretsSection(
      key: const Key('tsm-pgp-section'),
      title: 'PGP key',
      icon: Icons.key_rounded,
      children: [
        if (entry != null && !_hasKey(entry))
          const Text(
            'No key yet: generate one, or choose an armoured key file (a '
            'secret key, or someone\'s public key).',
            key: Key('tsm-pgp-none'),
          )
        else if (info == null)
          Text(
            'A key this app does not read (RSA below 2048 bits, or an old '
            'version): kept and served as it is.',
            style: theme.textTheme.bodySmall,
          ),
        if (info != null) ...[
          Text(
            [
              info.userIds.join(', '),
              info.keyDescription,
              info.isPrivate ? 'secret key' : 'public key only',
            ].join(' · '),
            key: const Key('tsm-pgp-summary'),
          ),
          Text(
            info.expires == null
                ? 'Made ${_day(info.created)}, does not expire'
                : 'Made ${_day(info.created)}, expires ${_day(info.expires!)}',
            key: const Key('tsm-pgp-validity'),
          ),
          if (info.shortness case final why?)
            Text(
              'Short key ($why): generate a new one when the tools allow.',
              key: const Key('tsm-pgp-short'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          SelectableText(
            grouped(info.fingerprint),
            key: const Key('tsm-pgp-fingerprint'),
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (!widget.readOnly)
              FilledButton.tonalIcon(
                key: const Key('tsm-pgp-generate'),
                icon: const Icon(Icons.auto_awesome_rounded),
                label: Text(
                  info == null ? 'Generate a key…' : 'Generate a new one…',
                ),
                onPressed: _busy ? null : () => unawaited(_generate()),
              ),
            if (!widget.readOnly && files != null)
              OutlinedButton(
                key: const Key('tsm-pgp-file'),
                onPressed: _busy ? null : () => unawaited(_pick(files)),
                child: const Text('Choose a key file…'),
              ),
            if (public != null)
              OutlinedButton.icon(
                key: const Key('tsm-pgp-copy'),
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Copy the public key'),
                onPressed: () => unawaited(
                  _copy(context, utf8.decode(public), 'The public key'),
                ),
              ),
          ],
        ),
        if (_busy) const LinearProgressIndicator(key: Key('tsm-pgp-busy')),
        if (_error != null)
          Text(
            _error!,
            key: const Key('tsm-pgp-error'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
      ],
    );
  }
}
