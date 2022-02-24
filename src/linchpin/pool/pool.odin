package pool

import "linchpin:alloc"

import "core:fmt"
import "core:mem"

Pool_Page :: struct {
  ptrs: [^]rawptr,
  buff: [^]u8,
  next: ^Pool_Page,
  iter: int,
}

Pool :: struct {
  item_size: int,
  capacity: int,
  pages: ^Pool_Page,
}

fetch_From_pool :: proc(pool: ^Pool) -> rawptr {

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

create_page :: proc(pool: ^Pool) -> ^Pool_Page {
  cap := pool.capacity
  item_sz := pool.item_size

  res, _ := mem.new_aligned(Pool_Page, 16)

  return nil
}

create_pool :: proc(item_size: int, capacity: int) -> (^Pool, mem.Allocator_Error) {
  assert(item_size > 0, "item size must be > 0")

  aligned_capacity := alloc.align_mask(capacity, 15)

  buff_slice, _ := mem.make_aligned([]u8, size_of(Pool) + size_of(Pool_Page) + (item_size + size_of(rawptr)) * aligned_capacity, 16)
  buff := &buff_slice[0]

  pool := cast(^Pool)buff
  buff = mem.ptr_offset(buff,size_of(Pool))
  pool.item_size = item_size
  pool.capacity = aligned_capacity
  pool.pages = cast(^Pool_Page)buff
  buff = mem.ptr_offset(buff, size_of(Pool_Page))

  page := pool.pages
  page.iter = aligned_capacity
  page.ptrs = cast([^]rawptr)buff
  buff = mem.ptr_offset(buff, size_of(rawptr) * aligned_capacity)
  page.buff = buff
  page.next = nil
  for i in 0 ..< aligned_capacity {
    page.ptrs[aligned_capacity - i - 1] = mem.ptr_offset(&page.buff[0], i * item_size)
  }
  mem.zero(page.buff, capacity * item_size)

  return pool, nil
}

grow :: proc(pool: ^Pool) -> bool {
  page := create_page(pool)
  if page != nil {
    last := pool.pages
    for last.next != nil {
      last = last.next
    }
    last.next = page
    return true
  } else {
    return false
  }
}

is_full :: proc(pool: ^Pool) -> bool {
  page := pool.pages
  for page != nil {
    if page.iter > 0 {
      return false
    }
    page = page.next
  }
  return true
}

new_and_grow :: proc(pool: ^Pool) -> rawptr {
  if is_full(pool) {
    grow(pool)
  }
  return fetch_From_pool(pool)
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
    free(pool.pages)
    free(pool)
  }
}