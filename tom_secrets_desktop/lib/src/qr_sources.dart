// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The desktop's QR sources (a TOTP's setup code): the picture on the
/// clipboard and a capture of the screen through the system's own picker.
///
/// - macOS and Windows: this package's platform code
///   (`tom_secrets_desktop/qr`): the pasteboard or clipboard's picture, and
///   ScreenCaptureKit's picker (macOS 14+) or `Windows.Graphics.Capture`'s
///   (Windows 10 1903+), the capture handed over as pixels in memory.
/// - Linux: the clipboard through `wl-paste` (Wayland) or `xclip` (X11),
///   and the screen through the XDG desktop portal's interactive
///   screenshot. The portal writes the capture to a file it chooses; it is
///   read and deleted at once.
library;

import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/services.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

/// The channel of the clipboard's picture and the screen capture.
const MethodChannel tomSecretsQrChannel = MethodChannel(
  'tom_secrets_desktop/qr',
);

/// [TomSecretsQrSources] of this desktop.
final class TomSecretsDesktopQrSources implements TomSecretsQrSources {
  /// The sources of this platform; [channel], [run] and [portal] for tests.
  TomSecretsDesktopQrSources({
    MethodChannel channel = tomSecretsQrChannel,
    String? platform,
    String? osVersion,
    Future<ProcessResult> Function(String executable, List<String> args)? run,
    Future<Uint8List?> Function()? portal,
  }) : _channel = channel,
       _platform = platform ?? Platform.operatingSystem,
       _osVersion = osVersion ?? Platform.operatingSystemVersion,
       _run = run ?? _runBytes,
       _portal = portal ?? tomSecretsPortalScreenshot;

  final MethodChannel _channel;
  final String _platform;
  final String _osVersion;
  final Future<ProcessResult> Function(String, List<String>) _run;
  final Future<Uint8List?> Function() _portal;

  static Future<ProcessResult> _runBytes(
    String executable,
    List<String> args,
  ) => Process.run(executable, args, stdoutEncoding: null);

  @override
  bool get canCaptureScreen => switch (_platform) {
    'macos' => (_firstNumber(_osVersion) ?? 0) >= 14,
    // `Windows 10 Pro" 10.0 (Build 19045)`: the picker came with 1903 (18362).
    'windows' => (_build(_osVersion) ?? 0) >= 18362,
    'linux' => true,
    _ => false,
  };

  @override
  Future<TomSecretsQrImage?> clipboardImage() async {
    if (_platform == 'linux') return _linuxClipboard();
    return _image(await _invoke('clipboardImage'));
  }

  @override
  Future<TomSecretsQrImage?> captureScreen() async {
    if (_platform == 'linux') {
      final png = await _portal();
      return png == null ? null : TomSecretsQrImage.encoded(png);
    }
    return _image(await _invoke('captureScreen'));
  }

  Future<Object?> _invoke(String method) async {
    try {
      return await _channel.invokeMethod<Object?>(method);
    } on PlatformException catch (e) {
      throw TomSecretsQrException(e.message ?? e.code);
    } on MissingPluginException {
      throw const TomSecretsQrException('not available on this system');
    }
  }

  /// The answer of the platform code: null, `{width, height, pixels,
  /// order}` (pixels four bytes each, `rgba` or `bgra`) or `{encoded}` (an
  /// image file's bytes).
  static TomSecretsQrImage? _image(Object? answer) {
    if (answer is! Map) return null;
    // Why: a platform message's bytes are an unmodifiable view; a copy of
    // our own can be overwritten once read.
    if (answer['encoded'] case final Uint8List bytes) {
      return TomSecretsQrImage.encoded(Uint8List.fromList(bytes));
    }
    final width = answer['width'];
    final height = answer['height'];
    final pixels = answer['pixels'];
    if (width is! int || height is! int || pixels is! Uint8List) return null;
    return TomSecretsQrImage.rgba(
      width,
      height,
      Uint8List.fromList(pixels),
      order: answer['order'] == 'bgra'
          ? TomSecretsPixelOrder.bgra
          : TomSecretsPixelOrder.rgba,
    );
  }

  /// The clipboard's PNG through `wl-paste` (Wayland) or `xclip` (X11);
  /// null when it holds none or neither tool is installed.
  Future<TomSecretsQrImage?> _linuxClipboard() async {
    final wayland = Platform.environment['WAYLAND_DISPLAY'] != null;
    final tries = [
      if (wayland) ('wl-paste', ['--no-newline', '--type', 'image/png']),
      ('xclip', ['-selection', 'clipboard', '-target', 'image/png', '-out']),
    ];
    var found = false;
    for (final (tool, args) in tries) {
      final ProcessResult result;
      try {
        result = await _run(tool, args);
      } on ProcessException {
        continue;
      }
      found = true;
      final out = result.stdout;
      if (result.exitCode == 0 && out is List<int> && out.isNotEmpty) {
        return TomSecretsQrImage.encoded(Uint8List.fromList(out));
      }
    }
    if (!found) {
      throw TomSecretsQrException(
        wayland
            ? 'reading a picture from the clipboard needs wl-clipboard '
                  '(wl-paste) installed'
            : 'reading a picture from the clipboard needs xclip installed',
      );
    }
    return null;
  }

  static int? _firstNumber(String text) =>
      int.tryParse(RegExp(r'\d+').firstMatch(text)?.group(0) ?? '');

  static int? _build(String text) =>
      int.tryParse(RegExp(r'Build (\d+)').firstMatch(text)?.group(1) ?? '');
}

/// An interactive screenshot through the XDG desktop portal
/// (`org.freedesktop.portal.Screenshot`): the desktop's own picker; the
/// PNG's bytes, or null when the user cancelled. The file the portal wrote
/// is deleted once read.
Future<Uint8List?> tomSecretsPortalScreenshot() async {
  final client = DBusClient.session();
  try {
    // Why: the unique name the request path is built from exists only once
    // the connection is up.
    await client.ping();
    final token = 'tsm_qr_${DateTime.now().microsecondsSinceEpoch}';
    final sender = client.uniqueName.replaceFirst(':', '').replaceAll('.', '_');
    Future<DBusSignal> responseOn(DBusObjectPath path) => DBusSignalStream(
      client,
      interface: 'org.freedesktop.portal.Request',
      name: 'Response',
      path: path,
    ).first;
    final expected = DBusObjectPath(
      '/org/freedesktop/portal/desktop/request/$sender/$token',
    );
    // Why: subscribed before the call, so a fast answer is not missed.
    var answer = responseOn(expected);
    final portal = DBusRemoteObject(
      client,
      name: 'org.freedesktop.portal.Desktop',
      path: DBusObjectPath('/org/freedesktop/portal/desktop'),
    );
    final DBusMethodSuccessResponse reply;
    try {
      reply = await portal.callMethod(
        'org.freedesktop.portal.Screenshot',
        'Screenshot',
        [
          const DBusString(''),
          DBusDict.stringVariant({
            'handle_token': DBusString(token),
            'interactive': const DBusBoolean(true),
          }),
        ],
        replySignature: DBusSignature('o'),
      );
    } on DBusMethodResponseException catch (e) {
      throw TomSecretsQrException(
        'the screenshot portal is not available (${e.errorName})',
      );
    }
    // An older portal names its own request path.
    final handle = reply.values.single as DBusObjectPath;
    if (handle != expected) answer = responseOn(handle);
    final signal = await answer;
    final code = (signal.values[0] as DBusUint32).value;
    if (code != 0) return null;
    final results = (signal.values[1] as DBusDict).children;
    final uri = results[const DBusString('uri')];
    final text = uri is DBusVariant ? uri.value : uri;
    if (text is! DBusString) return null;
    final file = File.fromUri(Uri.parse(text.value));
    try {
      return await file.readAsBytes();
    } finally {
      if (await file.exists()) await file.delete();
    }
  } finally {
    await client.close();
  }
}
