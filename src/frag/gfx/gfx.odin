package gfx

import sgfx "../../../vendor/sokol/sokol_gfx"

import "core:fmt"

init :: proc(gfx_desc: ^sgfx.Desc) {
  fmt.println("Inside gfx init!")
}