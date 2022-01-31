package core

import "thirdparty:sokol"

import "frag:asset"
import "frag:config"
import "frag:gfx"
import "frag:plugin"
import "frag:vfs"

import "linchpin:error"
import "linchpin:job"
import "linchpin:platform"

import "core:fmt"

Core_Context :: struct {
  job_ctx: ^job.Job_Context,
}


ctx : Core_Context


init :: proc(conf: ^config.Config) -> error.Error {
  plugin.init(conf.plugin_path) or_return

  vfs.init() or_return

  ctx.job_ctx = job.create_job_context(&job.Job_Context_Desc{
    num_threads = platform.num_cores() - 1,
    max_fibers = 64,
    fiber_stack_size = 1024 * 1024,
  }) or_return

  asset.init()

  gfx.init(&sokol.Gfx_Desc{
    ctx = sokol.sapp_sgcontext(),
  })
  
  return nil
}


shutdown :: proc() {
  job.destroy_job_context(ctx.job_ctx)
}