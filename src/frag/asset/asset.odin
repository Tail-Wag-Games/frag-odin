package asset

import "frag:api"
import "frag:private"

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:path/slashpath"
import "core:runtime"
import "core:strings"

Asset_Manager :: struct {
  name: string,
  name_hash: u32,
  callbacks: api.Asset_Callbacks,
}

Asset_Context :: struct {
  alloc: mem.Allocator,
  asset_managers: [dynamic]Asset_Manager,
  asset_name_hashes: [dynamic]u32,
}


ctx := Asset_Context{}

on_asset_modified :: proc "c" (path: cstring) {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  unix_path := slashpath.clean(strings.clone_from_cstring(path, context.temp_allocator))
}

register_asset_type :: proc "c" (name: cstring, callbacks: api.Asset_Callbacks) {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  name_str := strings.clone_from_cstring(name, context.temp_allocator)
  name_hash := hash.fnv32a(transmute([]u8)name_str)

  for asset_name_hash in ctx.asset_name_hashes {
    if name_hash == asset_name_hash {
      assert(false, fmt.tprintf("asset with name: %s - already registered", name))
      return
    }
  }

  append(&ctx.asset_managers, Asset_Manager{
    name = name_str,
    name_hash = name_hash,
    callbacks = callbacks,
  })
  append(&ctx.asset_name_hashes, name_hash)
}


init :: proc(allocator := context.allocator) {
  ctx.alloc = allocator

  private.vfs_api.register_modify_cb(on_asset_modified)
}

shutdown :: proc() {
  delete(ctx.asset_managers)
  delete(ctx.asset_name_hashes)
}

@(init, private)
init_asset_api :: proc() {
  private.asset_api = api.Asset_Api {
    register_asset_type = register_asset_type,
  }
}

