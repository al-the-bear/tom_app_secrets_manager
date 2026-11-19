// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// `tsm-browser-host`: the native-messaging host the browsers start for the
/// Tom Secrets Manager extension (part-browser). It speaks native
/// messaging on standard input and output and the client protocol to the
/// secrets service; it writes nothing else to standard output.
library;

import 'dart:io';

import 'package:tom_secrets_browser/tom_secrets_browser.dart';

Future<void> main(List<String> arguments) async {
  final code = await tomSecretsRunBrowserHost(
    arguments,
    input: stdin,
    output: stdout,
  );
  await stdout.flush();
  exit(code);
}
