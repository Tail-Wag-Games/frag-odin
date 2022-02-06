package imgui

import "thirdparty:cimgui"
import "thirdparty:sokol"

import "linchpin:error"
import "linchpin:pool"

import "frag:api"

import "./types"
import "./shaders"

import _c "core:c"
import "core:c/libc"
import "core:log"
import "core:math/linalg"
import "core:runtime"

MAX_BUFFERED_FRAME_TIMES :: 120

Imgui_Error :: enum {
  Init,
}

Imgui_Context :: struct {
  imgui_ctx: ^cimgui.Context,
  small_mem_pool: ^pool.Pool,
  max_verts: int,
  max_indices: int,
  verts: [^]cimgui.Draw_Vert,
  indices: [^]u16,
  shader: sokol.sg_shader,
  pip: sokol.sg_pipeline,
  bind: sokol.sg_bindings,
  fmt_tex: sokol.sg_image,
  stage: api.Gfx_Stage_Handle,
  mouse_btn_down: [api.MAX_APP_MOUSE_BUTTONS]bool,
  mouse_btn_up: [api.MAX_APP_MOUSE_BUTTONS]bool,
  mouse_weel_h: f32,
  mouse_wheel: f32,
  keys_down: [api.MAX_APP_KEY_CODES]bool,
  char_input: [dynamic]cimgui.Wchar,
  last_cursor: cimgui.Mouse_Cursor,
  sg_imgui: sokol.sg_imgui_t,
  fts: [MAX_BUFFERED_FRAME_TIMES]f32,
  ft_iter: i32,
  ft_iter_nomod: i32,
  dock_space_id: cimgui.ImID,
  docking: bool,
}


imgui_api := types.Imgui_Api {
  CreateContext = cimgui.igCreateContext,
  Begin = cimgui.igBegin,
  End = cimgui.igEnd,
  LabelText = cimgui.igLabelText,
  SetNextWindowContentSize = cimgui.igSetNextWindowContentSize,
}

@(link_section=".state")
core_api : ^api.Core_Api

@(link_section=".state")
plugin_api : ^api.Plugin_Api

@(link_section=".state")
app_api : ^api.App_Api

@(link_section=".state")
gfx_api : ^api.Gfx_Api

@(link_section=".state")
ctx : Imgui_Context

init :: proc() -> Imgui_Error {
  context.allocator = core_api.alloc()
  context.logger = app_api.logger()^

  ctx.docking = app_api.config().imgui_docking
  ctx.imgui_ctx = imgui_api.CreateContext(nil)
  if ctx.imgui_ctx == nil {
    log.error("failed initializing dear imgui")
    return .Init
  }

  shader := gfx_api.make_shader_with_data(
    shaders.imgui_vs_size, &shaders.imgui_vs_data[0], shaders.imgui_vs_refl_size, &shaders.imgui_vs_refl_data[0],
    shaders.imgui_fs_size, &shaders.imgui_fs_data[0], shaders.imgui_fs_refl_size, &shaders.imgui_fs_refl_data[0],
  )
  
  log.debug("imgui plugin succesfully initialized")

  return nil
}

@(link_name="cr_main")
@export frag_plugin_main :: proc "c" (plugin: ^api.Plugin, e: api.Plugin_Event) -> i32 {
  context = runtime.default_context()

  switch e {
    case api.Plugin_Event.Load: {
      plugin_api = plugin.api
      core_api = cast(^api.Core_Api)plugin.api.get_api(api.Api_Type.Core)
      gfx_api = cast(^api.Gfx_Api)plugin.api.get_api(api.Api_Type.Gfx)
      app_api = cast(^api.App_Api)plugin.api.get_api(api.Api_Type.App)

      log.debug("initializing imgui plugin...")
      if init() != nil {
        return -1
      }

      plugin_api.inject_api("imgui", &imgui_api)

      // sokol.sg_imgui_init(&sg_imgui)
    }

    case api.Plugin_Event.Step: {
      // sokol.sg_imgui_draw(&sg_imgui)
    }

    case api.Plugin_Event.Unload: {

    }

    case api.Plugin_Event.Close: {

    }
  }
  
  return 0
}

@export
frag_plugin :: proc(info: ^api.Plugin_Info) {
  info.name = "imgui"
  info.desc = "dear-imgui plugin"
}

render :: proc "c" () {
  
}