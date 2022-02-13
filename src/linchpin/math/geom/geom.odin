package geom

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