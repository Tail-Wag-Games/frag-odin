package linchpin

import "core:runtime"
import "core:intrinsics"

NATURAL_ALIGNMENT :: 8

align_mask :: proc(value: $T, mask: T) -> T {
  return ((value + mask) & (~T(0) & ~mask))
}

align_uintptr :: proc(ptr: uintptr, extra: uintptr, align: uintptr) -> uintptr {
  p := ptr
  unaligned := p + extra
  mask := align - 1
  aligned := align_mask(unaligned, mask)
  p = aligned
  return p
}

align_ptr :: proc(ptr: rawptr, extra: uintptr, align: int) -> rawptr {
  return rawptr(align_uintptr(uintptr(ptr), extra, uintptr(align)))
}