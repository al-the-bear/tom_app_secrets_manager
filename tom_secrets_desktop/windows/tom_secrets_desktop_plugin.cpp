// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The Windows half of tom_secrets_desktop's own platform code (DP-33): keeps
// the app's window out of screenshots and screen sharing with
// SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE), Windows 10 2004 and later;
// and sends the desktop session's screen lock and sleep to Dart
// (`tom_secrets_desktop/session`), which the app senses for the service;
// and registers the global hotkeys of quick access and auto-type
// (`tom_secrets_desktop/hotkeys`, RegisterHotKey and WM_HOTKEY).

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
  hotkeys_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "tom_secrets_desktop/hotkeys",
      &flutter::StandardMethodCodec::GetInstance());
  hotkeys_->SetMethodCallHandler([this](const auto &call, auto result) {
    HandleHotkeyCall(call, std::move(result));
  });
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
    for (const auto &entry : hotkey_names_) {
      UnregisterHotKey(session_window_, entry.first);
    }
  }
}

void TomSecretsDesktopPlugin::HandleHotkeyCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto *args =
      std::get_if<flutter::EncodableMap>(method_call.arguments());
  if (args == nullptr) {
    result->Error("bad_arguments", "a map");
    return;
  }
  auto text = [args](const char *key) -> std::string {
    auto it = args->find(flutter::EncodableValue(std::string(key)));
    if (it == args->end()) return std::string();
    const auto *value = std::get_if<std::string>(&it->second);
    return value == nullptr ? std::string() : *value;
  };
  const std::string id = text("id");
  // An earlier hotkey of that id goes first.
  for (auto it = hotkey_names_.begin(); it != hotkey_names_.end();) {
    if (it->second == id) {
      if (session_window_ != nullptr) UnregisterHotKey(session_window_, it->first);
      it = hotkey_names_.erase(it);
    } else {
      ++it;
    }
  }
  if (method_call.method_name() == "unregister") {
    result->Success();
    return;
  }
  if (method_call.method_name() != "register") {
    result->NotImplemented();
    return;
  }
  auto key_it = args->find(flutter::EncodableValue(std::string("keyCode")));
  const auto *key_code = key_it == args->end()
                             ? nullptr
                             : std::get_if<int32_t>(&key_it->second);
  if (key_code == nullptr || session_window_ == nullptr) {
    result->Success(flutter::EncodableValue(std::string("no window or key")));
    return;
  }
  UINT modifiers = MOD_NOREPEAT;
  auto mods_it = args->find(flutter::EncodableValue(std::string("modifiers")));
  if (mods_it != args->end()) {
    if (const auto *list = std::get_if<flutter::EncodableList>(&mods_it->second)) {
      for (const auto &m : *list) {
        const auto *name = std::get_if<std::string>(&m);
        if (name == nullptr) continue;
        if (*name == "control") modifiers |= MOD_CONTROL;
        if (*name == "alt") modifiers |= MOD_ALT;
        if (*name == "shift") modifiers |= MOD_SHIFT;
        if (*name == "meta") modifiers |= MOD_WIN;
      }
    }
  }
  const int number = next_hotkey_++;
  if (!RegisterHotKey(session_window_, number, modifiers,
                      static_cast<UINT>(*key_code))) {
    result->Success(flutter::EncodableValue(std::string(
        "Windows refused the hotkey: another program may use it")));
    return;
  }
  hotkey_names_[number] = id;
  result->Success();
}

std::optional<LRESULT> TomSecretsDesktopPlugin::HandleWindowProc(
    HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  const char *event = nullptr;
  if (message == WM_HOTKEY && hotkeys_ != nullptr) {
    auto it = hotkey_names_.find(static_cast<int>(wparam));
    if (it != hotkey_names_.end()) {
      hotkeys_->InvokeMethod(
          "pressed", std::make_unique<flutter::EncodableValue>(it->second));
      return 0;
    }
  }
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
