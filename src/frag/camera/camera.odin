package camera

import "linchpin:math/geom"

import "frag:api"
import "frag:private"

import "core:fmt"
import "core:math"
import glm "core:math/linalg"
import "core:mem"
import "core:runtime"

Camera_Context :: struct {
  alloc: mem.Allocator,
}

ctx : Camera_Context

calc_frustum_points_using_range :: proc "c" (cam: ^api.Camera, fnear: f32, ffar: f32) -> (res : [8]glm.Vector3f32) {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  fov := glm.radians(cam.fov)
  w := cam.viewport.xmax - cam.viewport.xmin
  h := cam.viewport.ymax - cam.viewport.ymin
  aspect := w / h

  xaxis := cam.right
  yaxis := cam.up
  zaxis := cam.forward
  pos := cam.pos

  near_plane_h := math.tan(fov * 0.5) * fnear
  near_plane_w := near_plane_h * aspect

  far_plane_h := math.tan(fov * 0.5) * ffar
  far_plane_w := far_plane_h * aspect

  center_near := (zaxis * fnear) + pos
  center_far := (zaxis * ffar) + pos

  xnear_scaled := xaxis * near_plane_w
  xfar_scaled := xaxis * far_plane_w
  ynear_scaled := yaxis * near_plane_h
  yfar_scaled := yaxis * far_plane_h

  res[0] = center_near - (xnear_scaled + ynear_scaled)
  res[1] = center_near + (xnear_scaled - ynear_scaled)
  res[2] = center_near + (xnear_scaled + ynear_scaled)
  res[3] = center_near - (xnear_scaled - ynear_scaled)

  res[4] = center_far - (xfar_scaled + yfar_scaled)
  res[5] = center_far - (xfar_scaled - yfar_scaled)
  res[6] = center_far + (xfar_scaled + yfar_scaled)
  res[7] = center_far + (xfar_scaled - yfar_scaled)

  return res
}

init_camera :: proc "c" (cam: ^api.Camera, fov_deg: f32, viewport: geom.Rectangle, fnear: f32, ffar: f32) {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  cam.pos = {0.0, 0.0, 0.0}
  cam.forward = {0.0, 0.0, -1.0}
  cam.right = glm.VECTOR3F32_X_AXIS
  cam.up = glm.VECTOR3F32_Z_AXIS  

  cam.quat = glm.QUATERNIONF32_IDENTITY
  cam.fov = fov_deg
  cam.fnear = fnear
  cam.ffar = ffar
  cam.viewport = viewport
}

location :: proc(cam: ^api.Camera, pos: glm.Vector3f32, rot: glm.Quaternionf32) {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  cam.pos = pos
  cam.quat = rot

  m := glm.matrix3_from_quaternion_f32(rot)
  cam.right = { m[0, 0], m[0, 1], m[0, 2] }
  cam.up = { m[1, 0], m[1, 1], m[1, 2] }
  cam.up = - cam.up
  cam.forward = { m[2, 0], m[2, 1], m[2, 2] }
}

look_at :: proc "c" (cam: ^api.Camera, pos: glm.Vector3f32, target: glm.Vector3f32, up: glm.Vector3f32) {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  cam.forward = glm.vector_normalize(target - pos)
  cam.right = glm.vector_normalize(glm.cross(cam.forward, up))
  cam.up = glm.cross(cam.right, cam.forward)
  cam.pos = pos

  cam.quat = glm.quaternion_from_forward_and_up_f32(cam.forward, cam.up)
}

perspective_mat :: proc "c" (cam: api.Camera) -> glm.Matrix4x4f32 {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  w := cam.viewport.xmax - cam.viewport.xmin
  h := cam.viewport.ymax - cam.viewport.ymin
  return glm.matrix4_perspective_f32(glm.radians(cam.fov), w / h, cam.fnear, cam.ffar)
}

view_mat :: proc "c" (cam: api.Camera) -> glm.Matrix4x4f32 {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  return glm.matrix4_look_at_from_fru_f32(cam.pos, cam.forward, cam.right, cam.up)
}

update_rotation :: proc "c" (cam: ^api.Camera) {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  m := glm.matrix4_from_quaternion_f32(cam.quat)

  cam.right = m[0].xyz
  cam.up = m[1].xyz
  cam.forward = -1.0 * m[2].xyz
}

init_fps_camera :: proc "c" (cam: ^api.Fps_Camera, fov_deg: f32, viewport: geom.Rectangle, fnear: f32, ffar: f32) {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  init_camera(&cam.cam, fov_deg, viewport, fnear, ffar)
  cam.yaw = 0
  cam.pitch = 0
}

fps_look_at :: proc "c" (fps: ^api.Fps_Camera, pos: glm.Vector3f32, target: glm.Vector3f32, up: glm.Vector3f32) {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  look_at(&fps.cam, pos, target, up)

  x, y, z := glm.euler_angles_from_quaternion_f32(fps.cam.quat, .XYZ)
  fps.pitch = x
  fps.yaw = z
}

fps_forward :: proc "c" (fps: ^api.Fps_Camera, forward: f32) {
  t : glm.Vector3f32
  fps.cam.pos += (fps.cam.forward * forward)
}

fps_strafe :: proc "c" (fps: ^api.Fps_Camera, strafe: f32) {
  t : glm.Vector3f32
  fps.cam.pos += (fps.cam.right * strafe)
}

fps_pitch :: proc "c" (fps: ^api.Fps_Camera, pitch: f32) {
  context = runtime.default_context()
  context.allocator = ctx.alloc
  
  fps.pitch -= pitch
  fps.cam.quat = glm.quaternion_angle_axis_f32(fps.yaw, {0, 0, 1}) * glm.quaternion_angle_axis_f32(fps.pitch, {1, 0, 0})
  update_rotation(&fps.cam)
}

fps_yaw :: proc "c" (fps: ^api.Fps_Camera, yaw: f32) {
  context = runtime.default_context()
  context.allocator = ctx.alloc
  
  fps.yaw -= yaw
  fps.cam.quat = glm.quaternion_angle_axis_f32(fps.yaw, {0, 0, 1}) * glm.quaternion_angle_axis_f32(fps.pitch, {1, 0, 0})
  update_rotation(&fps.cam)
}

init :: proc(allocator := context.allocator) {
  ctx.alloc = allocator
}

@(init, private)
init_camera_api :: proc() {
  private.camera_api = {
    init_camera = init_camera,
    look_at = look_at,
    perspective_mat = perspective_mat,
    view_mat = view_mat,
    calc_frustum_points_using_range = calc_frustum_points_using_range,
    init_fps_camera = init_fps_camera,
    fps_look_at = fps_look_at,
    fps_pitch = fps_pitch,
    fps_yaw = fps_yaw,
    fps_forward = fps_forward,
    fps_strafe = fps_strafe,
  }
}