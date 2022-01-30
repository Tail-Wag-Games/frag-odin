package linchpin

import "core:runtime"

OS_Error :: enum {
  Path_Not_Found,
}

Error :: union {
	runtime.Allocator_Error,
  OS_Error,
};