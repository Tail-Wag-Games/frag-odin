package three_d_impl

import "frag:api"

import "../debug"
import three_d "../api"

import "core:runtime"

Three_D_Context :: struct {
  
}

@(link_section=".state")
core_api : ^api.Core_Api

@(link_section=".state")
plugin_api : ^api.Plugin_Api

@(link_section=".state")
app_api : ^api.App_Api

@(link_section=".state")
gfx_api : ^api.Gfx_Api

@(link_section=".state")
camera_api : ^api.Camera_Api

@(link_section=".state")
ctx : Three_D_Context

three_d_api := three_d.Three_D_Api {
  debug = {
    draw_grid_on_xzplane_using_cam = debug.draw_grid_on_xzplane_using_cam,
  },
}


@export frag_plugin_event :: proc "c" (plugin: ^api.Plugin, e: ^api.App_Event) {
  
}

@export frag_plugin_main :: proc "c" (plugin: ^api.Plugin, e: api.Plugin_Event) -> i32 {
  context = runtime.default_context()
  context.allocator = core_api != nil ? core_api.alloc() : context.allocator
  context.logger = app_api != nil ? app_api.logger()^ : context.logger

  switch e {
    case api.Plugin_Event.Init: {
      plugin_api = plugin.api
      core_api = cast(^api.Core_Api)plugin.api.get_api(api.Api_Type.Core)
      gfx_api = cast(^api.Gfx_Api)plugin.api.get_api(api.Api_Type.Gfx)
      app_api = cast(^api.App_Api)plugin.api.get_api(api.Api_Type.App)
      camera_api = cast(^api.Camera_Api)plugin.api.get_api(api.Api_Type.Camera)

      debug.init(gfx_api, camera_api, context.allocator)

      plugin_api.inject_api("3d", &three_d_api)
    }

    case api.Plugin_Event.Load: {
      
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
  info.name = "3d"
  info.desc = "3d-related functionality"
}