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

create_pool :: proc(item_size: int, capacity: int) -> (pool: ^Pool, err: mem.Allocator_Error) {
  assert(item_size > 0, "item size must be > 0")

  aligned_capacity := align_mask(capacity, 15)
  
  pool = new(Pool)
  pool.item_size = item_size
  pool.capacity = aligned_capacity
  pool.pages = new(Pool_Page)

  page := pool.pages
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