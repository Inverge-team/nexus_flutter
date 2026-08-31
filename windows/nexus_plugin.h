#ifndef FLUTTER_PLUGIN_NEXUS_PLUGIN_H_
#define FLUTTER_PLUGIN_NEXUS_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace nexus {

class NexusPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  NexusPlugin();

  virtual ~NexusPlugin();

  // Disallow copy and assign.
  NexusPlugin(const NexusPlugin&) = delete;
  NexusPlugin& operator=(const NexusPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace nexus

#endif  // FLUTTER_PLUGIN_NEXUS_PLUGIN_H_
