package plugin

import "thirdparty:cr"

import "linchpin:error"
import "linchpin:platform"

import "frag:api"
import "frag:config"
import "frag:private"

import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:runtime"
import "core:sort"
import "core:strings"

Injected_Plugin_Api :: struct {
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
  initialized: bool,
}

Plugin_Context :: struct {
  plugins: [dynamic]Plugin_Item,
  plugin_update_order: [dynamic]int,
  plugin_path: string,
  injected: [dynamic]Injected_Plugin_Api,
  app_module: dynlib.Library,
  loaded: bool,
}

ctx : Plugin_Context

native_apis := [6]rawptr {
  &private.core_api, 
  &private.plugin_api, 
  &private.app_api, 
  &private.gfx_api, 
  &private.vfs_api, 
  &private.asset_api,
}

inject_api :: proc "c" (name: string, api: rawptr) {
  context = runtime.default_context()

  api_idx := -1
  for injected, i in ctx.injected {
    if injected.name == string(name) {
      api_idx = i
      break
    }
  }

  if api_idx == -1 {
    item := Injected_Plugin_Api {
      api = api,
      name = string(name),
    }
    append(&ctx.injected, item)
  } else {
    ctx.injected[api_idx].api = api
  }
}

get_api_by_name :: proc "c" (name: string) -> rawptr {
  context = runtime.default_context()

  for injected in ctx.injected {
    if injected.name == name {
      return injected.api
    }
  }

  log.warn("api with name: %s - not found")
  return nil
}

get_api :: proc "c" (kind: api.Api_Type) -> rawptr {
  context = runtime.default_context()

  return native_apis[kind]
}

update :: proc(dt: f32) {
  for i in 0 ..< len(ctx.plugin_update_order) {
    item := &ctx.plugins[ctx.plugin_update_order[i]]
    check_reload := false
    item.update_tm += dt

    if item.update_tm >= config.PLUGIN_UPDATE_INTERVAL {
      check_reload = true
      item.update_tm = 0
    }

    r := cr.plugin_update(&item.p, check_reload)
    if r == -2 {
      log.errorf("plugin '%s' failed to reload", ctx.plugins[i].info.name)
    } else if (r < -1) {
      if item.p.failure == cr.CR_Failure.User {
        log.errorf("plugin '%s' failed (main ret = -1)", ctx.plugins[i].info.name)
      }
    } else {
      log.errorf("plugin '%s' crashed", ctx.plugins[i].info.name)
    }
  }
}

sort_dependencies :: proc() -> error.Error {
  context = runtime.default_context()
  
  num_plugins := len(ctx.plugins)
  if num_plugins == 0 {
    return nil
  }

  level := 0
  count := 0
  for count < num_plugins {
    init_count := count
    for i in 0 ..< num_plugins {
      item := &ctx.plugins[i]
      if item.order == -1 {
        if len(item.deps) > 0 {
          num_deps_met := 0
          for d in 0 ..< len(item.deps) {
            for j in 0 ..< num_plugins {
              parent_item := &ctx.plugins[j]
              if i != j && parent_item.order != -1 &&
                parent_item.order <= (level -1) &&
                parent_item.info.name == item.deps[d] {
                  num_deps_met += 1
                  break
                }
            }
          }
          if num_deps_met == len(item.deps) {
            item.order = level
            count += 1
          }
        } else {
          item.order = 0
          count += 1
        }
      }
    } // foreach plugin
    
    if init_count == count {
      break
    }

    level += 1
  }

  if count != num_plugins {
    log.error("the following plugins' dependences were not met:")
    
    sb := strings.make_builder()
    defer strings.destroy_builder(&sb)
    for i in 0 ..< num_plugins {
      item := &ctx.plugins[i]
      if item.order == -1 {
        fmt.sbprint(&sb, '[')
        for d in 0 ..< len(item.deps) {
          if d != len(item.deps) - 1 {
            fmt.sbprint(&sb, item.deps[d])
          } else {
            fmt.sbprint(&sb, ']')
          }
        }
        log.errorf("\t%s - (depends-> %s", len(item.info.name) > 0 ? item.info.name : "[entry]", strings.to_string(sb))
      }
      strings.reset_builder(&sb)
    }
  }

  sort.quick_sort(ctx.plugin_update_order[:])

  return nil
}

init_plugins :: proc() -> error.Error {
  context = runtime.default_context()

  sort_dependencies() or_return

  for i in 0 ..< len(ctx.plugin_update_order) {
    index := ctx.plugin_update_order[i]
    item := &ctx.plugins[index]

    res := cr.plugin_open(&item.p, strings.clone_to_cstring(item.filepath))
    if !res {
      log.errorf("failed initializing plugin: %s", item.filepath)
      return error.Plugin_Error.Init
    }

    if len(item.info.name) > 0 {
      log.infof("(init) plugin: %s (%s)", item.info.name, item.filepath)
    }
  }

  ctx.loaded = true
  return nil
}

load_abs :: proc(filepath: string, entry: bool, deps: []string) -> error.Error {
  context = runtime.default_context()
  context.logger = log.create_console_logger()

  item : Plugin_Item
  item.p.user_data = &private.plugin_api

  dll : dynlib.Library
  if !entry {
    dll, dll_ok := dynlib.load_library(filepath)
    if !dll_ok {
      log.errorf("failed loading plugin: %s - %v", filepath, platform.dlerr())
      return error.Plugin_Error.Load
    }

    ptr, sym_ok := dynlib.symbol_address(dll, "frag_plugin")
    if !sym_ok {
      log.errorf("failed loading `frag_plugin` symbol from plugin: %s - %v", filepath, platform.dlerr())
	  	return error.Plugin_Error.Symbol_Not_Found
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
  item.update_tm = max(f32)
  dynlib.unload_library(dll)

  append(&ctx.plugins, item)
  append(&ctx.plugin_update_order, len(ctx.plugins) - 1)

  return nil
}

load :: proc "c" (name: string) -> (err: error.Error = nil) {
  context = runtime.default_context()

  assert(!ctx.loaded, "additional plugins cannot be loaded after `init_plugins` has been invoked")
  return load_abs(strings.concatenate({filepath.join(ctx.plugin_path, name), platform.DLL_EXT}), false, []string {})
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
  private.plugin_api = api.Plugin_Api {
    load = load,
    inject_api = inject_api,
    get_api = get_api,
    get_api_by_name = get_api_by_name,
  }
}
