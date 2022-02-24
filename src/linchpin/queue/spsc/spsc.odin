package spsc

import "thirdparty:lockless"

import "linchpin:alloc"
import "linchpin:error"

import "core:mem"
import "core:runtime"

Node :: struct {
  next: ^Node,
}

Bin :: struct {
  ptrs: []^Node,
  buff: []u8,
  next: ^Bin,
  iter: int,
  _reserved: int,
}

Queue :: struct {
  ptrs: []^Node,
  buff: []u8,
  iter: int,
  capacity: int,
  stride: int,

  first: ^Node,
  last: lockless.Atomic_Ptr,
  divider: lockless.Atomic_Ptr,

  grow_bins: ^Bin,
}

create_bin :: proc(item_size: int, capacity: int) -> ^Bin {
  assert(capacity % 16 == 0)

  res := new(Bin)
  res.ptrs = make([]^Node, capacity)
  res.buff = make([]u8, (item_size + size_of(Node)) * capacity)
  res.next = nil

  res.iter = capacity

  for i in 0 ..< capacity {
    res.ptrs[capacity - i - 1] =
      cast(^Node)&res.buff[(size_of(Node) + item_size) * i]
  }

  return res
}

create :: proc(item_size: int, capacity: int) -> (^Queue, error.Error) {
  assert(item_size > 0)

  aligned_capacity := alloc.align_mask(capacity, 15)

  res := new(Queue)
  res.ptrs = make([]^Node, aligned_capacity)
  res.buff = make([]u8, (item_size + size_of(Node)) * aligned_capacity)

  res.iter = aligned_capacity
  res.capacity = aligned_capacity
  res.stride = item_size

  for i in 0 ..< aligned_capacity {
    res.ptrs[aligned_capacity - i - 1] =
      cast(^Node)&res.buff[(size_of(Node) + item_size) * i]
  }

  res.iter -= 1
  node := res.ptrs[res.iter]
  node.next = nil
  res.first = node
  res.last = lockless.Atomic_Ptr(uintptr(node))
  res.divider = res.last
  res.grow_bins = nil
  
  return res, nil
}

consume :: proc(queue: ^Queue, data: rawptr) -> bool {
  if queue.divider != lockless.atomic_loadptr_explicit(&queue.last, lockless.Atomic_Memory_Order.Acquire) {
    divider := cast(^Node)uintptr(queue.divider)
    assert(divider.next != nil)
    runtime.mem_copy(data, mem.ptr_offset(divider.next, 1), queue.stride)

    lockless.atomic_storeptr_explicit(&queue.divider, u64(uintptr(divider.next)), lockless.Atomic_Memory_Order.Release)
    return true
  }

  return false
}

produce :: proc(queue: ^Queue, data: rawptr) -> bool {
  node : ^Node
  node_bin : ^Bin
  if queue.iter > 0 {
    queue.iter -= 1
    node = queue.ptrs[queue.iter]
  } else {
    bin := queue.grow_bins
    for bin != nil && node == nil {
      if bin.iter == 0 {
        bin.iter -= 1
        node = bin.ptrs[bin.iter]
        node_bin = bin
      }
      bin = bin.next
    }
  }

  if node != nil {
    mem.copy(mem.ptr_offset(node, 1), data, queue.stride)
    node.next = nil

    last := cast(^Node)uintptr(lockless.atomic_exchange64(&queue.last, u64(uintptr(node))))
    last.next = node

    for lockless.Atomic_Ptr(uintptr(queue.first)) != lockless.atomic_load64_explicit(&queue.divider, .Acquire) {
      first := cast(^Node)queue.first
      queue.first = first.next

      first_ptr := uintptr(first)
      if first_ptr >= uintptr(&queue.buff[0]) && first_ptr < uintptr(&queue.buff[len(queue.buff) - 1]) {
        assert(queue.iter != queue.capacity)
        queue.ptrs[queue.iter] = first
        queue.iter += 1
      } else {
        bin := queue.grow_bins
        for bin != nil {
          if first_ptr >= uintptr(&bin.buff[0]) && first_ptr < uintptr(&bin.buff[len(bin.buff) - 1]) {
            assert(bin.iter != queue.capacity)
            bin.ptrs[bin.iter] = first
            bin.iter += 1
            break
          }
          bin = bin.next
        }
        assert(bin != nil, "item does not not belong to queue buffers")
      }
    }
    return true
  } else {
    return false
  }
}

grow :: proc(queue: ^Queue) -> bool {
  bin := create_bin(queue.stride, queue.capacity)
  if bin != nil {
    if queue.grow_bins != nil {
      last := queue.grow_bins
      for last.next != nil {
        last = last.next
      }
      last.next = bin
    } else {
      queue.grow_bins = bin
    }
    return true
  } else {
    return false
  }
}

full :: proc(queue: ^Queue) -> bool {
  if queue.iter == 0 {
    return false
  } else {
    bin := queue.grow_bins
    for bin != nil {
      if bin.iter > 0 {
        return false
      }
      bin = bin.next
    }
  }
  return true
}

produce_and_grow :: proc(queue: ^Queue, data: rawptr) -> bool {
  if full(queue) {
    grow(queue)
  }
  return produce(queue, data)
}

destroy_bin :: proc(bin: ^Bin) {
  assert(bin != nil)
  free(bin)
}

destroy :: proc(queue: ^Queue) {
  if queue != nil {
    if queue.grow_bins != nil {
      bin := queue.grow_bins
      for bin != nil {
        next := bin.next
        destroy_bin(bin)
        bin = next
      }
    }

    queue.iter = 0
    queue.capacity = queue.iter
    delete(queue.ptrs)
    delete(queue.buff)
    free(queue)
  }
}