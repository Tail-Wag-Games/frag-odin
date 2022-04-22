package linchpin

make_four_cc :: proc(a, b, c, d: rune) -> u32 {
  return ((u32(a) | (u32(b) << 8) | (u32(c) << 16) | (u32(d) << 24)))
}