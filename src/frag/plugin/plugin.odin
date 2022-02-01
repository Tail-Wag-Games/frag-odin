package plugin

import "thirdparty:cr"

import "linchpin:error"
import "linchpin:platform"

import "frag:api"
import "frag:private"

import "core:dynlib"
import "core:log"
import "core:os"
import "core:path/filepath"

Injected_Plugin_API :: struct {
  name: string,
  version: u32,
  api: rawptr,
}

Plugin_Object :: struct {
  dll: rawptr,
  event_handler: api.Plugin_Event_Handler_Callback,
  main: api.Plugin_Main_Callback,
}

Plugin_Item :: struct {
  using po : struct #raw_union {
    p: cr.CR_Plugin,
    obj: Plugin_Object,
  },

  info: api.Plugin_Info,
  order: int,
  filepath: string,
  update_tm: f32,
  deps: []string,
}

Plugin_Context :: struct {
  plugins: [dynamic]Plugin_Item,
  plugin_update_order: [dynamic]int,
  plugin_path: string,
  injected: []Injected_Plugin_API,
  app_module: dynlib.Library,
  loaded: bool,
}

ctx : Plugin_Context

load_abs :: proc(filepath: string, entry: bool, deps: []string) -> (err: error.Error = nil) {
  log.info("loading plugin!")
  item : Plugin_Item
  item.p.user_data = &private.plugin_api

  dll : dynlib.Library
  if !entry {
    dll, dll_ok := dynlib.load_library(filepath); !dll_ok {
      return error.Plugin_Error { msg = platform.dlerr() }
    }

    ptr, sym_ok := dynlib.symbol_address(dll, "plugin_decl")
    if !sym_ok {
	  	return error.Plugin_Error { msg = platform.dlerr() }
	  }

    decl := cast(api.Plugin_Decl_Cb)ptr

    decl(&item.info)
  } else {
    dll = ctx.app_module
    item.info.name = private.app_api.name()
  }

  item.filepath = filepath
  item.deps = entry ? deps : item.info.deps
  item.order = -1
  dynlib.unload_library(dll)

  append(&ctx.plugins, item)
  append(&ctx.plugin_update_order, len(ctx.plugins) - 1)

  return err
}

load :: proc(name: string) -> (err: error.Error = nil) {
  assert(!ctx.loaded, "additional plugins cannot be loaded after `init_plugins` has been invoked")
  return load_abs(filepath.join(ctx.plugin_path, name, platform.DLL_EXT), false, []string {})
}


init :: proc(plugin_path: string, app_module: dynlib.Library) -> (err: error.Error = nil) {
  ctx.plugin_path = filepath.clean(plugin_path)
  if !os.is_dir(ctx.plugin_path) {
    err = error.IO_Error.Directory
    return err 
  }

  ctx.app_module = app_module

  return err
}

@(init, private)
init_plugin_api :: proc() {
  private.plugin_api = api.Plugin_API{
    load = load,
  }
}
