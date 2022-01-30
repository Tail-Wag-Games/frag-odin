package linchpin

align_mask :: proc(value: $T, mask: T) -> T {
  return ((value + mask) & (~T(0) & ~mask))
}

align_ptr :: proc(ptr: rawptr, extra: uintptr, align: int) -> rawptr {
  using un : struct #raw_union {
		ptr: rawptr,
    addr: uintptr,
	}
  un.ptr = ptr
  unaligned := un.addr + extra
  mask := uintptr(align - 1)
  aligned := align_mask(unaligned, mask)
  un.addr = aligned
  return un.ptr
}