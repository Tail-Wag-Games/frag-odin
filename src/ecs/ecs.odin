package ecs

import "frag:api"

import "./types"

import "core:runtime"

@(link_section=".state")
core_api : ^api.Core_Api

@(link_section=".state")
plugin_api : ^api.Plugin_Api

@(link_section=".state")
app_api : ^api.App_Api

@(link_section=".state")
gfx_api : ^api.Gfx_Api

ecs_api := types.Ecs_Api {
  
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
    }

    case api.Plugin_Event.Load: {
      plugin_api.inject_api("ecs", &ecs_api)
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
  info.name = "ecs"
  info.desc = "entity-component-system plugin"
}

@(init, private)
init_ecs_plugin :: proc() {

}