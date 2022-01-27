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
  assetManagers: [dynamic]Asset_Manager,
  assetNameHashes: [dynamic]u32,
}

register_asset_type :: proc "c" (name: string, callbacks: frag.Asset_Callbacks) {
  context = runtime.default_context()
  
  name_hash := hash.fnv32a(transmute([]u8)name)
}

@(init)
init_api :: proc() {
  frag.asset_api = frag.Asset_API{
    register_asset_type = register_asset_type,
  }
}

