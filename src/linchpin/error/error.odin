package error

import "core:runtime"

OS_Error :: enum {
  Path_Not_Found,
  Directory,
}

Error :: union {
	runtime.Allocator_Error,
  OS_Error,
};

error_descriptions := map[Error]string{
  .Path_Not_Found = "The system cannot find the path specified.",
  .Directory = "The directory name is invalid.",
}