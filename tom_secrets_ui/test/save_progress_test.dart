// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The progress of a large save as the Import screen and the entry editor
// show it: a bar with the megabytes sent, then "writing" once all is sent.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

void main() {
  const mib = 1024 * 1024;

  testWidgets('on its way: the share sent and the megabytes; sent: the '
      'service is writing', (tester) async {
    Future<void> show(TomSecretsSaveProgress progress) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TomSecretsSaveProgressBar(progress: progress)),
      ),
    );

    await show(const TomSecretsSaveProgress('primary', 10 * mib, 40 * mib));
    expect(find.text('Saving primary: 10.0 of 40.0 MB sent'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.25,
    );

    await show(const TomSecretsSaveProgress('primary', 40 * mib, 40 * mib));
    expect(
      find.text('Sent 40.0 MB; the service is writing primary…'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      isNull,
      reason: 'the service\'s part has no measure',
    );
  });
}
