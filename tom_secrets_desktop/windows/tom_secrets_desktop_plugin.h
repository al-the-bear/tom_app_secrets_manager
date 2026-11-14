// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

#ifndef FLUTTER_PLUGIN_TOM_SECRETS_DESKTOP_PLUGIN_H_
#define FLUTTER_PLUGIN_TOM_SECRETS_DESKTOP_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

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
  // The registrar, for the view whose window the capture setting applies to.
  flutter::PluginRegistrarWindows *registrar_;
};

}  // namespace tom_secrets_desktop

#endif  // FLUTTER_PLUGIN_TOM_SECRETS_DESKTOP_PLUGIN_H_
