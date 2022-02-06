package gfx

import "thirdparty:sokol"
import "thirdparty:lockless"

import "linchpin:alloc"
import "linchpin:memio"

import "frag:api"
import "frag:private"

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:runtime"
import "core:slice"

Gfx_Command :: enum {
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

Gfx_Command_Buffer_Ref :: struct {
  key: u32,
  cmd_buffer_idx: int,
  cmd: Gfx_Command,
  params_offset: int,
}

Gfx_Command_Buffer :: struct {
  params_buff: [dynamic]u8,
  refs: [dynamic]Gfx_Command_Buffer_Ref,
  running_stage: api.Gfx_Stage_Handle,
  index: int,
  stage_order: u16,
  cmd_idx: u16,
}

Gfx_Stage_State :: enum {
  None,
  Submitting,
  Done,
}

Gfx_Stage :: struct {
  name: [32]u8,
  name_hash: u32,
  state: Gfx_Stage_State,
  parent: api.Gfx_Stage_Handle,
  child: api.Gfx_Stage_Handle,
  next: api.Gfx_Stage_Handle,
  prev: api.Gfx_Stage_Handle,
  order: u16,
  enabled: bool,
  single_enabled: bool,
}

Gfx_Context :: struct {
  stages: [dynamic]Gfx_Stage,
  cmd_buffers_feed: []Gfx_Command_Buffer,
  cmd_buffers_render: []Gfx_Command_Buffer,
  stage_lock: lockless.Spinlock,

  cur_stage_name: [32]u8,
}

Run_Command_Callback :: proc(buff: []u8, offset: int) -> ([]u8, int)

STAGE_ORDER_DEPTH_BITS :: 6
STAGE_ORDER_DEPTH_MASK :: 0xfc00
STAGE_ORDER_ID_BITS :: 10
STAGE_ORDER_ID_MASK :: 0x03ff

ctx : Gfx_Context
gfx_alloc: mem.Allocator

run_command_cbs := [17]Run_Command_Callback {
  run_cb_begin_default_pass,
  run_cb_begin_default_pass,
  run_cb_begin_default_pass,
  run_cb_begin_default_pass,
  run_cb_begin_default_pass,
  run_cb_begin_default_pass,
  run_cb_begin_default_pass,
  run_cb_begin_default_pass,
  run_cb_begin_default_pass,
  run_cb_end_pass,
  run_cb_begin_default_pass,
  run_cb_begin_default_pass,
  run_cb_begin_default_pass,
  run_cb_begin_default_pass,
  run_cb_begin_default_pass,
  run_cb_begin_stage,
  run_cb_end_stage,
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

run_cb_begin_stage :: proc(buff: []u8, offset: int) -> ([]u8, int) {
  cur_offset := offset

  name := cast(cstring)&buff[cur_offset]
  cur_offset += 32

  mem.copy(&ctx.cur_stage_name[0], transmute(rawptr)name, size_of(ctx.cur_stage_name))
  
  return buff, cur_offset
}

run_cb_end_stage :: proc(buff: []u8, offset: int) -> ([]u8, int) {
  ctx.cur_stage_name[0] = u8(0)

  return buff, offset
}

execute_command_buffer :: proc(cmds: []Gfx_Command_Buffer) -> int {
  assert(private.core_api.job_thread_index() == 0, "`execute_command_buffer` should only be invoked from main thread")

  cmd_count := 0
  cmd_buffer_count := private.core_api.num_job_threads()

  for i in 0 ..< cmd_buffer_count {
    cb := &cmds[i]
    assert(cb.running_stage.id == 0, "`end_stage` must be called for all command buffers which draw calls have been submitted for")
    cmd_count += len(cb.refs)
  }

  if cmd_count > 0 {
    refs := make([]Gfx_Command_Buffer_Ref, cmd_count, context.temp_allocator)

    cur_ref_count := 0
    init_refs := refs
    for i in 0 ..< cmd_buffer_count {
      cb := &cmds[i]
      ref_count := len(cb.refs)
      if ref_count > 0 {
        mem.copy(&refs[cur_ref_count], mem.raw_dynamic_array_data(cb.refs), size_of(Gfx_Command_Buffer_Ref) * ref_count)
        cur_ref_count += ref_count
        runtime.clear_dynamic_array(&cb.refs)
      }
    }
    refs = init_refs

    slice.sort_by(refs, proc(x, y: Gfx_Command_Buffer_Ref) -> bool {
      return x.key < y.key
    })

    for i in 0 ..< cmd_count {
      ref := &refs[i]
      cb := &cmds[ref.cmd_buffer_idx]
      run_command_cbs[ref.cmd](cb.params_buff[:], ref.params_offset)
    }
  }

  return cmd_count
}

execute_command_buffers :: proc () {

  execute_command_buffer(ctx.cmd_buffers_render)
  execute_command_buffer(ctx.cmd_buffers_feed)
  
  for i in 0 ..< len(ctx.stages) {
    ctx.stages[i].state = .None
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

make_cb_params_buff :: proc(cb: ^Gfx_Command_Buffer, size: int, offset: ^int) -> ^u8 {
  if size == 0 {
    return nil
  }
  
  current_len := len(cb.params_buff)
  resize(&cb.params_buff, current_len + alloc.align_mask(size, mem.DEFAULT_ALIGNMENT - 1))
  offset^ = int(mem.ptr_sub(&cb.params_buff[current_len], &cb.params_buff[0]))

  return &cb.params_buff[current_len]
}

end_cb_pass :: proc "c" () {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  cb := &ctx.cmd_buffers_feed[private.core_api.job_thread_index()]

  assert(cb.running_stage.id != 0, "draw related calls must be issued between `begin_stage` and `end_stage`")
  assert(cb.cmd_idx < max(u16), "max number of graphics calls exceeded")

  ref := Gfx_Command_Buffer_Ref {
    key = (u32(cb.stage_order << 16) | u32(cb.cmd_idx)),
    cmd_buffer_idx = cb.index,
    cmd = .End_Pass,
    params_offset = len(cb.params_buff),
  }
  append(&cb.refs, ref)

  cb.cmd_idx += 1
}

begin_cb_default_pass :: proc "c" (pass_action: ^sokol.sg_pass_action, width: i32, height: i32) {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  cb := &ctx.cmd_buffers_feed[private.core_api.job_thread_index()]

  assert(cb.running_stage.id != 0, "draw related calls must be issued between `begin_stage` and `end_stage`")
  assert(cb.cmd_idx < max(u16), "max number of graphics calls exceeded")

  offset := 0
  buff := make_cb_params_buff(cb, size_of(sokol.sg_pass_action) + size_of(i32) * 2, &offset)

  ref := Gfx_Command_Buffer_Ref {
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

record_cb_begin_stage :: proc(name: cstring, name_size: int) {
  assert(name_size == 32)

  cb := &ctx.cmd_buffers_feed[private.core_api.job_thread_index()]

  assert(cb.running_stage.id != 0, "draw related calls must be issued between `begin_stage` and `end_stage`")
  assert(cb.cmd_idx < max(u16), "max number of graphics calls exceeded")

  offset := 0
  buff := make_cb_params_buff(cb, name_size, &offset)

  ref := Gfx_Command_Buffer_Ref {
    key = ((u32(cb.stage_order) << 16) | u32(cb.cmd_idx)),
    cmd_buffer_idx = cb.index,
    cmd = .Stage_Push,
    params_offset = offset,
  }
  append(&cb.refs, ref)

  cb.cmd_idx += 1

  mem.copy(buff, transmute(rawptr)name, name_size)
}

record_cb_end_stage :: proc() {
  cb := &ctx.cmd_buffers_feed[private.core_api.job_thread_index()]

  assert(cb.running_stage.id != 0, "draw related calls must be issued between `begin_stage` and `end_stage`")
  assert(cb.cmd_idx < max(u16), "max number of graphics calls exceeded")

  ref := Gfx_Command_Buffer_Ref {
    key = ((u32(cb.stage_order) << 16) | u32(cb.cmd_idx)),
    cmd_buffer_idx = cb.index,
    cmd = .Stage_Pop,
    params_offset = len(cb.params_buff),
  }
  append(&cb.refs, ref)

  cb.cmd_idx += 1
}

begin_cb_stage :: proc "c" (stage_handle: api.Gfx_Stage_Handle) -> bool {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  cb := &ctx.cmd_buffers_feed[private.core_api.job_thread_index()]

  stage : ^Gfx_Stage
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

add_child_stage :: proc(parent, child: api.Gfx_Stage_Handle) {
  p := &ctx.stages[api.to_index(parent.id)]
  c := &ctx.stages[api.to_index(child.id)]
  if p.child.id > 0 {
    first_child := &ctx.stages[api.to_index(p.child.id)]
    first_child.prev = child
    c.next = p.child
  }

  p.child = child
}

register_stage :: proc "c" (name: string, parent_stage: api.Gfx_Stage_Handle) -> api.Gfx_Stage_Handle {
  context = runtime.default_context()
  context.allocator = gfx_alloc

  stage := Gfx_Stage {
    name_hash = hash.fnv32a(transmute([]u8)name),
    parent = parent_stage,
    enabled = true,
    single_enabled = true,
  }
  mem.copy(&stage.name[0], mem.raw_string_data(name), size_of(stage.name))

  handle := api.Gfx_Stage_Handle {
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

make_shader_with_data :: proc "c" (vs_data_size: u32, vs_data: [^]u32, vs_refl_size: u32, vs_refl_json: [^]u32, fs_data_size: u32, fs_data: [^]u32, fs_ref_size: u32, fs_ref_json: [^]u32) -> api.Shader {
  return api.Shader {}
}


on_prepare_shader :: proc (params: ^api.Asset_Load_Params, mem: ^memio.Mem_Block) {

}


on_load_shader :: proc (data: ^api.Asset_Load_Data, params: ^api.Asset_Load_Params, mem: ^memio.Mem_Block) {

}


on_finalize_shader :: proc (data: ^api.Asset_Load_Data, params: ^api.Asset_Load_Params, mem: ^memio.Mem_Block) {

}


on_reload_shader :: proc (handle: api.Asset_Handle, prev_obj: api.Asset_Obj) {

}


on_release_shader :: proc (obj: api.Asset_Obj) {

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

create_command_buffers :: proc() -> []Gfx_Command_Buffer {
  num_threads := private.core_api.num_job_threads()
  cbs := make([]Gfx_Command_Buffer, num_threads)

  for i in 0 ..< num_threads {
    cbs[i].index = i
  }

  return cbs
}

init :: proc(desc: ^sokol.sg_desc, allocator := context.allocator) {
  gfx_alloc = allocator

  sokol.sg_setup(desc)

  ctx.cmd_buffers_feed = create_command_buffers()
  ctx.cmd_buffers_render = create_command_buffers()

  init_shaders()
}

destroy_buffers :: proc(cbs: []Gfx_Command_Buffer) {
  for i in 0 ..< private.core_api.num_job_threads() {
    cb := &cbs[i]
    assert(cb.running_stage.id == 0)
    delete(cb.params_buff)
    delete(cb.refs)
  }
}

shutdown :: proc() {
  destroy_buffers(ctx.cmd_buffers_feed)

  delete(ctx.cmd_buffers_feed)
  delete(ctx.cmd_buffers_render)
  delete(ctx.stages)
}


@(init, private)
init_gfx_api :: proc() {
  private.gfx_api = {
    staged = {
      begin = begin_cb_stage,
      end = end_cb_stage,
      begin_default_pass = begin_cb_default_pass,
      end_pass = end_cb_pass,
    },
    register_stage = register_stage,
    make_shader_with_data = make_shader_with_data,
  }
}

