// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// One instance of the app per user (part-app, "Tray and menu bar"): the
/// first one listens on a localhost port named in `app.port` of the data
/// directory; a second launch tells it to show its window and ends.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The first instance's listener.
final class TomSecretsSingleInstance {
  TomSecretsSingleInstance._(this._server, this._file);

  final ServerSocket _server;
  final File _file;

  /// The word a second launch sends.
  static const String activate = 'activate';

  /// Becomes the one instance, calling [onActivate] whenever a later launch
  /// asks; or, when another instance answers on the port in [portFile],
  /// tells it to come to the front and answers null.
  static Future<TomSecretsSingleInstance?> claim(
    File portFile, {
    required void Function() onActivate,
  }) async {
    if (await _tell(portFile)) return null;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    await portFile.parent.create(recursive: true);
    await portFile.writeAsString('${server.port}\n');
    server.listen((socket) {
      unawaited(
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .first
            .then((text) {
              if (text.trim() == activate) onActivate();
            })
            .catchError((Object _) {})
            .whenComplete(socket.destroy),
      );
    });
    return TomSecretsSingleInstance._(server, portFile);
  }

  static Future<bool> _tell(File portFile) async {
    final int? port;
    try {
      port = int.tryParse((await portFile.readAsString()).trim());
    } on FileSystemException {
      return false;
    }
    if (port == null) return false;
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 2),
      );
      socket.write('$activate\n');
      await socket.flush();
      await socket.close();
      return true;
    } on SocketException {
      return false;
    }
  }

  /// Stops listening and removes the port file.
  Future<void> close() async {
    await _server.close();
    try {
      await _file.delete();
    } on FileSystemException {
      // Gone already.
    }
  }
}
