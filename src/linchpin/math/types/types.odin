package math_types

import glm "core:math/linalg"

AABB :: struct #raw_union {
  using floats: struct {
    xmin, ymin, zmin: f32,
    xmax, ymax, zmax: f32,
  },

  using vectors: struct {
    vmin: glm.Vector3f32,
    vmax: glm.Vector3f32,
  },

  f: [6]f32,
}

Color :: struct #raw_union {
  using rgba: struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
  },

  n: u32,
}

RED := Color{ rgba = { 255, 0, 0, 255 }}
GREEN := Color{ rgba = { 0, 255, 0, 255 }}

aabbf :: proc(xmin, ymin, zmin, xmax, ymax, zmax: f32) -> AABB {
  return AABB {
    floats = { xmin = xmin, ymin = ymin, zmin = zmin, xmax = xmax, ymax = ymax, zmax= zmax },
  }
}

aabbv :: proc(vmin: glm.Vector3f32, vmax: glm.Vector3f32) -> AABB {
  return AABB {
    floats = { xmin = vmin.x, ymin = vmin.y, zmin = vmin.z, xmax = vmax.x, ymax = vmax.y, zmax = vmax.z }, 
  }
}

aabb_empty :: proc() -> AABB {
  return aabbf(max(f32), max(f32), max(f32), -max(f32), -max(f32), -max(f32))
}

add_point :: proc(aabb: ^AABB, pt: glm.Vector3f32) {
  aabb^ = aabbv(
    {min(aabb.vectors.vmin.x, pt.x), min(aabb.vectors.vmin.y, pt.y), min(aabb.vectors.vmin.z, pt.z)},
    {max(aabb.vectors.vmax.x, pt.x), max(aabb.vectors.vmax.y, pt.y), max(aabb.vectors.vmax.z, pt.z)},
  )
}

equal :: proc(a, b, epsilon: f32) -> bool {
  lhs := abs(a - b)
  aa := abs(a)
  ab := abs(b)
  rhs := epsilon * max(1.0, max(aa, ab))
  return lhs <= rhs
}