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
import '../state/session_state.dart';
import '../widgets/generator_dialog.dart';
import '../widgets/protected_field.dart';
import '../widgets/style.dart';
import '../widgets/totp_view.dart';
import 'gate_screens.dart' show tomSecretsDescribeAdminError;
import 'overlay_editor.dart' show tomSecretsShowOverlayEditor;

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
  DateTime? _expiry;
  bool _dirty = false;
  bool _saving = false;
  String? _keyError;
  String? _otpError;

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
                const SizedBox(width: 12),
                DropdownButton<TomSecretsEntryType>(
                  key: const Key('tsm-entry-type'),
                  value: _type,
                  items: [
                    for (final t in const [
                      TomSecretsEntryType.login,
                      TomSecretsEntryType.apiToken,
                      TomSecretsEntryType.note,
                    ])
                      DropdownMenuItem(
                        value: t,
                        child: Text(switch (t) {
                          TomSecretsEntryType.apiToken => 'API token',
                          TomSecretsEntryType.note => 'Secure note',
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
          _section(
            switch (_type) {
              TomSecretsEntryType.apiToken => 'Token',
              TomSecretsEntryType.note => 'Secret',
              _ => 'Sign-in',
            },
            Icons.password_rounded,
            [
              if (_type != TomSecretsEntryType.note)
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
                label: _type == TomSecretsEntryType.apiToken
                    ? 'Token'
                    : 'Password',
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
          if (_type != TomSecretsEntryType.note)
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
          ]),
          _section('Attachments', Icons.attach_file_rounded, [
            for (final MapEntry(key: name, value: binary)
                in entry.binaryEntries)
              ListTile(
                dense: true,
                leading: const Icon(Icons.attach_file),
                title: Text(name.key),
                subtitle: Text('${binary.value.length} bytes'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (host.files != null)
                      IconButton(
                        tooltip: 'Save as…',
                        icon: const Icon(Icons.download),
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
