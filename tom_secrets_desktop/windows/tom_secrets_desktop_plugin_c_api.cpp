#include "include/tom_secrets_desktop/tom_secrets_desktop_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "tom_secrets_desktop_plugin.h"

void TomSecretsDesktopPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  tom_secrets_desktop::TomSecretsDesktopPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
