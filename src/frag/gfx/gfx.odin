package gfx

import "../../../vendor/sokol"

import "core:fmt"

init :: proc(desc: ^sokol.Gfx_Desc) {
  sokol.sg_setup(desc)
}