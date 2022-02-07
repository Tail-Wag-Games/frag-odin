package core

import "thirdparty:sokol"

import "frag:api"
import "frag:asset"
import "frag:gfx"
import "frag:plugin"
import "frag:private"
import "frag:vfs"

import imgui "imgui:types"

import "linchpin:error"
import "linchpin:job"
import "linchpin:platform"

import "core:dynlib"
import "core:fmt"
import "core:mem"
import "core:runtime"

Core_Context :: struct {
  alloc: mem.Allocator,
  job_ctx: ^job.Job_Context,

  num_threads: int,

  frame_idx: i64,
  elapsed_tick: u64,
  delta_tick: u64,
  last_tick: u64,
  fps_mean: f32,
  fps_frame: f32,

  paused: bool,
}

ctx : Core_Context

alloc :: proc "c" () -> mem.Allocator {
  return ctx.alloc
}

delta_tick :: proc "c" () -> u64 {
  return ctx.delta_tick
}

fps :: proc "c" () -> f32 {
  return ctx.fps_frame
}

job_thread_index :: proc "c" () -> int {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  return job.thread_index(ctx.job_ctx)
}

num_job_threads :: proc "c" () -> int {
  return ctx.num_threads
}

frame :: proc() {
  if ctx.paused {
    return
  }

  ctx.delta_tick = sokol.stm_laptime(&ctx.last_tick)
  ctx.elapsed_tick += ctx.delta_tick

  delta_tick := ctx.delta_tick
  dt := f32(sokol.stm_sec(delta_tick))

  if delta_tick > 0 {
    afps : f64 = f64(ctx.fps_mean)
    fps : f64 = f64(1.0 / dt)

    afps += (fps - afps) / f64(ctx.frame_idx)
    ctx.fps_mean = f32(afps)
    ctx.fps_frame = f32(fps)
  }

  plugin.update(dt)

  gfx.execute_command_buffers()

  imgui_api := cast(^imgui.Imgui_Api)private.plugin_api.get_api_by_name("imgui")
  if imgui_api != nil {
    imgui_api.Render()
  }

  sokol.sg_commit()

  ctx.frame_idx += 1
}

init :: proc(conf: ^api.Config, app_module: dynlib.Library, allocator := context.allocator) -> error.Error {
  ctx.alloc = allocator

  num_worker_threads := conf.num_job_threads >= 0 ? conf.num_job_threads : platform.num_cores() - 1
  num_worker_threads = max(1, num_worker_threads)
  ctx.num_threads = num_worker_threads + 1

  vfs.init() or_return

  ctx.job_ctx = job.create_job_context(&job.Job_Context_Desc{
    num_threads = platform.num_cores() - 1,
    max_fibers = 64,
    fiber_stack_size = 1024 * 1024,
  }) or_return

  asset.init()

  gfx.init(&sokol.sg_desc{
    desc = sokol.sapp_sgcontext(),
  })

  plugin.init(conf.plugin_path, app_module) or_return
  
  return nil
}

shutdown :: proc() {
  plugin.shutdown()

  job.destroy_job_context(ctx.job_ctx)

  asset.shutdown()
  gfx.shutdown()
  vfs.shutdown()
}

@(init, private)
init_core_api :: proc() {
  private.core_api = {
    alloc = alloc,
    delta_tick = delta_tick,
    fps = fps,
    job_thread_index = job_thread_index,
    num_job_threads = num_job_threads,
  }
}
