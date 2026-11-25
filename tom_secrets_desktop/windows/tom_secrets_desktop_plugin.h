// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

#ifndef FLUTTER_PLUGIN_TOM_SECRETS_DESKTOP_PLUGIN_H_
#define FLUTTER_PLUGIN_TOM_SECRETS_DESKTOP_PLUGIN_H_

// This must be included before many other Windows headers.
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <map>
#include <memory>
#include <optional>
#include <string>

#include "tom_secrets_qr_windows.h"

namespace tom_secrets_desktop {

class TomSecretsDesktopPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  explicit TomSecretsDesktopPlugin(flutter::PluginRegistrarWindows *registrar);

  virtual ~TomSecretsDesktopPlugin();

  // Disallow copy and assign.
  TomSecretsDesktopPlugin(const TomSecretsDesktopPlugin&) = delete;
  TomSecretsDesktopPlugin& operator=(const TomSecretsDesktopPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  // The desktop session's screen lock and sleep (`tom_secrets_desktop/
  // session`): WM_WTSSESSION_CHANGE (WTS_SESSION_LOCK) and WM_POWERBROADCAST
  // (PBT_APMSUSPEND) of the app's top-level window, sent to Dart as `event`.
  std::optional<LRESULT> HandleWindowProc(HWND hwnd, UINT message,
                                          WPARAM wparam, LPARAM lparam);

  // The global hotkeys (`tom_secrets_desktop/hotkeys`): RegisterHotKey on
  // the app's top-level window, WM_HOTKEY sent to Dart as `pressed` with
  // the hotkey's id.
  void HandleHotkeyCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> hotkeys_;
  std::map<int, std::string> hotkey_names_;
  int next_hotkey_ = 1;

  // The registrar, for the view whose window the capture setting applies to.
  flutter::PluginRegistrarWindows *registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> session_;
  int window_proc_id_ = -1;
  HWND session_window_ = nullptr;
  // The clipboard's picture and the screen capture (`tom_secrets_desktop/
  // qr`).
  std::unique_ptr<TomSecretsQrWindows> qr_;
};

}  // namespace tom_secrets_desktop

#endif  // FLUTTER_PLUGIN_TOM_SECRETS_DESKTOP_PLUGIN_H_
