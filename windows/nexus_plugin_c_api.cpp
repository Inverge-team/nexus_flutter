#include "include/nexus/nexus_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "nexus_plugin.h"

void NexusPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  nexus::NexusPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
