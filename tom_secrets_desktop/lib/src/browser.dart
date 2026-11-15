// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Opening a web page in the system browser (`url_launcher`): GitHub's
/// token pages when a token is renewed (`TomSecretsHost.openUrl`).
library;

import 'package:url_launcher/url_launcher.dart';

/// Opens [url] in the system browser; answers whether it was opened. Only
/// `https` pages are opened.
Future<bool> tomSecretsDesktopOpenUrl(Uri url) async {
  if (url.scheme != 'https') return false;
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } on Object {
    return false;
  }
}
