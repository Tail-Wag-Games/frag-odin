package asset

import ".."

import "core:fmt"
import "core:hash"
import "core:runtime"

Asset_Manager :: struct {
  name: string,
  callbacks: frag.Asset_Callbacks,
}

Asset_Context :: struct {
  asset_managers: [dynamic]Asset_Manager,
  asset_name_hashes: [dynamic]u32,
}

ctx := Asset_Context{}

register_asset_type :: proc "c" (name: string, callbacks: frag.Asset_Callbacks) {
  context = runtime.default_context()

  name_hash := hash.fnv32a(transmute([]u8)name)

  // for i := 0; i < len(ctx.assetManagers); i += 1 {
	//   if name_hash == ctx.assetManagers[i]
  // }

  for asset_name_hash in ctx.asset_name_hashes {
    if name_hash == asset_name_hash {
      assert(false, fmt.tprintf("asset with name: %s - already registered", name))
      return
    }
  }

  append(&ctx.asset_name_hashes, name_hash)
}

@(init)
init_api :: proc() {
  frag.asset_api = frag.Asset_API{
    register_asset_type = register_asset_type,
  }
}

