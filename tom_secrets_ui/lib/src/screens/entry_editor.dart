// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The entry editor (part-app, Screens › Entry editor, phase A): login, API
/// token and secure note; title, user name, the password with the generator,
/// URLs, TOTP with its countdown, custom fields (protected or not), tags,
/// expiry, attachments; "How clients name it"; the history with Restore.
/// Protected values are masked, revealed one at a time for a limited time and
/// copied through the protected clipboard. A confirmed change is saved
/// through the service.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:tom_basics/utilities.dart' show TomProtectedClipboard;
import 'package:tom_ui_support/tom_ui_support.dart' show tomShowNotice;
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;
import 'package:tom_secrets_client/tom_secrets_client.dart'
    show TomSecretPathTarget, TomSecretReference;
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../ports/desktop_ports.dart';
import '../state/auto_type.dart';
import '../state/session_state.dart';
import '../widgets/generator_dialog.dart';
import '../widgets/protected_field.dart';
import '../widgets/style.dart';
import '../widgets/totp_view.dart';
import 'attachment_viewer.dart';
import 'gate_screens.dart' show tomSecretsDescribeAdminError;
import 'overlay_editor.dart' show tomSecretsShowOverlayEditor;
import 'share_dialogs.dart' show tomSecretsShowShareDialog;
import 'typed_keys_section.dart';

/// The fields the editor shows in their own places; every other non-reserved
/// string field is a custom field.
final Set<String> _ownFields = {
  KdbxKeyCommon.TITLE.key,
  KdbxKeyCommon.USER_NAME.key,
  KdbxKeyCommon.PASSWORD.key,
  KdbxKeyCommon.URL.key,
  KdbxKeyCommon.NOTES.key,
  TomSecretsTotpFields.otp.key,
  TomSecretsTotpFields.otpAuth.key,
  TomSecretsTotpFields.secretBase32.key,
  TomSecretsTotpFields.length.key,
  TomSecretsTotpFields.period.key,
  TomSecretsTotpFields.algorithm.key,
};

/// Whether the editor leaves [field] alone: the product's own `tsm.*`
/// fields (the key and type have their own controls), passkeys and the
/// extra URLs (shown as URLs).
bool _hidden(String field) =>
    tomSecretsIsReservedName(field) ||
    tomSecretsIsPasskeyField(field) ||
    field.startsWith(TomSecretsEntryFields.extraUrlPrefix);

final RegExp _keyPattern = RegExp(r'^[a-z][a-z0-9_-]*(\.[a-z][a-z0-9_-]*)*$');

/// The editor of [ref].
class TomSecretsEntryEditor extends StatefulWidget {
  /// The editor of [ref]; [clipboard] clears what it copies.
  const TomSecretsEntryEditor({
    super.key,
    required this.ref,
    required this.clipboard,
    this.generator,
  });

  /// The entry.
  final TomSecretsEntryRef ref;

  /// The protected clipboard.
  final TomProtectedClipboard clipboard;

  /// The password generator (default a secure one).
  final TomSecretsPasswordGenerator? generator;

  @override
  State<TomSecretsEntryEditor> createState() => _EntryEditorState();
}

final class _CustomField {
  _CustomField(String name, String value, this.protected)
    : name = TextEditingController(text: name),
      value = TextEditingController(text: value);

  final TextEditingController name;
  final TextEditingController value;
  bool protected;

  void dispose() {
    name.dispose();
    value.dispose();
  }
}

class _EntryEditorState extends State<TomSecretsEntryEditor> {
  final _title = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _notes = TextEditingController();
  final _otp = TextEditingController();
  final _key = TextEditingController();
  final _tags = TextEditingController();
  final List<TextEditingController> _urls = [];
  final List<_CustomField> _custom = [];
  final TomSecretsRevealController _reveal = TomSecretsRevealController();
  TomSecretsEntryType _type = TomSecretsEntryType.login;
  bool _expires = false;
  bool _breachExcluded = false;
  // Auto-type (the KDBX AutoType element).
  bool _autoTypeOn = true;
  final _autoTypeSequence = TextEditingController();
  final List<(TextEditingController, TextEditingController)> _windows = [];
  DateTime? _expiry;
  bool _dirty = false;
  bool _saving = false;
  String? _keyError;
  String? _otpError;
  bool _keyBusy = false;
  String? _sshError;

  TomSecretsSession get _session => context.read<TomSecretsSession>();

  @override
  void initState() {
    super.initState();
    _load();
    for (final c in [_title, _user, _password, _notes, _otp, _key, _tags]) {
      c.addListener(_touched);
    }
  }

  void _touched() {
    if (!_dirty && mounted) setState(() => _dirty = true);
  }

  void _load() {
    final entry = context.read<TomSecretsSession>().entryOf(widget.ref);
    if (entry == null) return;
    String text(KdbxKey key) => entry.getString(key)?.getText() ?? '';
    _title.text = entry.label ?? '';
    _user.text = text(KdbxKeyCommon.USER_NAME);
    _password.text = text(KdbxKeyCommon.PASSWORD);
    _notes.text = text(KdbxKeyCommon.NOTES);
    _otp.text = TomSecretsTotp.fromEntry(entry)?.toUri() ?? '';
    _key.text = text(TomSecretsEntryFields.key);
    _tags.text = tomSecretsTagsOf(entry).join(', ');
    _type = TomSecretsEntryType.of(text(TomSecretsEntryFields.type));
    _expires = entry.times.expires.get() == true;
    _breachExcluded = tomSecretsBreachCheckExcluded(entry);
    final autoType = entry.autoType;
    _autoTypeOn = autoType.enabled;
    _autoTypeSequence.text = autoType.defaultSequence ?? '';
    for (final (w, q) in _windows) {
      w.dispose();
      q.dispose();
    }
    _windows
      ..clear()
      ..addAll([
        for (final a in autoType.associations)
          (
            TextEditingController(text: a.window),
            TextEditingController(text: a.sequence),
          ),
      ]);
    _expiry = entry.times.expiryTime.get();
    for (final c in _urls) {
      c.dispose();
    }
    _urls
      ..clear()
      ..add(TextEditingController(text: text(KdbxKeyCommon.URL)))
      ..addAll([
        for (final MapEntry(:key, :value) in entry.stringEntries)
          if (key.key.startsWith(TomSecretsEntryFields.extraUrlPrefix))
            TextEditingController(text: value?.getText() ?? ''),
      ]);
    for (final f in _custom) {
      f.dispose();
    }
    _custom
      ..clear()
      ..addAll([
        for (final MapEntry(:key, :value) in entry.stringEntries)
          if (!_ownFields.contains(key.key) && !_hidden(key.key))
            _CustomField(
              key.key,
              value?.getText() ?? '',
              value is ProtectedValue,
            ),
      ]);
    for (final c in [
      ..._urls,
      ..._custom.expand((f) => [f.name, f.value]),
    ]) {
      c.addListener(_touched);
    }
    _dirty = false;
    _keyError = null;
    _otpError = null;
  }

  /// The key's problem, or null: its grammar, and no other entry of the
  /// store outside the overlays carrying it (BP-20).
  String? _checkKey(String key) {
    if (key.isEmpty) return null;
    if (!_keyPattern.hasMatch(key)) {
      return 'a key is lower-case dotted names: telegram.bot_token';
    }
    final taken = _session.index.any(
      (e) =>
          e.ref.store == widget.ref.store &&
          e.ref != widget.ref &&
          e.key == key,
    );
    return taken ? 'another entry of this vault has this key' : null;
  }

  TomSecretsTotp? _parseOtp(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    final uri = TomSecretsTotp.tryParseUri(t);
    if (uri != null) return uri;
    final secret = tomSecretsBase32Decode(t);
    if (secret == null || secret.isEmpty) {
      throw const FormatException(
        'neither an otpauth:// URI nor a base32 secret',
      );
    }
    return TomSecretsTotp(secret);
  }

  /// The TOTP secret read from its QR code (an `otpauth://` URI, as the
  /// service's setup page shows it): put in the field to save.
  Future<void> _scanOtp(TomSecretsCodeScanner scanner) async {
    final text = await scanner.scan(
      context,
      title: 'Scan the one-time code\'s QR code',
    );
    if (text == null || !mounted) return;
    String? problem;
    try {
      if (_parseOtp(text) == null) problem = 'the QR code is empty';
    } on FormatException catch (e) {
      problem = 'the QR code holds ${e.message}';
    }
    setState(() {
      _otpError = problem;
      if (problem == null) {
        _otp.text = text.trim();
        _dirty = true;
      }
    });
  }

  Future<void> _save() async {
    final keyError = _checkKey(_key.text.trim());
    TomSecretsTotp? totp;
    String? otpError;
    try {
      totp = _parseOtp(_otp.text);
    } on FormatException catch (e) {
      otpError = e.message;
    }
    setState(() {
      _keyError = keyError;
      _otpError = otpError;
    });
    if (keyError != null || otpError != null) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await _session.updateEntry(widget.ref, (entry) => _apply(entry, totp));
      _load();
      tomShowNotice(messenger, kind: 'entry-saved', message: 'Saved');
    } on TomSecretsAdminException catch (e) {
      tomShowNotice(
        messenger,
        kind: 'entry-saved',
        message: tomSecretsDescribeAdminError(e),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _apply(KdbxEntry entry, TomSecretsTotp? totp) {
    entry.modify(() {
      entry.label = _title.text;
      entry.setString(KdbxKeyCommon.USER_NAME, PlainValue(_user.text));
      entry.setString(
        KdbxKeyCommon.PASSWORD,
        ProtectedValue.fromString(_password.text),
      );
      entry.setString(KdbxKeyCommon.NOTES, PlainValue(_notes.text));
      final urls = _urls.map((c) => c.text.trim()).toList();
      entry.setString(
        KdbxKeyCommon.URL,
        PlainValue(urls.isEmpty ? '' : urls.first),
      );
      for (final MapEntry(:key) in entry.stringEntries.toList()) {
        if (key.key.startsWith(TomSecretsEntryFields.extraUrlPrefix)) {
          entry.removeString(key);
        }
      }
      final extra = urls.skip(1).where((u) => u.isNotEmpty).toList();
      for (var i = 0; i < extra.length; i++) {
        entry.setString(
          KdbxKey(
            i == 0
                ? TomSecretsEntryFields.extraUrlPrefix
                : '${TomSecretsEntryFields.extraUrlPrefix}_$i',
          ),
          PlainValue(extra[i]),
        );
      }
      final key = _key.text.trim();
      if (key.isEmpty) {
        entry.removeString(TomSecretsEntryFields.key);
      } else {
        entry.setString(TomSecretsEntryFields.key, PlainValue(key));
      }
      if (_breachExcluded) {
        entry.setString(tomSecretsBreachCheckField, PlainValue('off'));
      } else {
        entry.removeString(tomSecretsBreachCheckField);
      }
      if (_type == TomSecretsEntryType.login) {
        entry.removeString(TomSecretsEntryFields.type);
      } else {
        entry.setString(TomSecretsEntryFields.type, PlainValue(_type.wireName));
      }
      final keep = <String>{};
      for (final f in _custom) {
        final name = f.name.text.trim();
        if (name.isEmpty || _ownFields.contains(name) || _hidden(name)) {
          continue;
        }
        keep.add(name);
        entry.setString(
          KdbxKey(name),
          f.protected
              ? ProtectedValue.fromString(f.value.text)
              : PlainValue(f.value.text),
        );
      }
      for (final MapEntry(:key) in entry.stringEntries.toList()) {
        if (!_ownFields.contains(key.key) &&
            !_hidden(key.key) &&
            !keep.contains(key.key)) {
          entry.removeString(key);
        }
      }
      for (final k in [
        TomSecretsTotpFields.otp,
        TomSecretsTotpFields.otpAuth,
        TomSecretsTotpFields.secretBase32,
        TomSecretsTotpFields.length,
        TomSecretsTotpFields.period,
        TomSecretsTotpFields.algorithm,
      ]) {
        entry.removeString(k);
      }
      totp?.writeTo(entry);
      entry.tags.set(
        _tags.text
            .split(RegExp(r'[,;]'))
            .map((t) => t.trim())
            .where((t) => t.isNotEmpty)
            .join(';'),
      );
      entry.times.expires.set(_expires && _expiry != null);
      if (_expires && _expiry != null) entry.times.expiryTime.set(_expiry);
      final sequence = _autoTypeSequence.text.trim();
      final autoType = KdbxAutoTypeSettings(
        enabled: _autoTypeOn,
        defaultSequence: sequence.isEmpty ? null : sequence,
        associations: [
          for (final (w, q) in _windows)
            if (w.text.trim().isNotEmpty)
              KdbxAutoTypeAssociation(w.text.trim(), q.text.trim()),
        ],
      );
      if (entry.autoType != autoType) entry.autoType = autoType;
    });
  }

  Future<void> _restore(KdbxEntry version) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await _session.updateEntry(widget.ref, (entry) {
        entry.modify(() {
          for (final MapEntry(:key) in entry.stringEntries.toList()) {
            entry.removeString(key);
          }
          for (final MapEntry(:key, :value) in version.stringEntries) {
            entry.setString(key, value);
          }
          entry.tags.set(version.tags.get());
        });
      });
      _load();
      tomShowNotice(messenger, kind: 'entry-saved', message: 'Restored');
    } on TomSecretsAdminException catch (e) {
      tomShowNotice(
        messenger,
        kind: 'entry-saved',
        message: tomSecretsDescribeAdminError(e),
      );
    }
  }

  Future<void> _addAttachment() async {
    final files = context.read<TomSecretsHost>().files;
    final picked = await files?.pick();
    if (picked == null) return;
    await _session.updateEntry(
      widget.ref,
      (entry) => entry.createBinary(
        isProtected: false,
        name: picked.name,
        bytes: picked.bytes,
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _autoTypeSequence.dispose();
    for (final (w, q) in _windows) {
      w.dispose();
      q.dispose();
    }
    for (final c in [
      _title,
      _user,
      _password,
      _notes,
      _otp,
      _key,
      _tags,
      ..._urls,
    ]) {
      c.dispose();
    }
    for (final f in _custom) {
      f.dispose();
    }
    _reveal.dispose();
    super.dispose();
  }

  /// Generates a key into the entry ([algorithm], DP-179), or takes a key
  /// file the user picks; a key already there is replaced after asking (the
  /// old one stays in the entry's history).
  Future<void> _setKey({TomSecretsSshKeyAlgorithm? algorithm}) async {
    final entry = _session.entryOf(widget.ref);
    if (entry != null && tomSecretsSshKeyOf(entry) != null) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const Key('tsm-ssh-replace'),
          title: const Text('Replace the key?'),
          content: const Text(
            'The entry has a key. The new one replaces it; the old one stays '
            'in the entry\'s history. Servers that trust the old key need the '
            'new public key.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('tsm-ssh-replace-ok'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (replace != true) return;
    }
    if (!mounted) return;
    final files = context.read<TomSecretsHost>().files;
    setState(() {
      _keyBusy = true;
      _sshError = null;
    });
    try {
      if (algorithm != null) {
        await _session.generateSshKey(widget.ref, algorithm: algorithm);
      } else {
        final picked = await files?.pick();
        if (picked == null) return;
        await _session.setSshKeyFile(widget.ref, picked.name, picked.bytes);
      }
      _type = TomSecretsEntryType.sshKey;
    } on FormatException catch (e) {
      if (mounted) setState(() => _sshError = e.message);
    } on TomSecretsAdminException catch (e) {
      if (mounted) setState(() => _sshError = tomSecretsDescribeAdminError(e));
    } finally {
      if (mounted) setState(() => _keyBusy = false);
    }
  }

  /// Whether the ssh-agent serves the key (and why not), and the switch
  /// that confirms each of its signatures (KeeAgent's "require
  /// confirmation", which KeePassXC reads too).
  List<Widget> _agentLines(
    BuildContext context,
    KdbxEntry entry,
    bool readOnly,
  ) {
    final theme = Theme.of(context);
    final agent = tomSecretsSshAgentStateOf(entry);
    final served = agent.state == TomSecretsSshAgentServing.served;
    final vaultConfirms = _session.sshConfirmOf(widget.ref.store);
    return [
      Text(
        served
            ? 'Served by the ssh-agent.'
            : 'Not served by the ssh-agent: '
                  '${tomSecretsSshAgentReason(agent.state)}.',
        key: const Key('tsm-ssh-agent-state'),
        style: served
            ? theme.textTheme.bodySmall
            : theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
      ),
      CheckboxListTile(
        key: const Key('tsm-ssh-confirm'),
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: agent.confirm || vaultConfirms,
        onChanged: readOnly || vaultConfirms || _keyBusy
            ? null
            : (v) async {
                setState(() => _keyBusy = true);
                try {
                  await _session.setSshKeyConfirm(widget.ref, v == true);
                } on TomSecretsAdminException catch (e) {
                  if (mounted) {
                    setState(() => _sshError = tomSecretsDescribeAdminError(e));
                  }
                } finally {
                  if (mounted) setState(() => _keyBusy = false);
                }
              },
        title: const Text('Confirm every signature the agent makes with it'),
        subtitle: vaultConfirms
            ? const Text('Its vault confirms every signature.')
            : null,
      ),
    ];
  }

  /// Whether the entry is a note or a typed key: no user name, no URLs.
  bool get _typedKey => switch (_type) {
    TomSecretsEntryType.note ||
    TomSecretsEntryType.sshKey ||
    TomSecretsEntryType.certificate ||
    TomSecretsEntryType.pgpKey => true,
    _ => false,
  };

  /// Takes over what writing a certificate or PGP key changed in the saved
  /// entry (its type, the passphrase in Password, Expires), so a later save
  /// of the form keeps it.
  void _takeTypedKey() {
    final entry = _session.entryOf(widget.ref);
    if (entry == null || !mounted) return;
    final dirty = _dirty;
    setState(() {
      _type = TomSecretsEntryType.of(
        entry.getString(TomSecretsEntryFields.type)?.getText(),
      );
      _password.text = entry.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '';
      _expires = entry.times.expires.get() == true;
      _expiry = entry.times.expiryTime.get();
      _dirty = dirty;
    });
  }

  Widget _sshSection(BuildContext context, KdbxEntry entry, bool readOnly) {
    final theme = Theme.of(context);
    final key = tomSecretsSshKeyOf(entry);
    final info = key?.info;
    final publicKey = info?.publicKey;
    final canPick = context.read<TomSecretsHost>().files != null;
    return _section('SSH key', Icons.terminal_rounded, [
      if (key == null)
        const Text(
          'No key yet: generate one, or choose a private key file.',
          key: Key('tsm-ssh-none'),
        )
      else ...[
        Text(
          [
            info!.keyType ?? 'unknown type',
            if (info.bits != null) '${info.bits} bits',
            'attachment ${key.name}',
            if (info.encrypted) 'encrypted: its passphrase below',
          ].join(' · '),
          key: const Key('tsm-ssh-summary'),
        ),
        if (info.fingerprint != null)
          SelectableText(
            info.fingerprint!,
            key: const Key('tsm-ssh-fingerprint'),
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
        if (publicKey != null)
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  publicKey,
                  key: const Key('tsm-ssh-public'),
                  maxLines: 3,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              IconButton(
                key: const Key('tsm-ssh-copy-public'),
                tooltip: 'Copy the public key',
                icon: const Icon(Icons.copy_rounded),
                onPressed: () async {
                  // The public key is no secret: the plain clipboard.
                  await Clipboard.setData(ClipboardData(text: publicKey));
                  if (!context.mounted) return;
                  tomShowNotice(
                    ScaffoldMessenger.maybeOf(context),
                    kind: 'copied',
                    message: 'The public key is copied.',
                  );
                },
              ),
            ],
          )
        else
          Text(
            'The key file is encrypted in a form that hides its public key; '
            '`ssh-keygen -y -f <file>` prints it with the passphrase.',
            style: theme.textTheme.bodySmall,
          ),
      ],
      if (key != null) ..._agentLines(context, entry, readOnly),
      if (!readOnly)
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            FilledButton.tonalIcon(
              key: const Key('tsm-ssh-generate'),
              icon: const Icon(Icons.auto_awesome_rounded),
              label: const Text('Generate an Ed25519 key'),
              onPressed: _keyBusy
                  ? null
                  : () => unawaited(
                      _setKey(algorithm: TomSecretsSshKeyAlgorithm.ed25519),
                    ),
            ),
            OutlinedButton(
              key: const Key('tsm-ssh-generate-rsa'),
              onPressed: _keyBusy
                  ? null
                  : () => unawaited(
                      _setKey(algorithm: TomSecretsSshKeyAlgorithm.rsa),
                    ),
              child: const Text('RSA 4096 (for a tool that needs RSA)'),
            ),
            if (canPick)
              OutlinedButton(
                key: const Key('tsm-ssh-file'),
                onPressed: _keyBusy ? null : () => unawaited(_setKey()),
                child: const Text('Choose a key file…'),
              ),
          ],
        ),
      if (_keyBusy) const LinearProgressIndicator(key: Key('tsm-ssh-busy')),
      if (_sshError != null)
        Text(
          _sshError!,
          key: const Key('tsm-ssh-error'),
          style: TextStyle(color: theme.colorScheme.error),
        ),
    ]);
  }

  /// Auto-type (part-password-manager): on or off, the entry's sequence
  /// (KeePass's syntax; empty: its group's, else the default), the window
  /// associations, and typing it into the window behind the app.
  Widget _autoTypeSection(bool readOnly) {
    final quick = context.watch<TomSecretsQuickAccess>();
    final support = quick.support;
    final outcome = quick.lastOutcome;
    void touched() {
      if (!_dirty) setState(() => _dirty = true);
    }

    return _section('Auto-type', Icons.keyboard_rounded, [
      CheckboxListTile(
        key: const Key('tsm-auto-type-on'),
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _autoTypeOn,
        onChanged: readOnly
            ? null
            : (on) => setState(() {
                _autoTypeOn = on == true;
                _dirty = true;
              }),
        title: const Text('Auto-type this entry'),
      ),
      TextField(
        key: const Key('tsm-auto-type-sequence'),
        controller: _autoTypeSequence,
        readOnly: readOnly,
        onChanged: (_) => touched(),
        decoration: const InputDecoration(
          labelText: 'Sequence',
          hintText: tomSecretsDefaultAutoTypeSequence,
          helperText:
              'Empty: the group\'s, else {USERNAME}{TAB}{PASSWORD}{ENTER}. '
              'Placeholders {USERNAME} {PASSWORD} {TITLE} {URL} {TOTP} '
              '{S:field}; keys {TAB} {ENTER} {DELAY 500}; + Shift, ^ Ctrl, '
              '% Alt.',
          helperMaxLines: 3,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'Windows (title patterns with * and ?, or //regex//)',
        style: Theme.of(context).textTheme.labelLarge,
      ),
      for (final (i, (window, sequence)) in _windows.indexed)
        Row(
          children: [
            Expanded(
              child: TextField(
                key: Key('tsm-auto-type-window-$i'),
                controller: window,
                readOnly: readOnly,
                onChanged: (_) => touched(),
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Window title',
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: Key('tsm-auto-type-window-sequence-$i'),
                controller: sequence,
                readOnly: readOnly,
                onChanged: (_) => touched(),
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Sequence (empty: the entry\'s)',
                ),
              ),
            ),
            IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: readOnly
                  ? null
                  : () => setState(() {
                      final (w, q) = _windows.removeAt(i);
                      w.dispose();
                      q.dispose();
                      _dirty = true;
                    }),
            ),
          ],
        ),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          TextButton.icon(
            key: const Key('tsm-auto-type-window-add'),
            icon: const Icon(Icons.add),
            label: const Text('Add a window'),
            onPressed: readOnly
                ? null
                : () => setState(() {
                    _windows.add((
                      TextEditingController(),
                      TextEditingController(),
                    ));
                    _dirty = true;
                  }),
          ),
          OutlinedButton.icon(
            key: const Key('tsm-auto-type-now'),
            icon: const Icon(Icons.keyboard),
            label: const Text('Type into the window behind'),
            onPressed: support.available && !_dirty
                ? () => unawaited(quick.typeFromEditor(widget.ref))
                : null,
          ),
        ],
      ),
      if (!support.available && support.reason != null)
        Text(
          support.reason!,
          key: const Key('tsm-auto-type-unavailable'),
          style: Theme.of(context).textTheme.bodySmall,
        )
      else if (_dirty)
        Text(
          'Save first: auto-type types the saved entry.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      if (outcome != null &&
          outcome.result != TomSecretsAutoTypeResult.typed &&
          outcome.message != null)
        Text(
          outcome.message!,
          key: const Key('tsm-auto-type-outcome'),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
    ]);
  }

  Widget _section(String title, IconData icon, List<Widget> children) =>
      TomSecretsSection(
        title: title,
        icon: icon,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            children[i],
          ],
        ],
      );

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    final host = context.read<TomSecretsHost>();
    final entry = session.entryOf(widget.ref);
    final view = session.view(widget.ref);
    if (entry == null || view == null) {
      return const Center(child: Text('This entry is no longer there.'));
    }
    final readOnly = session.readOnlyReason(widget.ref.store);
    final changed = session.changedElsewhere == widget.ref;
    final totp = TomSecretsTotp.fromEntry(entry);
    final pathReference = TomSecretReference.format(
      TomSecretReference(
        target: TomSecretPathTarget(widget.ref.store, [
          ...view.groups,
          view.title.isEmpty ? '(untitled)' : view.title,
        ]),
      ),
    );
    final key = view.key;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
      },
      child: ListView(
        key: const Key('tsm-entry-editor'),
        padding: const EdgeInsets.all(16),
        children: [
          if (readOnly != null)
            MaterialBanner(
              key: const Key('tsm-read-only'),
              content: Text('This vault is $readOnly.'),
              actions: const [SizedBox.shrink()],
            ),
          if (changed)
            MaterialBanner(
              key: const Key('tsm-changed-elsewhere'),
              content: const Text(
                'This entry changed elsewhere and the vault was read again. '
                'Unsaved edits here are saved over it field by field.',
              ),
              actions: [
                TextButton(
                  onPressed: () => setState(_load),
                  child: const Text('Discard my edits'),
                ),
              ],
            ),
          if (view.hasConflict)
            const MaterialBanner(
              content: Text(
                'This entry carries a conflict from a merge: both sides '
                'changed a field.',
              ),
              actions: [SizedBox.shrink()],
            ),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                TomSecretsTypeAvatar(_type, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: const Key('tsm-field-title'),
                    controller: _title,
                    readOnly: readOnly != null,
                    style: Theme.of(context).textTheme.titleMedium,
                    decoration: const InputDecoration(labelText: 'Title'),
                  ),
                ),
                if (context.read<TomSecretsHost>().sendsShares) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    key: const Key('tsm-entry-share'),
                    tooltip: 'Share…',
                    icon: const Icon(Icons.ios_share_rounded),
                    onPressed: () => unawaited(
                      tomSecretsShowShareDialog(context, [widget.ref]),
                    ),
                  ),
                ],
                const SizedBox(width: 12),
                DropdownButton<TomSecretsEntryType>(
                  key: const Key('tsm-entry-type'),
                  value: _type,
                  items: [
                    for (final t in const [
                      TomSecretsEntryType.login,
                      TomSecretsEntryType.apiToken,
                      TomSecretsEntryType.note,
                      TomSecretsEntryType.sshKey,
                      TomSecretsEntryType.certificate,
                      TomSecretsEntryType.pgpKey,
                    ])
                      DropdownMenuItem(
                        value: t,
                        child: Text(switch (t) {
                          TomSecretsEntryType.apiToken => 'API token',
                          TomSecretsEntryType.note => 'Secure note',
                          TomSecretsEntryType.sshKey => 'SSH key',
                          TomSecretsEntryType.certificate => 'Certificate',
                          TomSecretsEntryType.pgpKey => 'PGP key',
                          _ => 'Login',
                        }),
                      ),
                  ],
                  onChanged: readOnly != null
                      ? null
                      : (t) => setState(() {
                          _type = t ?? _type;
                          _dirty = true;
                        }),
                ),
              ],
            ),
          ),
          if (_type == TomSecretsEntryType.sshKey)
            _sshSection(context, entry, readOnly != null),
          if (_type == TomSecretsEntryType.certificate)
            TomSecretsCertificateSection(
              entryRef: widget.ref,
              readOnly: readOnly != null,
              onWritten: _takeTypedKey,
            ),
          if (_type == TomSecretsEntryType.pgpKey)
            TomSecretsPgpKeySection(
              entryRef: widget.ref,
              readOnly: readOnly != null,
              onWritten: _takeTypedKey,
            ),
          _section(
            switch (_type) {
              TomSecretsEntryType.apiToken => 'Token',
              TomSecretsEntryType.note => 'Secret',
              TomSecretsEntryType.sshKey ||
              TomSecretsEntryType.certificate ||
              TomSecretsEntryType.pgpKey => 'Passphrase',
              _ => 'Sign-in',
            },
            Icons.password_rounded,
            [
              if (!_typedKey)
                TextField(
                  key: const Key('tsm-field-user'),
                  controller: _user,
                  readOnly: readOnly != null,
                  decoration: const InputDecoration(
                    labelText: 'User name',
                    prefixIcon: Icon(Icons.person_outline_rounded, size: 18),
                  ),
                ),
              TomSecretsProtectedField(
                name: 'password',
                label: switch (_type) {
                  TomSecretsEntryType.apiToken => 'Token',
                  TomSecretsEntryType.sshKey ||
                  TomSecretsEntryType.certificate =>
                    'Passphrase (only when the key is encrypted)',
                  TomSecretsEntryType.pgpKey => 'Passphrase of the secret key',
                  _ => 'Password',
                },
                controller: _password,
                reveal: _reveal,
                clipboard: widget.clipboard,
                readOnly: readOnly != null,
                onCopied: () => tomShowNotice(
                  ScaffoldMessenger.maybeOf(context),
                  kind: 'copied',
                  message: 'Copied; the clipboard is cleared in 30 seconds.',
                ),
                extra: readOnly != null
                    ? null
                    : IconButton(
                        key: const Key('tsm-generate'),
                        tooltip: 'Generate a password',
                        icon: const Icon(Icons.casino_outlined),
                        onPressed: () async {
                          final generated = await tomSecretsShowGenerator(
                            context,
                            generator: widget.generator,
                          );
                          if (generated != null) _password.text = generated;
                        },
                      ),
              ),
            ],
          ),
          if (!_typedKey)
            _section('URLs', Icons.link_rounded, [
              for (var i = 0; i < _urls.length; i++)
                TextField(
                  key: Key('tsm-field-url-$i'),
                  controller: _urls[i],
                  readOnly: readOnly != null,
                  decoration: InputDecoration(
                    labelText: i == 0 ? 'URL' : 'URL ${i + 1}',
                  ),
                ),
              if (readOnly == null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('tsm-add-url'),
                    icon: const Icon(Icons.add),
                    label: const Text('Add a URL'),
                    onPressed: () => setState(() {
                      _urls.add(TextEditingController()..addListener(_touched));
                    }),
                  ),
                ),
            ]),
          _section('One-time code (TOTP)', Icons.timer_rounded, [
            if (totp != null)
              TomSecretsTotpView(totp: totp, clipboard: widget.clipboard),
            TomSecretsProtectedField(
              name: 'otp',
              label: 'otpauth:// URI or base32 secret',
              controller: _otp,
              reveal: _reveal,
              clipboard: widget.clipboard,
              readOnly: readOnly != null,
            ),
            if (host.scanner != null && readOnly == null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('tsm-otp-scan'),
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  label: const Text('Scan a QR code'),
                  onPressed: () => unawaited(_scanOtp(host.scanner!)),
                ),
              ),
            if (_otpError != null)
              Text(
                _otpError!,
                key: const Key('tsm-otp-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ]),
          _section('Notes', Icons.notes_rounded, [
            TextField(
              key: const Key('tsm-field-notes'),
              controller: _notes,
              readOnly: readOnly != null,
              minLines: 2,
              maxLines: 8,
              decoration: const InputDecoration(hintText: 'Notes'),
            ),
          ]),
          _section('Custom fields', Icons.tune_rounded, [
            for (final f in _custom)
              Row(
                children: [
                  SizedBox(
                    width: 160,
                    child: TextField(
                      controller: f.name,
                      readOnly: readOnly != null,
                      decoration: const InputDecoration(labelText: 'Name'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: f.protected
                        ? TomSecretsProtectedField(
                            name: 'custom-${_custom.indexOf(f)}',
                            label: 'Value (protected)',
                            controller: f.value,
                            reveal: _reveal,
                            clipboard: widget.clipboard,
                            readOnly: readOnly != null,
                          )
                        : TextField(
                            controller: f.value,
                            readOnly: readOnly != null,
                            decoration: const InputDecoration(
                              labelText: 'Value',
                            ),
                          ),
                  ),
                  IconButton(
                    tooltip: f.protected ? 'Unprotect' : 'Protect',
                    icon: Icon(f.protected ? Icons.lock : Icons.lock_open),
                    onPressed: readOnly != null
                        ? null
                        : () => setState(() {
                            f.protected = !f.protected;
                            _dirty = true;
                          }),
                  ),
                  IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: readOnly != null
                        ? null
                        : () => setState(() {
                            _custom.remove(f);
                            f.dispose();
                            _dirty = true;
                          }),
                  ),
                ],
              ),
            if (readOnly == null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('tsm-add-field'),
                  icon: const Icon(Icons.add),
                  label: const Text('Add a field'),
                  onPressed: () => setState(() {
                    final f = _CustomField('', '', false);
                    f.name.addListener(_touched);
                    f.value.addListener(_touched);
                    _custom.add(f);
                    _dirty = true;
                  }),
                ),
              ),
          ]),
          _section('Tags and expiry', Icons.sell_rounded, [
            if (tomSecretsTagsOf(entry).isNotEmpty)
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final tag in tomSecretsTagsOf(entry))
                    TomSecretsChip(tag, colour: tomSecretsTagColour(tag)),
                ],
              ),
            TextField(
              key: const Key('tsm-field-tags'),
              controller: _tags,
              readOnly: readOnly != null,
              decoration: const InputDecoration(
                labelText: 'Tags',
                helperText: 'separated by commas',
              ),
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('tsm-expires'),
                  value: _expires,
                  onChanged: readOnly != null
                      ? null
                      : (on) => setState(() {
                          _expires = on == true;
                          _expiry ??= DateTime.now().add(
                            const Duration(days: 90),
                          );
                          _dirty = true;
                        }),
                ),
                const Text('Expires'),
                const SizedBox(width: 12),
                if (_expires && _expiry != null)
                  TextButton(
                    key: const Key('tsm-expiry'),
                    onPressed: readOnly != null
                        ? null
                        : () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: _expiry!.toLocal(),
                              firstDate: DateTime(2000),
                              lastDate: DateTime(2200),
                            );
                            if (picked != null) {
                              setState(() {
                                _expiry = picked.toUtc();
                                _dirty = true;
                              });
                            }
                          },
                    child: Text(_dateOf(_expiry!)),
                  ),
              ],
            ),
            if (_type == TomSecretsEntryType.login)
              CheckboxListTile(
                key: const Key('tsm-breach-check'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: !_breachExcluded,
                onChanged: readOnly != null
                    ? null
                    : (on) => setState(() {
                        _breachExcluded = on != true;
                        _dirty = true;
                      }),
                title: const Text('Check the password against known breaches'),
              ),
          ]),
          _section('Attachments', Icons.attach_file_rounded, [
            for (final MapEntry(key: name, value: binary)
                in entry.binaryEntries)
              ListTile(
                dense: true,
                leading: Icon(switch (tomSecretsAttachmentKindOf(
                  name.key,
                  binary.value,
                )) {
                  TomSecretsAttachmentKind.image => Icons.image_outlined,
                  TomSecretsAttachmentKind.text => Icons.description_outlined,
                  TomSecretsAttachmentKind.other => Icons.attach_file,
                }),
                title: Text(name.key),
                subtitle: Text('${binary.value.length} bytes'),
                // Shown from memory: viewing writes no file.
                onTap: () => unawaited(
                  showTomSecretsAttachment(context, name.key, binary.value),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (tomSecretsAttachmentKindOf(name.key, binary.value) !=
                        TomSecretsAttachmentKind.other)
                      IconButton(
                        key: Key('tsm-attachment-view-${name.key}'),
                        tooltip: 'Show',
                        icon: const Icon(Icons.visibility_outlined),
                        onPressed: () => unawaited(
                          showTomSecretsAttachment(
                            context,
                            name.key,
                            binary.value,
                          ),
                        ),
                      ),
                    if (host.files != null)
                      IconButton(
                        key: Key('tsm-attachment-save-${name.key}'),
                        tooltip: host.attachmentsShare ? 'Share…' : 'Save as…',
                        icon: Icon(
                          host.attachmentsShare
                              ? Icons.ios_share_rounded
                              : Icons.download,
                        ),
                        onPressed: () =>
                            unawaited(host.files!.save(name.key, binary.value)),
                      ),
                    if (readOnly == null)
                      IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => unawaited(
                          _session.updateEntry(
                            widget.ref,
                            (e) => e.removeBinary(name),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (readOnly == null && host.files != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('tsm-attachment-add'),
                  icon: const Icon(Icons.attach_file),
                  label: const Text('Attach a file'),
                  onPressed: () => unawaited(_addAttachment()),
                ),
              ),
          ]),
          _section(
            'How clients name it',
            Icons.integration_instructions_rounded,
            [
              _ReferenceRow(
                label: 'Path',
                reference: pathReference,
                copyKey: const Key('tsm-copy-path-ref'),
              ),
              TextField(
                key: const Key('tsm-field-key'),
                controller: _key,
                readOnly: readOnly != null,
                decoration: InputDecoration(
                  labelText: 'Key (tsm.key)',
                  helperText: 'unique in this vault, e.g. telegram.bot_token',
                  errorText: _keyError,
                  suffixIcon: key == null
                      ? null
                      : IconButton(
                          key: const Key('tsm-copy-key-ref'),
                          tooltip: 'Copy the key reference',
                          icon: const Icon(Icons.copy),
                          onPressed: () =>
                              Clipboard.setData(ClipboardData(text: key)),
                        ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      view.overlays == 0
                          ? 'No overlays: every host, platform and '
                                'environment gets this value.'
                          : '${view.overlays} overlay'
                                '${view.overlays == 1 ? '' : 's'}: other '
                                'hosts, platforms or environments get their '
                                'own value.',
                    ),
                  ),
                  TextButton.icon(
                    key: const Key('tsm-open-overlays'),
                    icon: const Icon(Icons.layers_rounded, size: 18),
                    label: const Text('Overlays…'),
                    onPressed: () => unawaited(
                      tomSecretsShowOverlayEditor(
                        context,
                        widget.ref,
                        clipboard: widget.clipboard,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                FilledButton.icon(
                  key: const Key('tsm-save-entry'),
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save),
                  label: const Text('Save'),
                  onPressed: readOnly != null || !_dirty || _saving
                      ? null
                      : _save,
                ),
                const SizedBox(width: 8),
                if (_dirty)
                  TextButton(
                    onPressed: () => setState(_load),
                    child: const Text('Discard'),
                  ),
              ],
            ),
          ),
          _section('History', Icons.history_rounded, [
            if (entry.history.isEmpty) const Text('No earlier versions.'),
            for (final version in entry.history.reversed)
              ListTile(
                dense: true,
                title: Text(version.label ?? ''),
                subtitle: Text(
                  _dateTimeOf(version.times.lastModificationTime.get()),
                ),
                trailing: readOnly != null
                    ? null
                    : TextButton(
                        onPressed: () => unawaited(_restore(version)),
                        child: const Text('Restore'),
                      ),
              ),
          ]),
          if (_type == TomSecretsEntryType.login ||
              _type == TomSecretsEntryType.apiToken)
            _autoTypeSection(readOnly != null),
        ],
      ),
    );
  }

  static String _dateOf(DateTime d) {
    final l = d.toLocal();
    return '${l.year}-${_two(l.month)}-${_two(l.day)}';
  }

  static String _dateTimeOf(DateTime? d) {
    if (d == null) return '';
    final l = d.toLocal();
    return '${_dateOf(l)} ${_two(l.hour)}:${_two(l.minute)}';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}

class _ReferenceRow extends StatelessWidget {
  const _ReferenceRow({
    required this.label,
    required this.reference,
    required this.copyKey,
  });

  final String label;
  final String reference;
  final Key copyKey;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(width: 60, child: Text(label)),
      Expanded(
        child: SelectableText(
          reference,
          style: const TextStyle(fontFamily: 'monospace'),
        ),
      ),
      IconButton(
        key: copyKey,
        tooltip: 'Copy the $label reference',
        icon: const Icon(Icons.copy),
        onPressed: () => Clipboard.setData(ClipboardData(text: reference)),
      ),
    ],
  );
}

/// Why the ssh-agent does not serve a key, in words.
String tomSecretsSshAgentReason(TomSecretsSshAgentServing state) =>
    switch (state) {
      TomSecretsSshAgentServing.served => 'it is served',
      TomSecretsSshAgentServing.notSshKey => 'the entry is not an SSH key',
      TomSecretsSshAgentServing.noKey => 'the entry holds no key it reads',
      TomSecretsSshAgentServing.notAllowed =>
        'KeePassXC\'s agent settings do not allow it',
      TomSecretsSshAgentServing.notAdded =>
        'KeePassXC\'s agent settings do not add it when the vault opens',
      TomSecretsSshAgentServing.keyFileOutside =>
        'the key is a file outside the vault',
      TomSecretsSshAgentServing.unsupported =>
        'its key type is not supported (DSA, security keys)',
      TomSecretsSshAgentServing.passphraseMissing =>
        'the key is encrypted and the passphrase below is empty',
    };
