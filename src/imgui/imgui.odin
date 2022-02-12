package imgui

import "thirdparty:cimgui"
import "thirdparty:sokol"

import "linchpin:error"
import "linchpin:pool"

import "frag:api"

import "./fonts"
import "./shaders"
import "./types"


import _c "core:c"
import "core:c/libc"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:math/linalg"
import "core:runtime"
import "core:strings"

MAX_VERTS :: 32760   // 32k
MAX_INDICES :: 98304 // 96k
MAX_BUFFERED_FRAME_TIMES :: 120

Imgui_Error :: enum {
  Init,
  BufferCreation,
}

Imgui_Shader_Uniforms :: struct {
  disp_size: linalg.Vector2f32,
  padding: [2]f32,
}

Imgui_Context :: struct {
  imgui_ctx: ^cimgui.Context,
  small_mem_pool: ^pool.Pool,
  max_verts: int,
  max_indices: int,
  verts: [dynamic]cimgui.Draw_Vert,
  indices: [dynamic]u16,
  shader: sokol.sg_shader,
  pipeline: sokol.sg_pipeline,
  bind: sokol.sg_bindings,
  font_tex: sokol.sg_image,
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
  DestroyContext = cimgui.igDestroyContext,
  GetIO = cimgui.igGetIO,
  NewFrame = cimgui.igNewFrame,
  EndFrame = cimgui.igEndFrame,
  Render = render,
  GetDrawData = cimgui.igGetDrawData,
  StyleColorsDark = cimgui.igStyleColorsDark,
  Begin = cimgui.igBegin,
  End = cimgui.igEnd,
  SetNextWindowContentSize = cimgui.igSetNextWindowContentSize,
  LabelText = cimgui.igLabelText,
  ImFontAtlas_AddFontFromMemoryCompressedTTF = cimgui.ImFontAtlas_AddFontFromMemoryCompressedTTF,
  ImFontAtlas_GetTexDataAsRGBA32 = cimgui.ImFontAtlas_GetTexDataAsRGBA32,
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

imgui_vertex_layout : api.Vertex_Layout


resize_buffers :: proc(max_verts: int, max_indices: int) -> Imgui_Error {
  assert(resize(&ctx.verts, max_verts))
  assert(resize(&ctx.indices, max_indices))

  gfx_api.destroy_buffer(ctx.bind.vertex_buffers[0])
  gfx_api.destroy_buffer(ctx.bind.index_buffer)

  ctx.bind.vertex_buffers[0] = gfx_api.make_buffer(&sokol.sg_buffer_desc {
    type = .SG_BUFFERTYPE_VERTEXBUFFER,
    usage = .SG_USAGE_STREAM,
    size = uint(size_of(cimgui.Draw_Vert) * MAX_VERTS),
    label = "imgui_vbuff",
  })

  ctx.bind.index_buffer = gfx_api.make_buffer(&sokol.sg_buffer_desc {
    type = .SG_BUFFERTYPE_INDEXBUFFER,
    usage = .SG_USAGE_STREAM,
    size = uint(size_of(u16) * MAX_INDICES),
    label = "imgui_ibuff",
  })

  ctx.max_verts = max_verts
  ctx.max_indices = max_indices

  return nil
}

init :: proc() -> Imgui_Error {
  context.allocator = core_api.alloc()
  context.logger = app_api.logger()^

  ctx.docking = app_api.config().imgui_docking
  ctx.imgui_ctx = imgui_api.CreateContext(nil)
  if ctx.imgui_ctx == nil {
    log.error("failed initializing dear imgui")
    return .Init
  }

  ini_filename : [64]u8
  conf := imgui_api.GetIO()
  conf.ini_filename = strings.clone_to_cstring(fmt.tprintf("%s_imgui.ini", app_api.name(), context.temp_allocator), context.temp_allocator)

  fb_scale := app_api.dpi_scale()
  conf.display_framebuffer_scale = {fb_scale, fb_scale}

  imgui_api.StyleColorsDark(nil)
  font_conf := cimgui.Font_Config {
    font_data_owned_by_atlas = true,
    oversample_h = 3,
    oversample_v = 1,
    rasterizer_multiply = 1.0,
    glyph_max_advance_x = max(f32),
  }

  imgui_api.ImFontAtlas_AddFontFromMemoryCompressedTTF(
    conf.fonts, &fonts.roboto_compressed_data[0], fonts.roboto_compressed_size, 14.0, &font_conf, nil,
  )

  conf.key_map[cimgui.Key.Tab] = i32(api.Key_Code.Tab)
  conf.key_map[cimgui.Key.LeftArrow] = i32(api.Key_Code.Left)
  conf.key_map[cimgui.Key.RightArrow] = i32(api.Key_Code.Right)
  conf.key_map[cimgui.Key.UpArrow] = i32(api.Key_Code.Up)
  conf.key_map[cimgui.Key.DownArrow] = i32(api.Key_Code.Down)
  conf.key_map[cimgui.Key.PageUp] = i32(api.Key_Code.Page_Up)
  conf.key_map[cimgui.Key.PageDown] = i32(api.Key_Code.Page_Down)
  conf.key_map[cimgui.Key.Home] = i32(api.Key_Code.Home)
  conf.key_map[cimgui.Key.End] = i32(api.Key_Code.End)
  conf.key_map[cimgui.Key.Insert] = i32(api.Key_Code.Insert)
  conf.key_map[cimgui.Key.Delete] = i32(api.Key_Code.Delete)
  conf.key_map[cimgui.Key.Backspace] = i32(api.Key_Code.Backspace)
  conf.key_map[cimgui.Key.Space] = i32(api.Key_Code.Space)
  conf.key_map[cimgui.Key.Enter] = i32(api.Key_Code.Enter)
  conf.key_map[cimgui.Key.KeyPadEnter] = i32(api.Key_Code.Kp_Enter)
  conf.key_map[cimgui.Key.Escape] = i32(api.Key_Code.Escape)
  conf.key_map[cimgui.Key.A] = i32(api.Key_Code.A)
  conf.key_map[cimgui.Key.C] = i32(api.Key_Code.C)
  conf.key_map[cimgui.Key.V] = i32(api.Key_Code.V)
  conf.key_map[cimgui.Key.X] = i32(api.Key_Code.X)
  conf.key_map[cimgui.Key.Y] = i32(api.Key_Code.Y)
  conf.key_map[cimgui.Key.Z] = i32(api.Key_Code.Z)

  if resize_buffers(MAX_VERTS, MAX_INDICES) != nil {
    log.error("failed creating vertex and or index buffer(s) for imgui")
    return .BufferCreation
  }

  font_pixels: [][]u8
  font_width, font_height, bpp : i32
  imgui_api.ImFontAtlas_GetTexDataAsRGBA32(conf.fonts, transmute(^^u8)&font_pixels, &font_width, &font_height, &bpp)
  desc := sokol.sg_image_desc {
    width = font_width,
    height = font_height,
    pixel_format = .SG_PIXELFORMAT_RGBA8,
    wrap_u = .SG_WRAP_CLAMP_TO_EDGE,
    wrap_v = .SG_WRAP_CLAMP_TO_EDGE,
    min_filter = .SG_FILTER_LINEAR,
    mag_filter = .SG_FILTER_LINEAR,
    label = "imgui_font",
  }
  desc.data.subimage[0][0].ptr = raw_data(font_pixels)
  desc.data.subimage[0][0].size = uint(font_width * font_height * 4)
  ctx.font_tex = gfx_api.make_image(&desc)
  conf.fonts.tex_id = cimgui.Texture_ID(uintptr(ctx.font_tex.id))

  shader := gfx_api.make_shader_with_data(
    shaders.imgui_vs_size, &shaders.imgui_vs_data[0], shaders.imgui_vs_refl_size, &shaders.imgui_vs_refl_data[0],
    shaders.imgui_fs_size, &shaders.imgui_fs_data[0], shaders.imgui_fs_refl_size, &shaders.imgui_fs_refl_data[0],
  )
  ctx.shader = shader.shd

  pipeline_desc := sokol.sg_pipeline_desc {
    shader = ctx.shader,
    index_type = .SG_INDEXTYPE_UINT16,
    cull_mode = .SG_CULLMODE_NONE,
    label = "imgui",
  }
  pipeline_desc.layout.buffers[0].stride = i32(size_of(cimgui.Draw_Vert))
  pipeline_desc.colors[0].write_mask = .SG_COLORMASK_RGB
  pipeline_desc.colors[0].blend.enabled = true
  pipeline_desc.colors[0].blend.src_factor_rgb = .SG_BLENDFACTOR_SRC_ALPHA
  pipeline_desc.colors[0].blend.dst_factor_rgb = .SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA

  ctx.pipeline = gfx_api.make_pipeline(gfx_api.bind_shader_to_pipeline(&shader, &pipeline_desc, &imgui_vertex_layout))

  ctx.stage = gfx_api.register_stage("imgui", {0})

  log.debug("imgui plugin succesfully initialized")

  return nil
}

frame :: proc() {
  io := imgui_api.GetIO()
  app_api.window_size(&io.display_size)
  io.delta_time = f32(sokol.stm_sec(core_api.delta_tick()))
  if io.delta_time == 0 {
    io.delta_time = 0.033
  }

  imgui_api.NewFrame()
}

shutdown :: proc() {
  if ctx.imgui_ctx != nil {
    imgui_api.DestroyContext(ctx.imgui_ctx)
  }

  gfx_api.destroy_shader(ctx.shader)
  delete(ctx.verts)
  delete(ctx.indices)
}

@(link_name="cr_main")
@export frag_plugin_main :: proc "c" (plugin: ^api.Plugin, e: api.Plugin_Event) -> i32 {
  context = runtime.default_context()
  context.allocator = core_api != nil ? core_api.alloc() : context.allocator
  context.logger = app_api != nil ? app_api.logger()^ : context.logger

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
      frame()
    }

    case api.Plugin_Event.Unload: {

    }

    case api.Plugin_Event.Close: {
      shutdown()
    }
  }
  
  return 0
}

@export
frag_plugin :: proc(info: ^api.Plugin_Info) {
  info.name = "imgui"
  info.desc = "dear-imgui plugin"
}

draw :: proc(data: ^cimgui.Draw_Data) {
  assert(data != nil)
  if data.cmd_lists_count == 0 {
    return
  }

  num_verts := 0
  num_indices := 0
  verts := ctx.verts
  indices := ctx.indices

  for dlist in 0 ..< data.cmd_lists_count {
    dl := (cast([^]^cimgui.Draw_List)data.cmd_lists)[dlist]
    dl_num_verts := dl.vtx_buffer.size
    dl_num_indices := dl.idx_buffer.size

    max_verts := ctx.max_verts
    max_indices := ctx.max_indices
    if int(num_verts + int(dl_num_verts)) > max_verts {
      log.warnf("imgui: max vertex count: %d - exceeded, growing buffers", ctx.max_verts)
      max_verts <<= 1
    }
    
    if (num_indices + int(dl_num_indices)) > max_indices {
      log.warnf("imgui: max index count: %d - exceeded, growing buffers", ctx.max_indices)
      max_indices <<= 1
    }

    if max_verts > ctx.max_verts || max_indices > int(ctx.max_indices) {
      err := resize_buffers(max_verts, max_indices)
      assert(err == nil, "imgui: vertex and or index buffer creation failed")
      verts = ctx.verts
      indices = ctx.indices
    }

    // mem.copy(&(transmute([]cimgui.Draw_List)verts)[num_verts], dl.vtx_buffer.data, int(dl_num_verts * size_of(cimgui.Draw_Vert)))
    mem.copy(&verts[num_verts], dl.vtx_buffer.data, int(dl_num_verts * size_of(cimgui.Draw_Vert)))

    src_index_ptr := cast([^]u16)(dl.idx_buffer.data)
    assert(num_verts <= int(max(u16)))
    base_vertex_idx := u16(num_verts)
    for i in 0 ..< dl_num_indices {
      indices[num_indices] = src_index_ptr[i] + base_vertex_idx
      num_indices += 1
    }
    num_verts += int(dl_num_verts)
  }

  gfx_api.imm.update_buffer(ctx.bind.vertex_buffers[0], &sokol.sg_range {raw_data(verts), uint(num_verts * size_of(cimgui.Draw_Vert)) })
  gfx_api.imm.update_buffer(ctx.bind.index_buffer, &sokol.sg_range { raw_data(indices), uint(num_indices * size_of(u16)) })

  io := imgui_api.GetIO()
  fb_scale := data.framebuffer_scale
  fb_pos := data.display_pos
  display_size := linalg.Vector2f32 {io.display_size.x, io.display_size.y}

  uniforms := Imgui_Shader_Uniforms { disp_size = display_size }
  base_elem := i32(0)
  last_img : sokol.sg_image
  ctx.bind.fs_images[0] = gfx_api.texture_white()
  gfx_api.imm.apply_pipeline(ctx.pipeline)
  gfx_api.imm.apply_bindings(&ctx.bind)
  gfx_api.imm.apply_uniforms(.SG_SHADERSTAGE_VS, 0, &uniforms, size_of(uniforms) )

  for dlist in 0 ..< data.cmd_lists_count {
    dl := mem.slice_ptr(data.cmd_lists, int(data.cmd_lists_count))[dlist]
    cmds := mem.slice_ptr(dl.cmd_buffer.data, int(dl.cmd_buffer.size))
    for cmd in cmds {
      if cmd.user_callback == nil {
        clip_rect : linalg.Vector4f32 = {
          (cmd.clip_rect.x - fb_pos.x) * fb_scale.x,
          (cmd.clip_rect.y - fb_pos.y) * fb_scale.y,
          (cmd.clip_rect.z - fb_pos.x) * fb_scale.x,
          (cmd.clip_rect.w - fb_pos.y) * fb_scale.y,
        }

        if clip_rect.x < display_size.x*fb_scale.x && clip_rect.y < display_size.y*fb_scale.y && clip_rect.z >= 0.0 && clip_rect.w >= 0.0 {
          scissor_x := i32(clip_rect.x)
          scissor_y := i32(clip_rect.y)
          scissor_w := i32(clip_rect.z - clip_rect.x)
          scissor_h := i32(clip_rect.w - clip_rect.y)

          tex : sokol.sg_image = {
            id = u32(uintptr(cmd.texture_id)),
          }
          if tex.id != last_img.id {
            ctx.bind.fs_images[0] = tex
            gfx_api.imm.apply_bindings(&ctx.bind)
          }
          gfx_api.imm.apply_scissor_rect(scissor_x, scissor_y, scissor_w, scissor_h, true)
          gfx_api.imm.draw(base_elem, i32(cmd.elem_count), 1)
        }
      }

      base_elem += i32(cmd.elem_count)
    }
  }

}

render :: proc "c" () {
  context = runtime.default_context()
  context.allocator = core_api != nil ? core_api.alloc() : context.allocator
  context.logger = app_api != nil ? app_api.logger()^ : context.logger
  
  cimgui.igRender()

  action := sokol.sg_pass_action {
    depth = { action = .SG_ACTION_DONTCARE },
    stencil = { action = .SG_ACTION_DONTCARE },
  }
  action.colors[0] = { action = .SG_ACTION_LOAD }

  if gfx_api.imm.begin(ctx.stage) {
    gfx_api.imm.begin_default_pass(&action, app_api.width(), app_api.height())
  }
  draw(imgui_api.GetDrawData())
  gfx_api.imm.end_pass()
  gfx_api.imm.end()
}

@(init, private)
init_imgui_plugin :: proc() {
  imgui_vertex_layout.attributes[0] = {semantic = "POSITION", offset = int(offset_of(cimgui.Draw_Vert, pos))}
  imgui_vertex_layout.attributes[1] = {semantic = "TEXCOORD", offset = int(offset_of(cimgui.Draw_Vert, uv))}
  imgui_vertex_layout.attributes[2] = {semantic = "COLOR", offset = int(offset_of(cimgui.Draw_Vert, col)), format = .SG_VERTEXFORMAT_UBYTE4N}
}

