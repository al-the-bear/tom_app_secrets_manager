// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The desktop host of the Tom Secrets Manager's manager app (part-app):
/// the implementations of `tom_secrets_ui`'s ports on macOS, Windows and
/// Linux.
library;

export 'src/browser.dart';
export 'src/device_files.dart';
export 'src/platform_channels.dart';
export 'src/printer.dart';
export 'src/service_host.dart';
export 'src/shell.dart';
export 'src/single_instance.dart';
