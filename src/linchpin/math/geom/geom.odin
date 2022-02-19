package geom

import glm "core:math/linalg"

Rectangle :: struct #raw_union {
  using f32s : struct {
    xmin, ymin: f32,
    xmax, ymax: f32,
  },
  using vf32s : struct {
    vmin: [2]f32,
    vmax: [2]f32,
  },
  n: [4]f32,
}

plane_normal :: proc(va, vb, vc: glm.Vector3f32) -> glm.Vector3f32 {
  ba := vb - va
  ca := vc - va
  baca := glm.vector_cross3(ca, ba)

  return glm.vector_normalize(baca)
}