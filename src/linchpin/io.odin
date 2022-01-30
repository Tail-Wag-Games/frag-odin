package linchpin

import "core:mem"
import "core:runtime"

Mem_Block :: struct {
  data: rawptr,
  size: i64,
  start_offset: int,
  align: int,
  refcount: int,
}

create_mem_block :: proc(size: i64, data: rawptr, align: int) -> (res: ^Mem_Block, err: Error = nil) {
  desired_alignment := max(align, mem.DEFAULT_ALIGNMENT)
  res = mem.new_aligned(Mem_Block, desired_alignment) or_return

  res.data = align_ptr(mem.ptr_offset(res, 1), 0, align)
  res.size = size
  res.start_offset = 0
  res.align = align
  res.refcount = 1
  if data != nil {
    runtime.mem_copy(res.data, data, int(size))
  }
  return res, err
}