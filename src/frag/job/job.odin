package job

import ".."

Job_Context_Desc :: struct {

}

Job_Context :: struct {

}

create_job_context :: proc(desc: ^Job_Context_Desc) -> (res: ^Job_Context, err: frag.Error) {
  ctx := new(Job_Context)

  if ctx == nil {
    return {}, .Out_Of_Memory 
  }

  return ctx, .None
}

destroy_job_context :: proc(ctx: ^Job_Context) {
  free(ctx)
}