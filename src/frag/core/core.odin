package core

import "../../../vendor/sokol"

import "../../linchpin"

import ".."
import "../asset"
import "../gfx"

import "core:fmt"

Core_Context :: struct {
  job_ctx: ^linchpin.Job_Context,
}

ctx : Core_Context

init :: proc(conf: ^frag.Config) -> linchpin.Error {
  ctx.job_ctx = linchpin.create_job_context(&linchpin.Job_Context_Desc{
    num_threads = linchpin.num_cores() - 1,
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
  linchpin.destroy_job_context(ctx.job_ctx)
}