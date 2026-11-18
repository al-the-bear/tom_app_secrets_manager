// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The Windows half of tom_secrets_desktop's own platform code (DP-33): keeps
// the app's window out of screenshots and screen sharing with
// SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE), Windows 10 2004 and later;
// and sends the desktop session's screen lock and sleep to Dart
// (`tom_secrets_desktop/session`), which the app senses for the service.

#include "tom_secrets_desktop_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>
#include <wtsapi32.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

namespace tom_secrets_desktop {

// static
void TomSecretsDesktopPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "tom_secrets_desktop/capture",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<TomSecretsDesktopPlugin>(registrar);

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

TomSecretsDesktopPlugin::TomSecretsDesktopPlugin(
    flutter::PluginRegistrarWindows *registrar)
    : registrar_(registrar) {
  session_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "tom_secrets_desktop/session",
      &flutter::StandardMethodCodec::GetInstance());
  window_proc_id_ = registrar->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        return HandleWindowProc(hwnd, message, wparam, lparam);
      });
  // The session change messages come only to a window registered for them.
  HWND view = registrar->GetView() == nullptr
                  ? nullptr
                  : registrar->GetView()->GetNativeWindow();
  session_window_ = view == nullptr ? nullptr : GetAncestor(view, GA_ROOT);
  if (session_window_ != nullptr) {
    WTSRegisterSessionNotification(session_window_, NOTIFY_FOR_THIS_SESSION);
  }
}

TomSecretsDesktopPlugin::~TomSecretsDesktopPlugin() {
  registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
  if (session_window_ != nullptr) {
    WTSUnRegisterSessionNotification(session_window_);
  }
}

std::optional<LRESULT> TomSecretsDesktopPlugin::HandleWindowProc(
    HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  const char *event = nullptr;
  if (message == WM_WTSSESSION_CHANGE && wparam == WTS_SESSION_LOCK) {
    event = "screenLocked";
  } else if (message == WM_POWERBROADCAST && wparam == PBT_APMSUSPEND) {
    event = "sleep";
  }
  if (event != nullptr && session_ != nullptr) {
    session_->InvokeMethod(
        "event", std::make_unique<flutter::EncodableValue>(std::string(event)));
  }
  // Never consumed: the window's own handling goes on.
  return std::nullopt;
}

void TomSecretsDesktopPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name() != "setCaptureExcluded") {
    result->NotImplemented();
    return;
  }
  const auto *excluded = std::get_if<bool>(method_call.arguments());
  if (excluded == nullptr) {
    result->Error("bad_arguments", "a bool");
    return;
  }
  // The top-level window the Flutter view is a child of.
  HWND view = registrar_->GetView() == nullptr
                  ? nullptr
                  : registrar_->GetView()->GetNativeWindow();
  HWND window = view == nullptr ? nullptr : GetAncestor(view, GA_ROOT);
  if (window == nullptr) {
    result->Success(flutter::EncodableValue(false));
    return;
  }
  const BOOL done = SetWindowDisplayAffinity(
      window, *excluded ? WDA_EXCLUDEFROMCAPTURE : WDA_NONE);
  result->Success(flutter::EncodableValue(done != FALSE));
}

}  // namespace tom_secrets_desktop
