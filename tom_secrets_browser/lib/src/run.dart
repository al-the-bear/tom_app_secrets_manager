// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The host's run: the caller checked, then each request read from the
/// browser answered in order, until the browser closes the port (standard
/// input ends).
library;

import 'dart:async';

import 'package:tom_secrets_client/tom_secrets_client.dart';

import 'caller.dart';
import 'framing.dart';
import 'host.dart';

/// Runs the host on [input] and [output] for the [arguments] the browser
/// started it with; [serviceFor] gives the service for the caller (default
/// the client library, named for the caller). Answers the exit code: 0 when
/// the browser closed the port, 1 for a caller that is not the product's
/// extension (one `denied` answer is written first), 2 for input that
/// breaks the framing.
Future<int> tomSecretsRunBrowserHost(
  List<String> arguments, {
  required Stream<List<int>> input,
  required StreamSink<List<int>> output,
  TomSecretsBrowserService Function(TomSecretsBrowserCaller caller)? serviceFor,
  TomSecretsBrowserHost Function(TomSecretsBrowserService service)? hostFor,
}) async {
  final caller = TomSecretsBrowserCaller.fromArguments(arguments);
  if (caller == null || !caller.isProducts) {
    output.add(
      tomSecretsBrowserFrame({
        'error': {
          'kind': 'denied',
          'message': 'this host serves the Tom Secrets Manager extension only',
          'reason': 'origin',
        },
      }),
    );
    return 1;
  }
  final service =
      serviceFor?.call(caller) ??
      TomSecretsClientBrowserService(
        TomSecretsClient(clientName: caller.clientName),
      );
  final host = hostFor?.call(service) ?? TomSecretsBrowserHost(service);
  try {
    await for (final request in tomSecretsBrowserMessages(input)) {
      output.add(tomSecretsBrowserFrame(await host.handle(request)));
    }
    return 0;
  } on TomSecretsBrowserFrameException {
    return 2;
  } finally {
    await service.close();
  }
}
