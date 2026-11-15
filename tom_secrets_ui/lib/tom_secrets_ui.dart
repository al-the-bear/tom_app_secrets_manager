// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The screens and state of the Tom Secrets Manager's manager app (part-app),
/// shared by the desktop and (phase B) the mobile app. A host implements the
/// ports ([TomSecretsHost]) and runs [TomSecretsApp].
library;

export 'src/app.dart';
export 'src/host_bridge.dart';
export 'src/ports/desktop_ports.dart';
export 'src/ports/service_host.dart';
export 'src/screens/approval_prompt.dart';
export 'src/screens/clients_view.dart';
export 'src/screens/conflicts_view.dart';
export 'src/screens/entry_editor.dart';
export 'src/screens/environments_view.dart';
export 'src/screens/first_run_wizard.dart';
export 'src/screens/renew_token_dialog.dart';
export 'src/screens/rotate_dialog.dart';
export 'src/screens/gate_screens.dart';
export 'src/screens/import_view.dart';
export 'src/screens/keys_view.dart';
export 'src/screens/main_shell.dart';
export 'src/screens/overlay_editor.dart';
export 'src/screens/rewritten_question.dart';
export 'src/screens/settings_view.dart';
export 'src/screens/status_view.dart';
export 'src/screens/vault_browser.dart';
export 'src/state/clients.dart';
export 'src/state/conflicts.dart';
export 'src/state/emergency_sheet.dart';
export 'src/state/first_run_model.dart';
export 'src/state/import_model.dart';
export 'src/state/overlays.dart';
export 'src/state/reminders.dart';
export 'src/state/rotation.dart';
export 'src/state/service_connection.dart';
export 'src/state/session_state.dart';
export 'src/state/token_renewal.dart';
export 'src/widgets/emergency_sheet_offer.dart';
export 'src/widgets/generator_dialog.dart';
export 'src/widgets/protected_field.dart';
export 'src/widgets/style.dart';
export 'src/widgets/totp_view.dart';
