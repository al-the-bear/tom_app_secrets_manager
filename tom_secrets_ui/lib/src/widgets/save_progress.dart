// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// How far a large save has been sent (a vault with attachments, over
/// 1 MiB): a bar and the megabytes, then "writing" while the service checks
/// and writes the file. Nothing for a save that is sent at once.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/session_state.dart';

/// [bytes] as megabytes with one decimal, as the progress line says them.
String tomSecretsMegabytes(int bytes) =>
    (bytes / (1024 * 1024)).toStringAsFixed(1);

/// The line a save's [progress] reads as.
String tomSecretsSaveProgressText(TomSecretsSaveProgress progress) =>
    progress.isSent
    ? 'Sent ${tomSecretsMegabytes(progress.total)} MB; the service is '
          'writing ${progress.store}…'
    : 'Saving ${progress.store}: ${tomSecretsMegabytes(progress.sent)} of '
          '${tomSecretsMegabytes(progress.total)} MB sent';

/// The progress of the session's save, while one over 1 MiB is on its way;
/// an empty box otherwise.
class TomSecretsSaveProgressLine extends StatelessWidget {
  /// The line.
  const TomSecretsSaveProgressLine({super.key});

  @override
  Widget build(BuildContext context) {
    final progress = context.select<TomSecretsSession, TomSecretsSaveProgress?>(
      (s) => s.saveProgress,
    );
    return progress == null
        ? const SizedBox.shrink()
        : TomSecretsSaveProgressBar(progress: progress);
  }
}

/// The bar and the line of one save's [progress].
class TomSecretsSaveProgressBar extends StatelessWidget {
  /// The bar of [progress].
  const TomSecretsSaveProgressBar({required this.progress, super.key});

  /// How far the save was sent.
  final TomSecretsSaveProgress progress;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('tsm-save-progress'),
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(
            // Sent: the service's part has no measure of its own.
            value: progress.isSent ? null : progress.sent / progress.total,
          ),
          const SizedBox(height: 4),
          Text(
            tomSecretsSaveProgressText(progress),
            key: const Key('tsm-save-progress-text'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
