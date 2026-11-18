// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The fake GitHub's client behind a switch, for the tests: [down] answers
/// every request with a network failure.
library;

import 'package:http/http.dart' as http;

final class NetSwitch extends http.BaseClient {
  NetSwitch(this.inner);

  final http.Client inner;
  bool down = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => down
      ? Future.error(http.ClientException('no network', request.url))
      : inner.send(request);
}
