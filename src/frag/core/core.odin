package core

import "../../../vendor/sokol"

import ".."
import "../asset"
import "../gfx"

init :: proc(conf: ^frag.Config) -> frag.Error {
  asset.init()

  gfx.init(&sokol.Gfx_Desc{
    ctx = sokol.sapp_sgcontext(),
  })
  return .None
}