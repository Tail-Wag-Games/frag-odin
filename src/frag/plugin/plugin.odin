package plugin

import "thirdparty:cr"

import "linchpin:error"

import "frag:api"
import "frag:private"

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
}

Plugin_Context :: struct {
  plugins: []Plugin_Item,
  plugin_update_order: []int,
  plugin_path: string,
  injected: []Injected_Plugin_API,
  loaded: bool,
}

ctx : Plugin_Context

load_abs :: proc(name: string, entry: bool) -> (err: error.Error = nil) {
}

load :: proc(name: string) -> (err: error.Error = nil) {
  assert(!ctx.loaded, "additional plugins cannot be loaded after `init_plugins` has been invoked")
  load_abs(name, false)
}


init :: proc(plugin_path: string) -> (err: error.Error = nil) {
  ctx.plugin_path = filepath.clean(plugin_path)
  if !os.is_dir(ctx.plugin_path) {
    err = error.OS_Error.Directory
    return err 
  }

  return err
}

@(init, private)
init_plugin_api :: proc() {
  private.plugin_api = api.Plugin_API{
    load = load,
  }
}
