package camera

import "thirdparty:cglm"

import "linchpin:math/geom"

import "frag:api"
import "frag:private"

import glm "core:math/linalg"
import "core:mem"
import "core:runtime"

Camera_Context :: struct {
  alloc: mem.Allocator,
}

ctx : Camera_Context

init_camera :: proc "c" (cam: ^api.Camera, fov_deg: f32, viewport: geom.Rectangle, fnear: f32, ffar: f32) {
  cam.right = glm.VECTOR3F32_X_AXIS
  cam.up = glm.VECTOR3F32_Z_AXIS
  cam.forward = glm.VECTOR3F32_Y_AXIS
  cam.pos = glm.Vector3f32{0, 0, 0}

  cam.quat = glm.QUATERNIONF32_IDENTITY
  cam.fov = fov_deg
  cam.fnear = fnear
  cam.ffar = ffar
  cam.viewport = viewport
}

location :: proc(cam: ^api.Camera, pos: glm.Vector3f32, rot: ^glm.Quaternionf32) {
  cam.pos = pos
  cam.quat = rot^
  
  m : glm.Matrix3f32
  cglm.quat_mat3(transmute([^]f32)rot, &m[0, 0])
  cam.right = { m[0][0], m[0][1], m[0][2] }
  cam.up = { m[1][0], m[1][1], m[1][2] }
  cglm.vec3_negate(&cam.up[0])
  cam.forward = { m[2][0], m[2][1], m[2][2] }
}

look_at :: proc "c" (cam: ^api.Camera, pos: ^glm.Vector3f32, target: ^glm.Vector3f32, up: ^glm.Vector3f32) {
  cglm.vec3_sub(&target[0], &pos[0], &cam.forward[0])
  cglm.vec3_normalize(&cam.forward[0])
  cglm.vec3_cross(&cam.forward[0], &up[0], &cam.right[0])
  cglm.vec3_normalize(&cam.right[0])
  cglm.vec3_cross(&cam.right[0], &cam.forward[0], &cam.up[0])
  cam.pos = pos^
}

init_fps_camera :: proc "c" (cam: ^api.Fps_Camera, fov_deg: f32, viewport: geom.Rectangle, fnear: f32, ffar: f32) {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  init_camera(&cam.cam, fov_deg, viewport, fnear, ffar)
  cam.yaw = 0
  cam.pitch = 0
}

fps_look_at :: proc "c" (fps: ^api.Fps_Camera, pos: ^glm.Vector3f32, target: ^glm.Vector3f32, up: ^glm.Vector3f32) {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  look_at(&fps.cam, pos, target, up)

  affine_transform : glm.Matrix4f32
  euler : glm.Vector3f32
  cglm.quat_mat4(transmute([^]f32)&fps.cam.quat, &affine_transform[0, 0])
  cglm.euler_angles(&affine_transform[0, 0], &euler[0])
  fps.pitch = euler.x
  fps.yaw = euler.z
}

fps_forward :: proc "c" (fps: ^api.Fps_Camera, forward: f32) {
  t : glm.Vector3f32
  cglm.vec3_scale(&fps.cam.forward[0], forward, &t[0])
  cglm.vec3_add(&fps.cam.pos[0], &t[0], &fps.cam.pos[0])
}

fps_strafe :: proc "c" (fps: ^api.Fps_Camera, strafe: f32) {
  t : glm.Vector3f32
  cglm.vec3_scale(&fps.cam.right[0], strafe, &t[0])
  cglm.vec3_add(&fps.cam.pos[0], &t[0], &fps.cam.pos[0])
}

init :: proc(allocator := context.allocator) {
  ctx.alloc = allocator
}

@(init, private)
init_camera_api :: proc() {
  private.camera_api = {
    init_camera = init_camera,
    look_at = look_at,
    init_fps_camera = init_fps_camera,
    fps_look_at = fps_look_at,
  }
}