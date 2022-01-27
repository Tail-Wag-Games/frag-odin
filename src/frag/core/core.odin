package core

import "../../../vendor/sokol"

import ".."
import "../gfx"

init :: proc(conf: ^frag.Config) -> frag.Error {
  gfx.init(&sokol.Gfx_Desc{
    ctx = sokol.sapp_sgcontext(),
  })
  return .None
}