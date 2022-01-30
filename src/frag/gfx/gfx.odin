package gfx

import "thirdparty:sokol"

import "linchpin:memio"

import "frag:api"
import "frag:private"

import "core:fmt"


on_prepare_shader :: proc "c" (params: ^api.Asset_Load_Params, mem: ^memio.Mem_Block) {

}


on_load_shader :: proc "c" (data: ^api.Asset_Load_Data, params: ^api.Asset_Load_Params, mem: ^memio.Mem_Block) {

}


on_finalize_shader :: proc "c" (data: ^api.Asset_Load_Data, params: ^api.Asset_Load_Params, mem: ^memio.Mem_Block) {

}


on_reload_shader :: proc "c" (handle: api.Asset_Handle, prev_obj: api.Asset_Obj) {

}


on_release_shader :: proc "c" (obj: api.Asset_Obj) {

}


init_shaders :: proc() {
  private.asset_api.register_asset_type("shader", api.Asset_Callbacks{
    on_prepare = on_prepare_shader,
    on_load = on_load_shader,
    on_finalize = on_finalize_shader,
    on_reload = on_reload_shader,
    on_release = on_release_shader,
  })
}

init :: proc(desc: ^sokol.Gfx_Desc) {
  sokol.sg_setup(desc)

  init_shaders()
}