package core

import sgfx "../../../vendor/sokol/sokol_gfx"
import sglue "../../../vendor/sokol/sokol_glue"

import ".."
import "../gfx"

init :: proc(conf: ^frag.Config) -> frag.Error {
  gfx.init(&sgfx.Desc{})
  return .None
}