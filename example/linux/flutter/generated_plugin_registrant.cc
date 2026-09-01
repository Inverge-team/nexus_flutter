//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <nexus_flutter/nexus_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) nexus_flutter_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "NexusPlugin");
  nexus_plugin_register_with_registrar(nexus_flutter_registrar);
}
