package pool

import "linchpin:alloc"

import "core:fmt"
import "core:mem"

Pool_Page :: struct {
  ptrs: []rawptr,
  buff: []u8,
  next: ^Pool_Page,
  iter: int,
}

Pool :: struct {
  item_size: int,
  capacity: int,
  pages: ^Pool_Page,
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

create_pool :: proc(item_size: int, capacity: int) -> (res: ^Pool, err: mem.Allocator_Error = nil) {
  assert(item_size > 0, "item size must be > 0")

  aligned_capacity := alloc.align_mask(capacity, 15)
  
  res = mem.new_aligned(Pool, 16) or_return
  res.item_size = item_size
  res.capacity = aligned_capacity
  res.pages = mem.new_aligned(Pool_Page, 16) or_return

  page := res.pages
  page.iter = aligned_capacity
  page.ptrs = mem.make_aligned([]rawptr, aligned_capacity, 16) or_return
  page.buff = mem.make_aligned([]u8, item_size * aligned_capacity, 16) or_return
  page.next = nil
  for i in 0 ..< aligned_capacity {
    page.ptrs[aligned_capacity - i - 1] = &page.buff[i * item_size]
  }
  
  return res, nil
}

destroy_pool :: proc(pool: ^Pool) {
  if pool != nil {
    assert(pool.pages != nil)

    page := pool.pages.next
    for page != nil {
      next := page.next
      delete(page.ptrs)
      delete(page.buff)
      free(page)
      page = next
    }
    pool.capacity = 0
    pool.pages.iter = 0
    pool.pages.next = nil
    delete(pool.pages.ptrs)
    delete(pool.pages.buff)
    free(pool)
  }
}