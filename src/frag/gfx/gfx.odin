package gfx

import "../../../vendor/sokol"

import ".."
import "../asset"

import "core:fmt"

init_shaders :: proc() {
  frag.asset_api.register_asset_type("shader", frag.Asset_Callbacks{})
}

init :: proc(desc: ^sokol.Gfx_Desc) {
  sokol.sg_setup(desc)

  init_shaders()
}