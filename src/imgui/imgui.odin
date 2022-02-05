package imgui

import "thirdparty:cimgui"

import "frag:api"

import "./types"

import _c "core:c"
import "core:c/libc"
import "core:math/linalg"
import "core:runtime"



// AnonymousUnion0 :: struct #raw_union {
//   val_i : _c.int,
//   val_f : _c.float,
//   val_p : rawptr,
// };

// AnonymousUnion1 :: struct #raw_union {
//   BackupInt : [2]_c.int,
//   BackupFloat : [2]_c.float,
// };



imgui_api := types.Imgui_Api {
  
}

@(link_section=".state")
core_api : ^api.Core_Api

@(link_section=".state")
plugin_api : ^api.Plugin_Api

@(link_section=".state")
app_api : ^api.App_Api

@(link_section=".state")
gfx_api : ^api.Gfx_Api

@(link_name="cr_main")
@export frag_plugin_main :: proc "c" (plugin: ^api.Plugin, e: api.Plugin_Event) -> i32 {
  context = runtime.default_context()

  switch e {
    case api.Plugin_Event.Load: {
      plugin_api = plugin.api
      core_api = cast(^api.Core_Api)plugin.api.get_api(api.Api_Type.Core)
      gfx_api = cast(^api.Gfx_Api)plugin.api.get_api(api.Api_Type.Gfx)
      app_api = cast(^api.App_Api)plugin.api.get_api(api.Api_Type.App)

      plugin_api.inject_api("imgui", &imgui_api)
    }

    case api.Plugin_Event.Step: {

    }

    case api.Plugin_Event.Unload: {

    }

    case api.Plugin_Event.Close: {

    }
  }
  
  return 0
}

@export
frag_plugin :: proc(info: ^api.Plugin_Info) {
  info.name = "imgui"
  info.desc = "dear-imgui plugin"
}

render :: proc "c" () {
  
}