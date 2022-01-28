package core

import "../../../vendor/sokol"

import ".."
import "../asset"
import "../gfx"
import "../job"

Core_Context :: struct {
  job_ctx: ^job.Job_Context,
}

ctx : Core_Context

init :: proc(conf: ^frag.Config) -> frag.Error {
  ctx.job_ctx = job.create_job_context(&job.Job_Context_Desc{}) or_return

  asset.init()

  gfx.init(&sokol.Gfx_Desc{
    ctx = sokol.sapp_sgcontext(),
  })
  return .None
}