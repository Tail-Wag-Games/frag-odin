package asset

import "frag:api"
import "frag:private"

import "core:fmt"
import "core:hash"
import "core:runtime"

Asset_Manager :: struct {
  name: string,
  name_hash: u32,
  callbacks: api.Asset_Callbacks,
}

Asset_Context :: struct {
  asset_managers: [dynamic]Asset_Manager,
  asset_name_hashes: [dynamic]u32,
}


ctx := Asset_Context{}


register_asset_type :: proc (name: string, callbacks: api.Asset_Callbacks) {
  context = runtime.default_context()

  name_hash := hash.fnv32a(transmute([]u8)name)

  for asset_name_hash in ctx.asset_name_hashes {
    if name_hash == asset_name_hash {
      assert(false, fmt.tprintf("asset with name: %s - already registered", name))
      return
    }
  }

  append(&ctx.asset_managers, Asset_Manager{
    name = name,
    name_hash = name_hash,
    callbacks = callbacks,
  })
  append(&ctx.asset_name_hashes, name_hash)
}


init :: proc() {

}

@(init, private)
init_asset_api :: proc() {
  private.asset_api = api.Asset_API {
    register_asset_type = register_asset_type,
  }
}

