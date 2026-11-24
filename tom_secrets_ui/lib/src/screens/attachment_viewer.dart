// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// An attachment shown in the app: an image in a picture viewer, a text file
/// as selectable text. Both are shown from memory only, so viewing leaves no
/// copy in the downloads folder or anywhere else on the disk.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// How an attachment can be shown.
enum TomSecretsAttachmentKind {
  /// A PNG, JPEG, GIF, WebP or BMP picture.
  image,

  /// UTF-8 text: `.txt`, `.csv`, `.md`, a PEM or OpenSSH key, an `.ovpn`
  /// profile, a configuration file.
  text,

  /// Anything else: offered for saving only.
  other,
}

/// The most text the viewer shows; a longer file is cut with a note.
const int tomSecretsAttachmentTextLimit = 2 * 1024 * 1024;

/// The kind of the attachment [name] holding [bytes]. Images are told by
/// their bytes (a renamed file is still found), text by being UTF-8 without
/// control characters other than tab, line feed, carriage return and form
/// feed; the name decides nothing.
TomSecretsAttachmentKind tomSecretsAttachmentKindOf(
  String name,
  Uint8List bytes,
) {
  if (_isImage(bytes)) return TomSecretsAttachmentKind.image;
  return _textOf(bytes) == null
      ? TomSecretsAttachmentKind.other
      : TomSecretsAttachmentKind.text;
}

bool _startsWith(Uint8List bytes, List<int> magic, [int at = 0]) {
  if (bytes.length < at + magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[at + i] != magic[i]) return false;
  }
  return true;
}

bool _isImage(Uint8List b) =>
    _startsWith(b, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) ||
    _startsWith(b, const [0xFF, 0xD8, 0xFF]) ||
    _startsWith(b, ascii.encode('GIF87a')) ||
    _startsWith(b, ascii.encode('GIF89a')) ||
    (_startsWith(b, ascii.encode('RIFF')) &&
        _startsWith(b, ascii.encode('WEBP'), 8)) ||
    (_startsWith(b, ascii.encode('BM')) && b.length > 26);

/// [bytes] as text, or null when they are not UTF-8 text.
String? _textOf(Uint8List bytes) {
  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    return null;
  }
  for (final c in text.codeUnits) {
    final control =
        c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D && c != 0x0C;
    if (control || c == 0x7F) return null;
  }
  return text.startsWith('﻿') ? text.substring(1) : text;
}

/// Shows the attachment [name] ([bytes]) in a dialog, when its kind can be
/// shown; answers whether it was.
Future<bool> showTomSecretsAttachment(
  BuildContext context,
  String name,
  Uint8List bytes,
) async {
  final kind = tomSecretsAttachmentKindOf(name, bytes);
  if (kind == TomSecretsAttachmentKind.other) return false;
  final image = kind == TomSecretsAttachmentKind.image
      ? MemoryImage(bytes)
      : null;
  await showDialog<void>(
    context: context,
    builder: (context) => _AttachmentDialog(
      name: name,
      image: image,
      text: image == null ? _textOf(bytes) : null,
    ),
  );
  // The decoded picture leaves the image cache with the dialog.
  if (image != null) await image.evict();
  return true;
}

class _AttachmentDialog extends StatelessWidget {
  const _AttachmentDialog({required this.name, this.image, this.text});

  final String name;
  final MemoryImage? image;
  final String? text;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final theme = Theme.of(context);
    final shown = text == null || text!.length <= tomSecretsAttachmentTextLimit
        ? text
        : text!.substring(0, tomSecretsAttachmentTextLimit);
    return Dialog(
      key: const Key('tsm-attachment-viewer'),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: size.width * 0.85,
          maxHeight: size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    key: const Key('tsm-attachment-close'),
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: image != null
                  ? InteractiveViewer(
                      maxScale: 8,
                      child: Center(
                        child: Image(
                          key: const Key('tsm-attachment-image'),
                          image: image!,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('This picture cannot be shown.'),
                          ),
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(
                        shown!,
                        key: const Key('tsm-attachment-text'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontFamily: 'monospace',
                          fontFamilyFallback: const [
                            'Menlo',
                            'Consolas',
                            'DejaVu Sans Mono',
                          ],
                        ),
                      ),
                    ),
            ),
            if (shown != null && shown.length < text!.length)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Only the first 2 MiB are shown; save the file to see it '
                  'all.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
