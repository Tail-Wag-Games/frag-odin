package gfx

import "thirdparty:sokol"
import "thirdparty:lockless"

import "linchpin:alloc"
import "linchpin:memio"

import "frag:api"
import "frag:private"

import stbi "vendor:stb/image"

import _c "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:math/big"
import "core:mem"
import "core:path/filepath"
import "core:runtime"
import "core:slice"
import "core:strings"

Texture_Manager :: struct {
  white_tex: api.Texture,
  black_tex: api.Texture,
  checker_tex: api.Texture,
  default_min_filter: sokol.sg_filter,
  default_mag_filter: sokol.sg_filter,
  default_aniso: int,
  default_first_mip: i32,
}

Command :: enum {
  Begin_Default_Pass,
  Begin_Pass,
  Apply_Viewport,
  Apply_Scissor_Rect,
  Apply_Pipeline,
  Apply_Bindings,
  Apply_Uniforms,
  Draw,
  Dispatch,
  End_Pass,
  Update_Buffer,
  Update_Image,
  Append_Buffer,
  Begin_Profile,
  End_Profile,
  Stage_Push,
  Stage_Pop,
}

Command_Buffer_Ref :: struct {
  key: u32,
  cmd_buffer_idx: int,
  cmd: Command,
  params_offset: int,
}

Command_Buffer :: struct {
  params_buff: [dynamic]u8,
  refs: [dynamic]Command_Buffer_Ref,
  running_stage: api.Stage_Handle,
  index: int,
  stage_order: u16,
  cmd_idx: u16,
}

Stream_Buffer :: struct {
  buffer: sokol.sg_buffer,
  offset: lockless.atomic_u32,
  size: uint,
}

Stage_State :: enum {
  None,
  Submitting,
  Done,
}

Stage :: struct {
  name: [32]u8,
  name_hash: u32,
  state: Stage_State,
  parent: api.Stage_Handle,
  child: api.Stage_Handle,
  next: api.Stage_Handle,
  prev: api.Stage_Handle,
  order: u16,
  enabled: bool,
  single_enabled: bool,
}

Context :: struct {
  stages: [dynamic]Stage,
  cmd_buffers_feed: []Command_Buffer,
  cmd_buffers_render: []Command_Buffer,
  stage_lock: lockless.Spinlock,
  tex_mgr: Texture_Manager,
  pipelines: [dynamic]sokol.sg_pipeline,
  stream_buffers: [dynamic]Stream_Buffer,

  doomed_buffers: [dynamic]sokol.sg_buffer,
  doomed_shaders: [dynamic]sokol.sg_shader,
  doomed_pipelines: [dynamic]sokol.sg_pipeline,
  doomed_passes: [dynamic]sokol.sg_pass,
  doomed_images: [dynamic]sokol.sg_image,

  cur_stage_name: [32]u8,

  last_shader_error: bool,
}

Run_Command_Callback :: proc(buff: []u8, offset: int) -> ([]u8, int)

STAGE_ORDER_DEPTH_BITS :: 6
STAGE_ORDER_DEPTH_MASK :: 0xfc00
STAGE_ORDER_ID_BITS :: 10
STAGE_ORDER_ID_MASK :: 0x03ff

ctx : Context
gfx_alloc: mem.Allocator

run_command_cbs := [17]Run_Command_Callback {
  run_cb_begin_default_pass,
  run_cb_begin_pass,
  run_cb_begin_default_pass,
  run_cb_begin_default_pass,
  run_cb_apply_pipeline,
  run_cb_apply_bindings,
  run_cb_apply_uniforms,
  run_cb_draw,
  run_cb_begin_default_pass,
  run_cb_end_pass,
  run_cb_begin_default_pass,
  run_cb_begin_default_pass,
  run_cb_append_buffer,
  run_cb_begin_default_pass,
  run_cb_begin_default_pass,
  run_begin_cb_stage,
  run_cb_end_stage,
}

shader_lang_names := map[string]api.Shader_Lang {
  "glsl" = api.Shader_Lang.GLSL,
  "hlsl" = api.Shader_Lang.HLSL,
}

shader_stage_keys := map[api.Shader_Stage]string {
  .VS = "vs",
  .FS = "fs",
  .CS = "cs",
}

vertex_format_names := map[string]sokol.sg_vertex_format {
  "float" = .SG_VERTEXFORMAT_FLOAT,
  "float2" = .SG_VERTEXFORMAT_FLOAT2,
  "float3" = .SG_VERTEXFORMAT_FLOAT3,
  "float4" = .SG_VERTEXFORMAT_FLOAT,
  "byte4" = .SG_VERTEXFORMAT_BYTE4,
  "ubyte4" = .SG_VERTEXFORMAT_UBYTE4,
  "ubte4n" = .SG_VERTEXFORMAT_UBYTE4N,
  "short2" = .SG_VERTEXFORMAT_SHORT2,
  "short2n" = .SG_VERTEXFORMAT_SHORT2N,
  "short4" = .SG_VERTEXFORMAT_SHORT4,
  "short4n" = .SG_VERTEXFORMAT_SHORT4N,
  "uint10n2" = .SG_VERTEXFORMAT_UINT10_N2,
}

Texture_Type_Name :: struct {
  name: string,
  array: bool,
}

texture_type_names := map[Texture_Type_Name]sokol.sg_image_type {
  {"2d", true} = .SG_IMAGETYPE_ARRAY,
  {"2d", false} = .SG_IMAGETYPE_2D,
  {"3d", false} = .SG_IMAGETYPE_3D,
  {"3d", true} = .SG_IMAGETYPE_CUBE,
}

sg_map_buffer :: proc(buf_id: sokol.sg_buffer, offset: i32, data: rawptr, num_bytes: i32) {
  buf := sokol.sg_lookup_buffer(buf_id.id)
  if buf.map_frame_index != sokol.sg_frame_index() {
    buf.append_pos = 0
    buf.append_overflow = false
  }

  if (offset + num_bytes) > buf.size {
    buf.append_overflow = true
  }

  if buf.state == .SG_RESOURCESTATE_VALID {
    buf.append_pos = offset
    if sokol.sg_validate_append_buffer(&buf, buf_id.id, data, num_bytes) {
      if !buf.append_overflow && num_bytes > 0 {
        assert(buf.update_frame_index != sokol.sg_frame_index())
        assert(buf.append_frame_index != sokol.sg_frame_index())
        sokol.sg_append_debug_buffer(&buf, buf_id.id, data, num_bytes, buf.map_frame_index != sokol.sg_frame_index())
        sokol.sg_buffer_set_map_frame(buf_id.id, sokol.sg_frame_index())
      }
    }
  }
}

bind_shader_to_sg_pipeline :: proc(shd: sokol.sg_shader, inputs: []api.Shader_Input_Reflection_Data, desc: ^sokol.sg_pipeline_desc, layout: ^api.Vertex_Layout) -> ^sokol.sg_pipeline_desc {
  desc.shader = shd

  idx := 0
  attr := &layout.attributes[0]
  
  for len(attr.semantic) > 0 && idx < len(inputs) {
    found := false
    for i in 0 ..< len(inputs) {
      if attr.semantic == inputs[i].semantic &&
        attr.semantic_index == inputs[i].semantic_index {
          found = true

          desc.layout.attrs[i].offset = i32(attr.offset)
          desc.layout.attrs[i].format = attr.format != .SG_VERTEXFORMAT_INVALID ? attr.format : inputs[i].format
          desc.layout.attrs[i].buffer_index = i32(attr.buffer_index)
          break
        }
    }

    if !found {
      assert(false)
    }

    idx += 1
    attr = &layout.attributes[idx]
  }

  return desc
}

bind_shader_to_pipeline :: proc "c" (shd: ^api.Shader, desc: ^sokol.sg_pipeline_desc, layout: ^api.Vertex_Layout) -> ^sokol.sg_pipeline_desc {
  context = runtime.default_context()
  context.allocator = gfx_alloc
  
  return bind_shader_to_sg_pipeline(shd.shd, shd.info.inputs[:], desc, layout)
}

run_cb_end_pass :: proc(buff: []u8, offset: int) -> ([]u8, int) {
  sokol.sg_end_pass()
  return buff, offset
}

run_cb_begin_default_pass :: proc(buff: []u8, offset: int) -> ([]u8, int) {
  cur_offset := offset

  pass_action := cast(^sokol.sg_pass_action)&buff[cur_offset]
  cur_offset += size_of(sokol.sg_pass_action)
  width := cast(^i32)&buff[cur_offset]
  cur_offset += size_of(i32)
  height := cast(^i32)&buff[cur_offset]
  cur_offset += size_of(i32)

  sokol.sg_begin_default_pass(pass_action, width^, height^)

  return buff, cur_offset
}

run_cb_end_stage :: proc(buff: []u8, offset: int) -> ([]u8, int) {
  ctx.cur_stage_name[0] = u8(0)

  return buff, offset
}

execute_command_buffer :: proc(cmds: []Command_Buffer) -> int {
  assert(private.core_api.job_thread_index() == 0, "`execute_command_buffer` should only be invoked from main thread")

  cmd_count := 0
  cmd_buffer_count := private.core_api.num_job_threads()

  for i in 0 ..< cmd_buffer_count {
    cb := &cmds[i]
    assert(cb.running_stage.id == 0, "`end_stage` must be called for all command buffers which draw calls have been submitted for")
    cmd_count += len(cb.refs)
  }

  if cmd_count > 0 {
    refs := make([]Command_Buffer_Ref, cmd_count, context.temp_allocator)
    defer delete(refs, context.temp_allocator)

    cur_ref_count := 0
    init_refs := refs
    for i in 0 ..< cmd_buffer_count {
      cb := &cmds[i]
      ref_count := len(cb.refs)
      if ref_count > 0 {
        mem.copy(&refs[cur_ref_count], mem.raw_dynamic_array_data(cb.refs), size_of(Command_Buffer_Ref) * ref_count)
        cur_ref_count += ref_count
        runtime.clear_dynamic_array(&cb.refs)
      }
    }
    refs = init_refs

    slice.sort_by(refs, proc(x, y: Command_Buffer_Ref) -> bool {
      return x.key < y.key
    })

    for i in 0 ..< cmd_count {
      ref := &refs[i]
      cb := &cmds[ref.cmd_buffer_idx]
      run_command_cbs[ref.cmd](cb.params_buff[:], ref.params_offset)
    }
  }

  for i in 0 ..< cmd_buffer_count {
    clear(&cmds[i].params_buff)
    cmds[i].cmd_idx = 0
  }

  return cmd_count
}

execute_command_buffers :: proc () {

  execute_command_buffer(ctx.cmd_buffers_render)
  execute_command_buffer(ctx.cmd_buffers_feed)
  
  for i in 0 ..< len(ctx.stages) {
    ctx.stages[i].state = .None
  }

  for i in 0 ..< len(ctx.stream_buffers) {
    ctx.stream_buffers[i].offset = 0
  }
}

end_cb_stage :: proc "c" () {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  cb := &ctx.cmd_buffers_feed[private.core_api.job_thread_index()]
  assert(cb.running_stage.id != 0, "`begin_stage` must be called before `end_stage`")

  lockless.lock_enter(&ctx.stage_lock)
  stage := &ctx.stages[api.to_index(cb.running_stage.id)]
  assert(stage.state == .Submitting, "`begin_stage` must be caled before `end_stage`")
  stage.state = .Done
  lockless.lock_exit(&ctx.stage_lock)

  record_cb_end_stage()
  cb.running_stage = { id = 0 }
}

make_cb_params_buff :: proc(cb: ^Command_Buffer, size: int, offset: ^int) -> ^u8 {
  if size == 0 {
    return nil
  }
  
  current_len := len(cb.params_buff)
  resize(&cb.params_buff, current_len + alloc.align_mask(size, mem.DEFAULT_ALIGNMENT - 1))
  offset^ = int(mem.ptr_sub(&cb.params_buff[current_len], &cb.params_buff[0]))

  return &cb.params_buff[current_len]
}

end_imm_stage :: proc "c" () {

}

end_cb_pass :: proc "c" () {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  cb := &ctx.cmd_buffers_feed[private.core_api.job_thread_index()]

  assert(cb.running_stage.id != 0, "draw related calls must be issued between `begin_stage` and `end_stage`")
  assert(cb.cmd_idx < max(u16), "max number of graphics calls exceeded")

  ref := Command_Buffer_Ref {
    key = (u32(cb.stage_order << 16) | u32(cb.cmd_idx)),
    cmd_buffer_idx = cb.index,
    cmd = .End_Pass,
    params_offset = len(cb.params_buff),
  }
  append(&cb.refs, ref)

  cb.cmd_idx += 1
}

append_cb_buffer :: proc "c" (buffer: sokol.sg_buffer, data: rawptr, data_size: i32) -> i32 {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  index := -1
  for i in 0 ..< len(ctx.stream_buffers) {
    if ctx.stream_buffers[i].buffer.id == buffer.id {
      index = i
      break
    }
  }

  assert(index != -1, "buffer must be streamed and must not be destroyed during render")
  sbuffer := &ctx.stream_buffers[index]
  assert(u32(sbuffer.offset) + u32(data_size) <= u32(sbuffer.size))
  stream_offset := lockless.atomic_fetch_add32(transmute(^u32)&sbuffer.offset, u32(data_size))

  cb := &ctx.cmd_buffers_feed[private.core_api.job_thread_index()]

  assert(cb.running_stage.id != 0, "draw related calls must be issued between `begin_stage` and `end_stage`")
  assert(cb.cmd_idx < max(u16), "max number of graphics calls exceeded")

  offset := 0
  buff := make_cb_params_buff(cb, int(data_size) + size_of(i32) * 3 + size_of(sokol.sg_buffer), &offset)

  ref := Command_Buffer_Ref {
    key = (u32(cb.stage_order << 16) | u32(cb.cmd_idx)),
    cmd_buffer_idx = cb.index,
    cmd = .Append_Buffer,
    params_offset = offset,
  }
  append(&cb.refs, ref)

  cb.cmd_idx += 1

  (cast(^i32)buff)^ = i32(index)
  buff = mem.ptr_offset(buff, size_of(i32))
  (cast(^sokol.sg_buffer)buff)^ = buffer
  buff = mem.ptr_offset(buff, size_of(sokol.sg_buffer))
  (cast(^u32)buff)^ = stream_offset
  buff = mem.ptr_offset(buff, size_of(i32))
  (cast(^i32)buff)^ = i32(data_size)
  buff = mem.ptr_offset(buff, size_of(i32))
  mem.copy(buff, data, int(data_size))
  
  sokol.sg_buffer_set_used_frame(buffer.id, private.core_api.frame_index())

  return i32(stream_offset)
}

run_cb_append_buffer :: proc(buff: []u8, offset: int) -> ([]u8, int) {
  cur_offset := offset

  stream_idx := (cast(^i32)&buff[cur_offset])^
  cur_offset += size_of(i32)
  buf := (cast(^sokol.sg_buffer)&buff[cur_offset])^
  cur_offset += size_of(sokol.sg_buffer)
  stream_offset := (cast(^i32)&buff[cur_offset])^
  cur_offset += size_of(i32)
  data_size := (cast(^i32)&buff[cur_offset])^
  cur_offset += size_of(i32)

  assert(stream_idx < i32(len(ctx.stream_buffers)))
  stream_buffer := &ctx.stream_buffers[stream_idx]
  sg_map_buffer(buf, stream_offset, &buff[cur_offset], data_size)
  cur_offset += int(data_size)

  return buff, cur_offset
}

cb_draw :: proc "c" (base_element: i32, num_elements: i32, num_instances: i32) {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  cb := &ctx.cmd_buffers_feed[private.core_api.job_thread_index()]

  assert(cb.running_stage.id != 0, "draw related calls must be issued between `begin_stage` and `end_stage`")
  assert(cb.cmd_idx < max(u16), "max number of graphics calls exceeded")

  offset := 0
  buff := make_cb_params_buff(cb, size_of(i32) * 3, &offset)

  ref := Command_Buffer_Ref {
    key = (u32(cb.stage_order << 16) | u32(cb.cmd_idx)),
    cmd_buffer_idx = cb.index,
    cmd = .Draw,
    params_offset = offset,
  }
  append(&cb.refs, ref)

  cb.cmd_idx += 1

  (cast(^i32)buff)^ = base_element
  buff = mem.ptr_offset(buff, size_of(i32))
  (cast(^i32)buff)^ = num_elements
  buff = mem.ptr_offset(buff, size_of(i32))
  (cast(^i32)buff)^ = num_instances
}

run_cb_draw :: proc(buff: []u8, offset: int) -> ([]u8, int) {
  cur_offset := offset

  base_element := (cast(^i32)&buff[cur_offset])^
  cur_offset += size_of(i32)
  num_elements := (cast(^i32)&buff[cur_offset])^
  cur_offset += size_of(i32)
  num_instances := (cast(^i32)&buff[cur_offset])^
  cur_offset += size_of(i32)
  sokol.sg_draw(base_element, num_elements, num_instances)
  return buff, cur_offset
}

apply_cb_pipeline :: proc "c" (pipeline: sokol.sg_pipeline) {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  cb := &ctx.cmd_buffers_feed[private.core_api.job_thread_index()]

  assert(cb.running_stage.id != 0, "draw related calls must be issued between `begin_stage` and `end_stage`")
  assert(cb.cmd_idx < max(u16), "max number of graphics calls exceeded")

  offset := 0
  buff := make_cb_params_buff(cb, size_of(sokol.sg_pipeline), &offset)

  ref := Command_Buffer_Ref {
    key = (u32(cb.stage_order << 16) | u32(cb.cmd_idx)),
    cmd_buffer_idx = cb.index,
    cmd = .Apply_Pipeline,
    params_offset = offset,
  }
  append(&cb.refs, ref)

  cb.cmd_idx += 1

  (cast(^sokol.sg_pipeline)buff)^ = pipeline

  sokol.sg_pipeline_set_used_frame(pipeline.id, private.core_api.frame_index())
}

run_cb_apply_pipeline :: proc(buff: []u8, offset: int) -> ([]u8, int) {
  cur_offset := offset

  pipeline := (cast(^sokol.sg_pipeline)&buff[cur_offset])^
  sokol.sg_apply_pipeline(pipeline)
  cur_offset += size_of(sokol.sg_pipeline)
  return buff, cur_offset
}

apply_cb_bindings :: proc "c" (bind: ^sokol.sg_bindings) {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  cb := &ctx.cmd_buffers_feed[private.core_api.job_thread_index()]

  assert(cb.running_stage.id != 0, "draw related calls must be issued between `begin_stage` and `end_stage`")
  assert(cb.cmd_idx < max(u16), "max number of graphics calls exceeded")

  offset := 0
  buff := make_cb_params_buff(cb, size_of(sokol.sg_bindings), &offset)

  ref := Command_Buffer_Ref {
    key = (u32(cb.stage_order << 16) | u32(cb.cmd_idx)),
    cmd_buffer_idx = cb.index,
    cmd = .Apply_Bindings,
    params_offset = offset,
  }
  append(&cb.refs, ref)

  cb.cmd_idx += 1

  mem.copy(buff, bind, size_of(bind^))

  frame_idx := private.core_api.frame_index()

  for i in 0 ..< sokol.SG_MAX_SHADERSTAGE_BUFFERS {
    if bind.vertex_buffers[i].id > 0 {
      sokol.sg_buffer_set_used_frame(bind.vertex_buffers[i].id, frame_idx)
    } else {
      break
    }
  }

  if bind.index_buffer.id > 0 {
    sokol.sg_buffer_set_used_frame(bind.index_buffer.id, frame_idx)
  }

  for i in 0 ..< sokol.SG_MAX_SHADERSTAGE_IMAGES {
    if bind.vs_images[i].id > 0 {
      sokol.sg_image_set_used_frame(bind.vs_images[i].id, frame_idx)
    } else {
      break
    }
  }

  // for i in 0 ..< sokol.SG_MAX_SHADERSTAGE_BUFFERS {
  //   if bind.vs_buffers[i].id > 0 {
  //     sokol.sg_buffer_set_used_frame(bind.vs_buffers[i].id, frame_idx)
  //   } else {
  //     break
  //   }
  // }

  for i in 0 ..< sokol.SG_MAX_SHADERSTAGE_IMAGES {
    if bind.fs_images[i].id > 0 {
      sokol.sg_image_set_used_frame(bind.fs_images[i].id, frame_idx)
    } else {
      break
    }
  }

  // for i in 0 ..< sokol.SG_MAX_SHADERSTAGE_BUFFERS {
  //   if bind.fs_buffers[i].id > 0 {
  //     sokol.sg_buffer_set_used_frame(bind.fs_buffers[i].id, frame_idx)
  //   } else {
  //     break
  //   }
  // }
}

run_cb_apply_bindings :: proc(buff: []u8, offset: int) -> ([]u8, int) {
  cur_offset := offset

  bindings := cast(^sokol.sg_bindings)&buff[cur_offset]
  sokol.sg_apply_bindings(bindings)
  cur_offset += size_of(sokol.sg_bindings)
  return buff, cur_offset
}

apply_cb_uniforms :: proc "c" (stage: sokol.sg_shader_stage, ub_index: i32, data: rawptr, num_bytes: i32) {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  cb := &ctx.cmd_buffers_feed[private.core_api.job_thread_index()]

  assert(cb.running_stage.id != 0, "draw related calls must be issued between `begin_stage` and `end_stage`")
  assert(cb.cmd_idx < max(u16), "max number of graphics calls exceeded")

  offset := 0
  buff := make_cb_params_buff(cb, size_of(sokol.sg_shader_stage) + size_of(i32) + int(num_bytes), &offset)

  ref := Command_Buffer_Ref {
    key = (u32(cb.stage_order << 16) | u32(cb.cmd_idx)),
    cmd_buffer_idx = cb.index,
    cmd = .Apply_Uniforms,
    params_offset = offset,
  }
  append(&cb.refs, ref)

  cb.cmd_idx += 1

  (cast(^sokol.sg_shader_stage)buff)^ = stage
  buff = mem.ptr_offset(buff, size_of(sokol.sg_shader_stage))
  (cast(^i32)buff)^ = ub_index
  buff = mem.ptr_offset(buff, size_of(i32))
  (cast(^i32)buff)^ = i32(num_bytes)
  buff = mem.ptr_offset(buff, size_of(i32))
  mem.copy(buff, data, int(num_bytes))
  buff = mem.ptr_offset(buff, int(num_bytes))
}

run_cb_apply_uniforms :: proc(buff: []u8, offset: int) -> ([]u8, int) {
  cur_offset := offset

  stage := (cast(^sokol.sg_shader_stage)&buff[cur_offset])^
  cur_offset += size_of(sokol.sg_shader_stage)
  ub_index := (cast(^i32)&buff[cur_offset])^
  cur_offset += size_of(i32)
  num_bytes := (cast(^i32)&buff[cur_offset])^
  cur_offset += size_of(i32)
  data := cast(rawptr)&buff[cur_offset]
  sokol.sg_apply_uniforms(stage, ub_index, &{ data, uint(num_bytes) })
  cur_offset += int(num_bytes)
  return buff, cur_offset
}

begin_cb_pass :: proc "c" (pass: sokol.sg_pass, pass_action: ^sokol.sg_pass_action) {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  cb := &ctx.cmd_buffers_feed[private.core_api.job_thread_index()]

  assert(cb.running_stage.id != 0, "draw related calls must be issued between `begin_stage` and `end_stage`")
  assert(cb.cmd_idx < max(u16), "max number of graphics calls exceeded")

  offset := 0
  buff := make_cb_params_buff(cb, size_of(sokol.sg_pass_action) + size_of(sokol.sg_pass), &offset)

  ref := Command_Buffer_Ref {
    key = (u32(cb.stage_order << 16) | u32(cb.cmd_idx)),
    cmd_buffer_idx = cb.index,
    cmd = .Begin_Pass,
    params_offset = offset,
  }
  append(&cb.refs, ref)

  cb.cmd_idx += 1

  mem.copy(buff, pass_action, size_of(pass_action^))
  buff = mem.ptr_offset(buff, size_of(pass_action^))
  (cast(^sokol.sg_pass)buff)^ = pass

  sokol.sg_pass_set_used_frame(pass.id, private.core_api.frame_index())
}

run_cb_begin_pass :: proc(buff: []u8, offset: int) -> ([]u8, int) {
  cur_offset := offset

  pass_action := cast(^sokol.sg_pass_action)&buff[cur_offset]
  cur_offset += size_of(sokol.sg_pass_action)
  pass := (cast(^sokol.sg_pass)&buff[cur_offset])^
  cur_offset += size_of(sokol.sg_pass)
  sokol.sg_begin_pass(pass, pass_action)
  return buff, cur_offset
}

begin_cb_default_pass :: proc "c" (pass_action: ^sokol.sg_pass_action, width: i32, height: i32) {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  cb := &ctx.cmd_buffers_feed[private.core_api.job_thread_index()]

  assert(cb.running_stage.id != 0, "draw related calls must be issued between `begin_stage` and `end_stage`")
  assert(cb.cmd_idx < max(u16), "max number of graphics calls exceeded")

  offset := 0
  buff := make_cb_params_buff(cb, size_of(sokol.sg_pass_action) + size_of(i32) * 2, &offset)

  ref := Command_Buffer_Ref {
    key = (u32(cb.stage_order << 16) | u32(cb.cmd_idx)),
    cmd_buffer_idx = cb.index,
    cmd = .Begin_Default_Pass,
    params_offset = offset,
  }
  append(&cb.refs, ref)

  cb.cmd_idx += 1

  mem.copy(buff, pass_action, size_of(pass_action^))
  buff = mem.ptr_offset(buff, size_of(pass_action^))
  (cast(^i32)buff)^ = width
  buff = mem.ptr_offset(buff, size_of(i32))
  (cast(^i32)buff)^ = height
}

record_cb_end_stage :: proc() {
  cb := &ctx.cmd_buffers_feed[private.core_api.job_thread_index()]

  assert(cb.running_stage.id != 0, "draw related calls must be issued between `begin_stage` and `end_stage`")
  assert(cb.cmd_idx < max(u16), "max number of graphics calls exceeded")

  ref := Command_Buffer_Ref {
    key = ((u32(cb.stage_order) << 16) | u32(cb.cmd_idx)),
    cmd_buffer_idx = cb.index,
    cmd = .Stage_Pop,
    params_offset = len(cb.params_buff),
  }
  append(&cb.refs, ref)

  cb.cmd_idx += 1
}

begin_cb_stage :: proc "c" (stage_handle: api.Stage_Handle) -> bool {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  cb := &ctx.cmd_buffers_feed[private.core_api.job_thread_index()]

  stage : ^Stage
  lockless.lock_enter(&ctx.stage_lock)
  stage = &ctx.stages[api.to_index(stage_handle.id)]
  assert(stage.state == .None, "begin was already called on this stage")
  enabled := stage.enabled
  if !enabled {
    lockless.lock_exit(&ctx.stage_lock)
    return false  
  }
  stage.state = .Submitting
  cb.running_stage = stage_handle
  cb.stage_order = stage.order
  lockless.lock_exit(&ctx.stage_lock)

  record_cb_begin_stage(transmute(cstring)&stage.name[0], size_of(stage.name))

  return true
}

record_cb_begin_stage :: proc(name: cstring, name_size: int) {
  assert(name_size == 32)

  cb := &ctx.cmd_buffers_feed[private.core_api.job_thread_index()]

  assert(cb.running_stage.id != 0, "draw related calls must be issued between `begin_stage` and `end_stage`")
  assert(cb.cmd_idx < max(u16), "max number of graphics calls exceeded")

  offset := 0
  buff := make_cb_params_buff(cb, name_size, &offset)

  ref := Command_Buffer_Ref {
    key = ((u32(cb.stage_order) << 16) | u32(cb.cmd_idx)),
    cmd_buffer_idx = cb.index,
    cmd = .Stage_Push,
    params_offset = offset,
  }
  append(&cb.refs, ref)

  cb.cmd_idx += 1

  mem.copy(buff, transmute(rawptr)name, name_size)
}

run_begin_cb_stage :: proc(buff: []u8, offset: int) -> ([]u8, int) {
  cur_offset := offset

  name := cast(cstring)&buff[cur_offset]
  cur_offset += 32

  mem.copy(&ctx.cur_stage_name[0], transmute(rawptr)name, size_of(ctx.cur_stage_name))
  
  return buff, cur_offset
}

begin_imm_stage :: proc "c" (stage_handle: api.Stage_Handle) -> bool {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  stage : ^Stage
  stage_name: string

  lockless.lock_enter(&ctx.stage_lock)
  stage = &ctx.stages[api.to_index(stage_handle.id)]
  assert(stage.state == .None, "begin was already called on this stage")
  enabled := stage.enabled
  if !enabled {
    lockless.lock_exit(&ctx.stage_lock)
    return false  
  }
  stage.state = .Submitting
  stage_name = strings.clone_from_bytes(stage.name[:], context.temp_allocator)
  lockless.lock_exit(&ctx.stage_lock)

  return true
}

add_child_stage :: proc(parent, child: api.Stage_Handle) {
  p := &ctx.stages[api.to_index(parent.id)]
  c := &ctx.stages[api.to_index(child.id)]
  if p.child.id > 0 {
    first_child := &ctx.stages[api.to_index(p.child.id)]
    first_child.prev = child
    c.next = p.child
  }

  p.child = child
}

register_stage :: proc "c" (name: string, parent_stage: api.Stage_Handle) -> api.Stage_Handle {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  stage := Stage {
    name_hash = hash.fnv32a(transmute([]u8)name),
    parent = parent_stage,
    enabled = true,
    single_enabled = true,
  }
  mem.copy(&stage.name[0], mem.raw_string_data(name), size_of(stage.name))

  handle := api.Stage_Handle {
    id = api.to_id(len(ctx.stages)),
  }

  depth := u16(0)
  if parent_stage.id > 0 {
    parent_depth := (ctx.stages[api.to_index(parent_stage.id)].order >> STAGE_ORDER_DEPTH_BITS) & 
      STAGE_ORDER_DEPTH_MASK
    depth = parent_depth + 1
  }

  stage.order = ((depth << STAGE_ORDER_DEPTH_BITS) & STAGE_ORDER_DEPTH_MASK) |
    u16(api.to_index(handle.id) & STAGE_ORDER_ID_MASK)
  append(&ctx.stages, stage)

  if parent_stage.id > 0 {
    add_child_stage(parent_stage, handle)
  }

  return handle
}

make_buffer :: proc "c" (desc: ^sokol.sg_buffer_desc) -> sokol.sg_buffer {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  buf_id := sokol.sg_make_buffer(desc)
  if desc.usage == .SG_USAGE_STREAM {
    sbuff := Stream_Buffer { buffer = buf_id, offset = 0, size = desc.size }
    append(&ctx.stream_buffers, sbuff)
  }

  return buf_id
}

make_pipeline :: proc "c" (desc: ^sokol.sg_pipeline_desc) -> sokol.sg_pipeline {
  ctx.last_shader_error = false

  pipeline := sokol.sg_make_pipeline(desc)

  if ctx.last_shader_error {

  }

  return pipeline
}

parse_shader_reflection_json :: proc(stage_refl_json: []u8, stage_refl_json_len: int) -> ^api.Shader_Reflection_Data {
  parsed, err := json.parse(stage_refl_json[:stage_refl_json_len], json.DEFAULT_SPECIFICATION, true)
  defer json.destroy_value(parsed)
  
  obj := parsed.(json.Object)

  stage : api.Shader_Stage
  stage_key : string
  if "vs" in obj {
    stage = .VS
    stage_key = shader_stage_keys[stage]
  } else if "fs" in obj {
    stage = .FS
    stage_key = shader_stage_keys[stage]
  } else if "cs" in obj {
    stage = .CS
    stage_key = shader_stage_keys[stage]
  }
  
  refl := new(api.Shader_Reflection_Data)
  refl.lang = shader_lang_names[obj["language"].(string)]
  refl.stage = stage
  refl.profile_version = int(obj["profile_version"].(i64))
  refl.code_type = "bytecode" in obj ? .Bytecode : .Source
  refl.flatten_ubos = "flatten_ubos" in obj
  
  stage_obj := obj[stage_key].(json.Object)
  refl.source_file = strings.clone(stage_obj["file"].(string), context.temp_allocator)

  if "inputs" in stage_obj {
    inputs := stage_obj["inputs"].(json.Array)
    refl.inputs = make([]api.Shader_Input_Reflection_Data, len(inputs))
    for i in 0 ..< len(inputs) {
      input := &refl.inputs[i]
      input_reflection_data := inputs[i].(json.Object)
      input.name = "name" in input_reflection_data ? strings.clone(input_reflection_data["name"].(string), context.temp_allocator) : ""
      input.semantic = "semantic" in input_reflection_data ? strings.clone(input_reflection_data["semantic"].(string), context.temp_allocator) : ""
      input.semantic_index = "semantic_index" in input_reflection_data ? int(input_reflection_data["semantic_index"].(i64)) : 0
      input.format = "type" in input_reflection_data ? vertex_format_names[input_reflection_data["type"].(string)] : .SG_VERTEXFORMAT_NUM
    }
  }
  

  if "uniform_buffers" in stage_obj {
    uniform_buffers := stage_obj["uniform_buffers"].(json.Array)
    refl.uniform_buffers = make([]api.Shader_Uniform_Buffer_Reflection_Data, len(uniform_buffers))
    for i in 0 ..< len(uniform_buffers) {
      ubo := &refl.uniform_buffers[i]
      ubo_reflection_data := uniform_buffers[i].(json.Object)
      ubo.name = "name" in ubo_reflection_data ? strings.clone(ubo_reflection_data["name"].(string), context.temp_allocator) : ""
      ubo.size_in_bytes = "block_size" in ubo_reflection_data ? int(ubo_reflection_data["block_size"].(i64)) : 0
      ubo.binding = "binding" in ubo_reflection_data ? int(ubo_reflection_data["binding"].(i64)) : 0
      ubo.array_size = "array" in ubo_reflection_data ? int(ubo_reflection_data["array"].(i64)) : 1
      
      if ubo.array_size > 1 {
        assert(refl.flatten_ubos, "array uniform buffers must be generated using --flatten-ubos glscc option")
      }
    }
  }

  if "textures" in stage_obj {
    textures := stage_obj["textures"].(json.Array)
    refl.textures = make([]api.Shader_Texture_Reflection_Data, len(textures))
    for i in 0 ..< len(textures) {
      texture := &refl.textures[i]
      texture_reflection_data := textures[i].(json.Object)
      texture.name = "name" in texture_reflection_data ? strings.clone(texture_reflection_data["name"].(string), context.temp_allocator) : ""
      texture.binding = "binding" in texture_reflection_data ? int(texture_reflection_data["binding"].(i64)) : 0
      texture.image_type = texture_type_names[
        { 
          "dimension" in texture_reflection_data ? texture_reflection_data["dimension"].(string) : "", 
          "array" in texture_reflection_data ? texture_reflection_data["array"].(bool) : false,
        }
      ]
    }
  }

  if "storage_images" in stage_obj {
    storage_images := stage_obj["storage_images"].(json.Array)
    refl.storage_images = make([]api.Shader_Texture_Reflection_Data, len(storage_images))
    for i in 0 ..< len(storage_images) {
      storage_image := &refl.storage_images[i]
      storage_image_reflection_data := storage_images[i].(json.Object)
      storage_image.name = "name" in storage_image_reflection_data ? strings.clone(storage_image_reflection_data["name"].(string), context.temp_allocator) : ""
      storage_image.binding = "binding" in storage_image_reflection_data ? int(storage_image_reflection_data["binding"].(i64)) : 0      
      storage_image.image_type = texture_type_names[
        { 
          "dimension" in storage_image_reflection_data ? storage_image_reflection_data["dimension"].(string) : "", 
          "array" in storage_image_reflection_data ? storage_image_reflection_data["array"].(bool) : false,
        }
      ]
    }
  }

  if "storage_buffers" in stage_obj {
    storage_buffers := stage_obj["storage_buffers"].(json.Array)
    refl.storage_buffers = make([]api.Shader_Buffer_Reflection_Data, len(storage_buffers))
    for i in 0 ..< len(storage_buffers) {
      storage_buffer := &refl.storage_buffers[i]
      storage_buffer_reflection_data := storage_buffers[i].(json.Object)
      storage_buffer.name = "name" in storage_buffer_reflection_data ? strings.clone(storage_buffer_reflection_data["name"].(string), context.temp_allocator) : ""
      storage_buffer.size_in_bytes = "block_size" in storage_buffer_reflection_data ? int(storage_buffer_reflection_data["block_size"].(i64)) : 0
      storage_buffer.binding = "binding" in storage_buffer_reflection_data ? int(storage_buffer_reflection_data["binding"].(i64)) : 0
      storage_buffer.array_stride = "unsized_array_stride" in storage_buffer_reflection_data ? int(storage_buffer_reflection_data["unsized_array_stride"].(i64)) : 1
    }
  }

  return refl
}

Shader_Stage_Setup_Desc :: struct {
  refl: ^api.Shader_Reflection_Data,
  code: rawptr,
  code_size: int,
}

setup_shader_desc :: proc(desc: ^sokol.sg_shader_desc, vs_refl: ^api.Shader_Reflection_Data, vs: rawptr, vs_size: int, fs_refl: ^api.Shader_Reflection_Data, fs: rawptr, fs_size: int, name_handle: ^u32) -> ^sokol.sg_shader_desc {
  num_stages :: 2
  stages := [2]Shader_Stage_Setup_Desc{
    {refl = vs_refl, code = vs, code_size = vs_size},
    {refl = fs_refl, code = fs, code_size = fs_size},
  }

  // if name_handle != nil {
  //   desc.label = core
  // }

  for i in 0 ..< num_stages {
    stage := &stages[i]
    stage_desc : ^sokol.sg_shader_stage_desc = nil
    #partial switch stage.refl.stage {
      case .VS: {
        stage_desc = &desc.vs
        stage_desc.d3d11_target = "vs_5_0"
      }
      case .FS: {
        stage_desc = &desc.fs
        stage_desc.d3d11_target = "ps_5_0"
      }
      case: {
        assert(false, "not implemented")
      }
    }

    if stage.refl.code_type == .Bytecode {
      stage_desc.bytecode.ptr = stage.code
      stage_desc.bytecode.size = uint(stage.code_size)
    } else if stage.refl.code_type == .Source {
      stage_desc.source = cast(cstring)stage.code
    }

    if stage.refl.stage == .VS {
      for attri in 0 ..< len(vs_refl.inputs) {
        desc.attrs[attri].name = strings.clone_to_cstring(vs_refl.inputs[attri].name, context.temp_allocator)
        desc.attrs[attri].sem_name = strings.clone_to_cstring(vs_refl.inputs[attri].semantic, context.temp_allocator)
        desc.attrs[attri].sem_index = i32(vs_refl.inputs[attri].semantic_index)
      }
    }

    for uboi in 0 ..< len(stage.refl.uniform_buffers) {
      ubord := &stage.refl.uniform_buffers[uboi]
      ub_desc := &stage_desc.uniform_blocks[ubord.binding]
      ub_desc.size = uint(ubord.size_in_bytes)
      if stage.refl.flatten_ubos {
        ub_desc.uniforms[0].array_count = i32(ubord.array_size)
        ub_desc.uniforms[0].name = strings.clone_to_cstring(ubord.name, context.temp_allocator)
        ub_desc.uniforms[0].type = .SG_UNIFORMTYPE_FLOAT4
      }
      
      // NOTE: Individual uniform names are supported by reflection json,
      //       however they are not being parsed or used here, as d3d/metal shaders don't
      //       requuire them and for gl/gles, they are always flattened
    }

    for texi in 0 ..< len(stage.refl.textures) {
      texrd := &stage.refl.textures[texi]
      img := &stage_desc.images[texrd.binding]
      img.name = strings.clone_to_cstring(texrd.name, context.temp_allocator)
      img.image_type = texrd.image_type
    }

    // TODO: This is for compute shaders only
    // for imgi in 0 ..< len(stage.refl.storage_images) {
    //   imgrd := &stage.refl.storage_images[imgi]
    //   img := stage_desc.images[imgrd.binding]
    //   img.name = strings.clone_to_cstring(imgrd.name, context.temp_allocator)
    //   img.image_type = imgrd.image_type
    // }
  }

  return desc
}

make_shader_with_data :: proc "c" (vs_data_size: u32, vs_data: [^]u32, vs_refl_size: u32, vs_refl_json: [^]u32, fs_data_size: u32, fs_data: [^]u32, fs_refl_size: u32, fs_refl_json: [^]u32) -> api.Shader {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  desc : sokol.sg_shader_desc
  vs_refl := parse_shader_reflection_json(transmute([]u8)vs_refl_json[:vs_refl_size], int(vs_refl_size) - 1)
  fs_refl := parse_shader_reflection_json(transmute([]u8)fs_refl_json[:fs_refl_size], int(fs_refl_size) - 1)

  s : api.Shader 
  s = {
    shd = sokol.sg_make_shader(setup_shader_desc(&desc, vs_refl, vs_data, int(vs_data_size), fs_refl, fs_data, int(fs_data_size), &s.info.name_handle)),
  }
  s.info.num_inputs = min(len(vs_refl.inputs), sokol.SG_MAX_VERTEX_ATTRIBUTES)
  for i in 0 ..< s.info.num_inputs {
    s.info.inputs[i] = vs_refl.inputs[i]
  }
  destroy_shader_reflection_data(vs_refl)
  destroy_shader_reflection_data(fs_refl)

  return s
}

destroy_buffer :: proc "c" (buf: sokol.sg_buffer) {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  if buf.id != 0 {
    queue_destruction(&ctx.doomed_buffers, buf)
  }
}

destroy_shader_reflection_data :: proc(refl: ^api.Shader_Reflection_Data) {
  assert(refl != nil)
  delete(refl.inputs)
  delete(refl.textures)
  delete(refl.storage_images)
  delete(refl.storage_buffers)
  delete(refl.uniform_buffers)
  free(refl)
}

destroy_shader :: proc "c" (shd: sokol.sg_shader) {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  if shd.id != 0 {
    queue_destruction(&ctx.doomed_shaders, shd)
  }
}

destroy_pipeline :: proc "c" (pip: sokol.sg_pipeline) {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  if pip.id != 0 {
    queue_destruction(&ctx.doomed_pipelines, pip)
  }
}

destroy_pass :: proc "c" (pass: sokol.sg_pass) {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  if pass.id != 0 {
    queue_destruction(&ctx.doomed_passes, pass)
  }
}

destroy_image :: proc "c" (img: sokol.sg_image) {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  if img.id != 0 {
    queue_destruction(&ctx.doomed_images, img)
  }
}

mipcnt :: proc(x, y, z: i32) -> i32 {
  return big.ilog2(max(max(x,y), z))
}

on_prepare_texture :: proc "c" (params: ^api.Asset_Load_Params, mb: ^memio.Mem_Block) -> api.Asset_Load_Data {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  fmt.println("in on_prepare_texture")
  res := new(api.Texture)

  info := &res.info
  ext := filepath.ext(string(params.path))
  // TODO:
  // Need to check extension to vary loading ktx / dds

  comp : i32
  if bool(stbi.info_from_memory(transmute([^]u8)mb.data, i32(mb.size), &info.width, &info.height, &comp)) {
    assert(info.width > 0 && info.height > 0, fmt.tprintf("invalid image size (%d,%d): %s", info.width, info.height, params.path))

    is_16_bit := bool(stbi.is_16_bit_from_memory(transmute([^]u8)mb.data, i32(mb.size)))
    mipcnt := is_16_bit ? mipcnt(info.width, info.height, 1) : 1

    info.image_type = .SG_IMAGETYPE_2D
    info.format = is_16_bit ? .SG_PIXELFORMAT_R16 : .SG_PIXELFORMAT_RGBA8
    info.size_in_bytes = is_16_bit ? 2 * info.width * info.height : 4 * info.width * info.height
    info.layers = 1
    info.mips = mipcnt
    info.bpp = is_16_bit ? 16 : 32
  } else {
    fmt.println("reading image matadata failed")
    mem.zero(info, size_of(api.Texture_Info))
  }

  res.img = private.gfx_api.alloc_image()
  assert(bool(res.img.id))

  user_data := new(sokol.sg_image_desc, gfx_alloc)

  return { obj = { ptr =  res }, user1 = user_data }
} 


on_load_texture :: proc "c" (data: ^api.Asset_Load_Data, params: ^api.Asset_Load_Params, mem: ^memio.Mem_Block) -> bool {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  tparams := cast(^api.Texture_Load_Params)params.params
  tex := cast(^api.Texture)data.obj.ptr
  desc := cast(^sokol.sg_image_desc)data.user1

  first_mip := tparams.first_mip != 0 ? tparams.first_mip : ctx.tex_mgr.default_first_mip
  if first_mip >= tex.info.mips {
    first_mip = tex.info.mips - 1
  }
  num_mips := tex.info.mips - first_mip

  tw := tex.info.width
  th := tex.info.height

  for i in 0..< first_mip {
    tw >>= 1
    th >>= 1
  }

  tex.info.mips = num_mips
  tex.info.width = tw
  tex.info.height = th

  assert(desc != nil)
  desc^ = {
    type = tex.info.image_type,
    width = tex.info.width,
    height = tex.info.height,
    num_slices = tex.info.layers,
    num_mipmaps = num_mips,
    pixel_format = tex.info.format,
    min_filter = tparams.min_filter != sokol.sg_filter(0) ? tparams.min_filter : ctx.tex_mgr.default_min_filter,
    mag_filter = tparams.mag_filter != sokol.sg_filter(0) ? tparams.mag_filter : ctx.tex_mgr.default_mag_filter,
    wrap_u = tparams.wrap_u,
    wrap_v = tparams.wrap_v,
    wrap_w = tparams.wrap_w,
    max_anisotropy = tparams.aniso != 0 ? u32(tparams.aniso) : u32(ctx.tex_mgr.default_aniso),
  }

  

  w, h, cmp: i32
  if tex.info.bpp == 16 {
    texels := stbi.load_16_from_memory(transmute([^]u8)mem.data, i32(mem.size), &w, &h, &cmp, 1)
    if texels != nil {
      total_size := uint(w * h * 2)
      tw := w
      th := h
      for i in 1 ..< sokol.SG_MAX_MIPMAPS {
        tw /= 2
        th /= 2

        if tw < 1 && th < 1 {
          break
        }

        total_size += uint(tw * th * 2)
      }

      tex_data := make([]u16, total_size)

      tw = w
      th = h
      for i in 1 ..< sokol.SG_MAX_MIPMAPS {
        tw /= 2
        th /= 2

        if tw < 1 && th < 1 {
          break
        }

        mip_lvl_sz := uint(tw * th * 2)
        desc.data.subimage[0][i].ptr = &tex_data[(tw * th * 2)]
        desc.data.subimage[0][i].size = mip_lvl_sz
      }

      for j in 0 ..< h {
        for i in 0 ..< w {
          z := texels[i + w * j]
          zf := f32(z) / f32((1 << 16) - 1)
          z2 := cast(u16)(zf * zf * ((1 << 16) - 1))

          tex_data[2 * (i + w * j)] = z
          tex_data[1 + 2 * (i + w * j)] = z2
        }
      }
      
      stbi.image_free(cast(rawptr)texels)

      desc.data.subimage[0][0].ptr = &tex_data[0]
      desc.data.subimage[0][0].size = uint(w * h * 2)
    }
  } else {
    texels := stbi.load_from_memory(transmute([^]u8)mem.data, i32(mem.size), &w, &h, &cmp, 4)
    if texels != nil {
      desc.data.subimage[0][0].ptr = texels
      desc.data.subimage[0][0].size = uint(w * h * 4)
    }
  }

  fmt.println("finished loading texture!")

  return true
}


on_finalize_texture :: proc "c" (data: ^api.Asset_Load_Data, params: ^api.Asset_Load_Params, mem: ^memio.Mem_Block) {
  context = runtime.default_context()
  context.allocator = gfx_alloc
  
  fmt.println("finalizing texture!!!")

  tex := cast(^api.Texture)data.obj.ptr
  desc := cast(^sokol.sg_image_desc)data.user1
  assert(desc != nil)

  private.gfx_api.init_image(tex.img, desc)
  assert(desc.data.subimage[0][0].ptr != nil)
  
  free(cast(rawptr)desc.data.subimage[0][0].ptr)
  free(data.user1)

  fmt.println("Initialized image!!!!!!")
}


on_reload_texture :: proc "c" (handle: api.Asset_Handle, prev_obj: api.Asset_Object) {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  fmt.println("in on_reload_texture")
}


on_release_texture :: proc "c" (obj: api.Asset_Object) {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  fmt.println("in on_release_texture")
}

on_prepare_shader :: proc "c" (params: ^api.Asset_Load_Params, mem: ^memio.Mem_Block) -> api.Asset_Load_Data {
  context = runtime.default_context()
  context.allocator = gfx_alloc
  
  fmt.println("Inside on prepare shader!")
  return {}
}


on_load_shader :: proc "c" (data: ^api.Asset_Load_Data, params: ^api.Asset_Load_Params, mem: ^memio.Mem_Block) -> bool {
  return true
}


on_finalize_shader :: proc "c" (data: ^api.Asset_Load_Data, params: ^api.Asset_Load_Params, mem: ^memio.Mem_Block) {

}


on_reload_shader :: proc "c" (handle: api.Asset_Handle, prev_obj: api.Asset_Object) {

}


on_release_shader :: proc "c" (obj: api.Asset_Object) {

}


init_shaders :: proc() {
  private.asset_api.register_asset_type("shader", api.Asset_Callbacks{
    on_prepare = on_prepare_shader,
    on_load = on_load_shader,
    on_finalize = on_finalize_shader,
    on_reload = on_reload_shader,
    on_release = on_release_shader,
  }, nil, 0)
}

texture_white :: proc "c" () -> sokol.sg_image {
  return ctx.tex_mgr.white_tex.img
}

texture_black :: proc "c" () -> sokol.sg_image {
  return ctx.tex_mgr.black_tex.img
}

init_textures :: proc() {
  @static white_pixel := u32(0xffffffff)
  @static black_pixel := u32(0xff000000)

  img_desc := sokol.sg_image_desc {
    width = 1,
    height = 1,
    num_mipmaps = 1,
    pixel_format = .SG_PIXELFORMAT_RGBA8,
    label = "frag_white_texture_1x1",
  }
  img_desc.data.subimage[0][0].ptr = &white_pixel
  img_desc.data.subimage[0][0].size = size_of(white_pixel)

  ctx.tex_mgr.white_tex = api.Texture {
    img = sokol.sg_make_image(&img_desc),
    info = {
      image_type = .SG_IMAGETYPE_2D,
      format = .SG_PIXELFORMAT_RGBA8,
      size_in_bytes = size_of(white_pixel),
      width = 1,
      height = 1,
      dl = {
        layers = 1,
      },
      mips = 1,
      bpp = 32,
    },
  }

  private.asset_api.register_asset_type(
    "texture",
    {
      on_prepare = on_prepare_texture,
      on_load = on_load_texture,
      on_finalize = on_finalize_texture,
      on_reload = on_reload_texture,
      on_release = on_release_texture,
    },
    "Texture_Load_Params",
    size_of(api.Texture_Load_Params),
  )
}

create_command_buffers :: proc() -> []Command_Buffer {
  num_threads := int(private.core_api.num_job_threads())
  cbs := make([]Command_Buffer, num_threads)

  for i in 0 ..< num_threads {
    cbs[i].index = i
  }

  return cbs
}

init :: proc(desc: ^sokol.sg_desc, allocator := context.allocator) {
  gfx_alloc = allocator

  sokol.sg_setup(desc)
  sokol.malloc_callback(proc "c" (size: _c.size_t) -> rawptr {
    context = runtime.default_context()
    context.allocator = gfx_alloc
    return mem.alloc(int(size))
  })

  sokol.log_callback(proc "c" (msg: cstring) {
    context = runtime.default_context()
    context.allocator = gfx_alloc

    fmt.println(msg)
  })

  sokol.free_callback(proc "c" (ptr: rawptr) {
    context = runtime.default_context()
    context.allocator = gfx_alloc
    free(ptr)
  })

  ctx.cmd_buffers_feed = create_command_buffers()
  ctx.cmd_buffers_render = create_command_buffers()

  init_textures()
  init_shaders()
}

destroy_buffers :: proc(cbs: []Command_Buffer) {
  for i in 0 ..< private.core_api.num_job_threads() {
    cb := &cbs[i]
    assert(cb.running_stage.id == 0)
    delete(cb.params_buff)
    delete(cb.refs)
  }
}

destroy_textures :: proc() {
  if ctx.tex_mgr.white_tex.img.id > 0 {
    destroy_image(ctx.tex_mgr.white_tex.img)
  }
  if ctx.tex_mgr.black_tex.img.id > 0 {
    destroy_image(ctx.tex_mgr.black_tex.img)
  }
  if ctx.tex_mgr.checker_tex.img.id > 0 {
    destroy_image(ctx.tex_mgr.checker_tex.img)
  }
}

update :: proc() {
  collect_garbage(private.core_api.frame_index())
}

collect_garbage :: proc(frame: i64) {
  // check frames and destroy objects if they are past 1 frame
  // the reason is because the _staged_ API executes commands one frame after their calls:
  //          frame #1
  // <--------------------->
  //      staged->destroy
  //    execute queued cmds |->      frame #2
  //                        <---------------------->
  //

  // buffers
  i := 0
  c := len(ctx.doomed_buffers)
  for ; i < c; i += 1 {
    buffer := ctx.doomed_buffers[i]
    buffer_lookup_result := sokol.sg_lookup_buffer(buffer.id)
    if frame > buffer_lookup_result.used_frame + 1 {
      if buffer_lookup_result.usage == .SG_USAGE_STREAM {
        for ii in 0 ..< len(ctx.stream_buffers) {
          if ctx.stream_buffers[ii].buffer.id == buffer.id {
            ordered_remove(&ctx.stream_buffers, ii)
            break
          }
        }
      }
      sokol.sg_destroy_buffer(buffer)
      ordered_remove(&ctx.doomed_buffers, i)
      i -= 1
      c -= 1
    }
  }

  // pipelines
  i = 0
  c = len(ctx.doomed_pipelines)
  for ; i < c; i += 1 {
    pipeline := ctx.doomed_pipelines[i]
    pipeline_lookup_result := sokol.sg_lookup_pipeline(pipeline.id)
    if frame > pipeline_lookup_result.used_frame + 1 {
      for ii in 0 ..< len(ctx.pipelines) {
        if ctx.pipelines[ii].id == pipeline.id {
          ordered_remove(&ctx.pipelines, ii)
          break
        }
      }
      sokol.sg_destroy_pipeline(pipeline)
      ordered_remove(&ctx.doomed_pipelines, i)
      i -= 1
      c -= 1
    }
  }

  // shaders
  i = 0
  c = len(ctx.doomed_shaders)
  for ; i < c; i += 1 {
    shader := ctx.doomed_shaders[i]
    shader_lookup_result := sokol.sg_lookup_shader(shader.id)
    if shader_lookup_result.found && frame > shader_lookup_result.used_frame + 1 {
      sokol.sg_destroy_shader(shader)
      ordered_remove(&ctx.doomed_shaders, i)
      i -= 1
      c -= 1
    } else {
      // TODO (FIXME): crash happened where shd became NULL when we reloaded the shaders
      ordered_remove(&ctx.doomed_shaders, i)
      i -= 1
      c -= 1
    }
  }

  // passes
  i = 0
  c = len(ctx.doomed_passes)
  for ; i < c; i += 1 {
    pass := ctx.doomed_passes[i]
    pass_lookup_result := sokol.sg_lookup_pass(pass.id)
    if frame > pass_lookup_result.used_frame + 1 {
      sokol.sg_destroy_pass(pass)
      ordered_remove(&ctx.doomed_passes, i)
      i -= 1
      c -= 1
    }
  }

  // images
  i = 0
  c = len(ctx.doomed_images)
  for ; i < c; i += 1 {
    image := ctx.doomed_images[i]
    image_lookup_result := sokol.sg_lookup_image(image.id)
    if frame > image_lookup_result.used_frame + 1 {
      sokol.sg_destroy_image(image)
      ordered_remove(&ctx.doomed_images, i)
      i -= 1
      c -= 1
    }
  }
}

queue_destruction :: proc(queue: ^$T/[dynamic]$E, doomed_object: E) {
  append(queue, doomed_object)
}

shutdown :: proc() {
  destroy_textures()

  collect_garbage(private.core_api.frame_index() + 100)

  destroy_buffers(ctx.cmd_buffers_feed)

  delete(ctx.cmd_buffers_feed)
  delete(ctx.cmd_buffers_render)
  delete(ctx.stages)
}

@(init, private)
init_gfx_api :: proc() {
  private.gfx_api = {
    imm = {
      begin = begin_imm_stage,
      end = end_imm_stage,
      update_buffer = sokol.sg_update_buffer,
      update_image = sokol.sg_update_image,
      begin_default_pass = sokol.sg_begin_default_pass,
      begin_pass = sokol.sg_begin_pass,
      apply_viewport = sokol.sg_apply_viewport,
      apply_scissor_rect = sokol.sg_apply_scissor_rect,
      apply_pipeline = sokol.sg_apply_pipeline,
      apply_bindings = sokol.sg_apply_bindings,
      apply_uniforms = proc "c" (stage: sokol.sg_shader_stage, ub_index: i32, data: rawptr, num_bytes: i32) { sokol.sg_apply_uniforms(stage, ub_index, &{ data, uint(num_bytes) }) },
      draw = sokol.sg_draw,
      end_pass = sokol.sg_end_pass,
      append_buffer = proc "c" (buffer: sokol.sg_buffer, data: rawptr, num_bytes: i32) -> i32 { return sokol.sg_append_buffer(buffer, &{ data, uint(num_bytes) }) },
    },
    staged = {
      begin = begin_cb_stage,
      end = end_cb_stage,
      begin_default_pass = begin_cb_default_pass,
      begin_pass = begin_cb_pass,
      apply_pipeline = apply_cb_pipeline,
      apply_bindings = apply_cb_bindings,
      apply_uniforms = apply_cb_uniforms,
      draw = cb_draw,
      end_pass = end_cb_pass,
      append_buffer = append_cb_buffer,
    },
    make_buffer = make_buffer,
    make_pass = sokol.sg_make_pass,
    make_pipeline = make_pipeline,
    make_image = sokol.sg_make_image,
    destroy_buffer = destroy_buffer,
    destroy_shader = destroy_shader,
    destroy_pipeline = destroy_pipeline,
    destroy_pass = destroy_pass,
    destroy_image = destroy_image,
    init_image = sokol.sg_init_image,
    make_shader_with_data = make_shader_with_data,
    register_stage = register_stage,
    bind_shader_to_pipeline = bind_shader_to_pipeline,
    alloc_image = sokol.sg_alloc_image,
    texture_white = texture_white,
    texture_black = texture_black,
  }
}

