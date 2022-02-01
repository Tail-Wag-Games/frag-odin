package platform

import "core:fmt"
import "core:sys/win32"
import "core:sys/windows"


DLL_EXT :: ".dll"

MIN_STACK_SIZE :: 32768 // 32kb

dlerr :: proc() -> string {
  when ODIN_OS == "windows" {
    return fmt.tprintf("%d", win32.get_last_error())
  }
}

num_cores :: proc() -> int {
  	info: windows.SYSTEM_INFO
	  windows.GetSystemInfo(&info)
	  return int(info.dwNumberOfProcessors)
}