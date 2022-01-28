package linchpin

import "core:c"
import win32 "core:sys/windows"

TLS :: rawptr

tls_create :: proc() -> TLS {
  tls_id := win32.TlsAlloc()
  assert(tls_id != win32.TLS_OUT_OF_INDEXES, "failed to create thread local storage!")
  return TLS(uintptr(tls_id))
}