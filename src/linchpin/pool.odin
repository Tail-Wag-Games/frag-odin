package linchpin

import "core:fmt"
import "core:mem"

import "core:c"

Pool_Page :: struct #align 16 {
  ptrs: []rawptr,
  buff: []u8,
  next: ^Pool_Page,
  iter: int,
}

Pool :: struct #align 16 {
  item_size: int,
  capacity: int,
  pages: ^Pool_Page,
}

align_mask :: proc(value: int, mask: int) -> int {
  return ((value + mask) & (~int(0) & ~mask))
}

delete_from_pool :: proc(pool: ^Pool, ptr: rawptr) {
  uptr := uintptr(ptr)
  page := pool.pages
  
  for page != nil {
    if uptr >= uintptr(page.buff[0]) &&
       uptr < uintptr(page.buff[pool.capacity * pool.item_size]) {
        assert(uintptr(mem.ptr_sub(cast(^u8)ptr, &page.buff[0])) % uintptr(pool.item_size) == 0, "pointer is not aligned to pool's items - probably invalid")
        assert(page.iter != pool.capacity, "cannot delete any more objectgs, possible double delete")

        page.ptrs[page.iter] = ptr
        page.iter += 1
        return
    }

    page = page.next
  }
  assert(false, "pointer does not belong to pool")
}

create_pool :: proc(item_size: int, capacity: int) -> (res: ^Pool, err: mem.Allocator_Error = .None) {
  assert(item_size > 0, "item size must be > 0")

  aligned_capacity := align_mask(capacity, 15)
  
  res = new(Pool)
  res.item_size = item_size
  res.capacity = aligned_capacity
  res.pages = new(Pool_Page)

  page := res.pages
  page.iter = aligned_capacity
  page.ptrs = mem.make_aligned([]rawptr, aligned_capacity, 16) or_return
  page.buff = mem.make_aligned([]u8, item_size * aligned_capacity, 16) or_return
  page.next = nil
  for i in 0 ..< aligned_capacity {
    page.ptrs[aligned_capacity - i - 1] = &page.buff[i * item_size]
  }
  
  return
}

destroy_pool :: proc(pool: ^Pool) {
  if pool != nil {
    assert(pool.pages != nil)

    page := pool.pages.next
    for page != nil {
      next := page.next
      free(page)
      page = next
    }
    pool.capacity = 0
    pool.pages.iter = 0
    pool.pages.next = nil
    free(pool)
  }
}