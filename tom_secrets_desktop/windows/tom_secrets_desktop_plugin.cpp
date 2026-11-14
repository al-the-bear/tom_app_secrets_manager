// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The Windows half of tom_secrets_desktop's own platform code (DP-33): keeps
// the app's window out of screenshots and screen sharing with
// SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE), Windows 10 2004 and later.

#include "tom_secrets_desktop_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

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
    : registrar_(registrar) {}

TomSecretsDesktopPlugin::~TomSecretsDesktopPlugin() {}

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
