package three_d_api

import math_types "linchpin:math/types"

import "frag:api"

import glm "core:math/linalg"

Debug_Vertex :: struct {
  pos: glm.Vector3f32,
  normal: glm.Vector3f32,
  uv: glm.Vector2f32,
  color: math_types.Color,
}

Debug :: struct {
  draw_grid_on_xzplane_using_cam : proc "c" (spacing: f32, spacing_bold: f32, dist: f32, cam: ^api.Camera, view_proj_mat: ^matrix[4, 4]f32),
}

Three_D_Api :: struct {
  debug: Debug,
}
