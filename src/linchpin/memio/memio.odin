package memio

import "thirdparty:lockless"

import linchpin "linchpin:alloc"
import "linchpin:error"

import "core:fmt"
import "core:mem"
import "core:runtime"

Mem_Block :: struct {
  data: rawptr,
  size: i64,
  start_offset: i64,
  align: int,
  refcount: u32,
}

create_block :: proc(size: i64, data: rawptr, align: int) -> (^Mem_Block, error.Error) {
  desired_alignment := max(align, linchpin.NATURAL_ALIGNMENT)
  raw := mem.alloc(int(size) + desired_alignment)

  res := new(Mem_Block)
  res.data = linchpin.align_ptr(raw, 0, desired_alignment)
  res.size = size
  res.start_offset = 0
  res.align = desired_alignment
  res.refcount = 1
  if data != nil {
    runtime.mem_copy(res.data, data, int(size))
  }
  return res, nil
}

destroy_block :: proc(mb: ^Mem_Block) {
  assert(mb != nil)
  assert(mb.refcount >= 1)

  if lockless.atomic_fetch_sub32_explicit(&mb.refcount, 1, .Acquire) == 1 {
    free(mb)
  }
}

add_offset :: proc(mb: ^Mem_Block, offset: i64) {
  mb.data = mem.ptr_offset(cast(^u8)mb.data, int(offset))
  mb.size -= offset
  mb.start_offset += offset
}