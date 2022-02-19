package debug

import "thirdparty:sokol"

import "linchpin:math/geom"
import math_types "linchpin:math/types"

import "frag:api"

import "shaders"
import three_d_api "../api"

import "core:fmt"
import "core:math"
import glm "core:math/linalg"
import "core:mem"
import "core:runtime"

MAX_DYN_VERTICES :: 10000

Debug_Context :: struct {
  alloc: mem.Allocator,
  draw_api: ^api.Draw_Api,
  shader_wire: sokol.sg_shader,
  pip_wire: sokol.sg_pipeline,
  dyn_vbuff: sokol.sg_buffer,
  num_verts: i32,
}

@(link_section=".state")
gfx_api : ^api.Gfx_Api

@(link_section=".state")
camera_api : ^api.Camera_Api

@(link_section=".state")
ctx : Debug_Context

wire_vertex_layout : api.Vertex_Layout

draw_grid_on_xzplane :: proc(desired_spacing: f32, spacing_bold: f32, vp: ^matrix[4, 4]f32, frustum: [8]glm.Vector3f32) {
  color := math_types.Color { rgba = { 170, 170, 170, 255 } }
  bold_color := math_types.Color { rgba = { 255, 255, 255, 255 } }

  draw_api := ctx.draw_api

  spacing := math.ceil(max(desired_spacing, 0.0001))
  bb := math_types.aabb_empty()

  near_plane_norm := geom.plane_normal(frustum[0], frustum[1], frustum[2])
  for i in 0 ..< 8 {
    if i < 4 {
      offset_pt := frustum[i] - (near_plane_norm * spacing)
      math_types.add_point(&bb, {offset_pt.x, offset_pt.y, 0})
    } else {
      math_types.add_point(&bb, {frustum[i].x, frustum[i].y, 0})
    }
  }

  nspace := i32(spacing)
  snapbox := math_types.aabbf(
    f32(i32(bb.floats.xmin) - i32(bb.floats.xmin) % nspace), f32(i32(bb.floats.ymin) - i32(bb.floats.ymin) % nspace), 0,
    f32(i32(bb.floats.xmax) - i32(bb.floats.xmax) % nspace), f32(i32(bb.floats.ymax) - i32(bb.floats.ymax) % nspace), 0,
  )
  w := snapbox.floats.xmax - snapbox.floats.xmin
  d := snapbox.floats.ymax - snapbox.floats.ymin
  if math_types.equal(w, 0.0, 0.00001) || math_types.equal(d, 0.0, 0.00001) {
    return
  }

  xlines := i32(w) / nspace + 1
  ylines := i32(d) / nspace + 1
  num_verts := (xlines + ylines) * 2

  verts := make([]three_d_api.Debug_Vertex, num_verts)
  defer delete(verts)

  i := 0
  for yoffset := snapbox.floats.ymin; yoffset <= snapbox.floats.ymax; yoffset += spacing {
    verts[i].pos.x = snapbox.floats.xmin
    verts[i].pos.y = yoffset
    verts[i].pos.z = 0

    ni := i + 1
    verts[ni].pos.x = snapbox.floats.xmax
    verts[ni].pos.y = yoffset
    verts[ni].pos.z = 0


    verts[ni].color = yoffset != 0.0 ? (!math_types.equal(math.mod(yoffset, spacing_bold), 0.0, 0.0001) ? color : bold_color) : math_types.RED
    verts[i].color = verts[ni].color
    i += 2
  }

  for xoffset := snapbox.floats.xmin; xoffset <= snapbox.floats.xmax; xoffset += spacing {
    verts[i].pos.x = xoffset
    verts[i].pos.y = snapbox.floats.ymin
    verts[i].pos.z = 0

    ni := i + 1
    verts[ni].pos.x = xoffset
    verts[ni].pos.y = snapbox.floats.ymax
    verts[ni].pos.z = 0


    verts[ni].color = xoffset != 0.0 ? (!math_types.equal(math.mod(xoffset, spacing_bold), 0.0, 0.0001) ? color : bold_color) : math_types.GREEN
    verts[i].color = verts[ni].color
    i += 2
  }
  
  offset := draw_api.append_buffer(ctx.dyn_vbuff, raw_data(verts), i32(size_of(three_d_api.Debug_Vertex) * num_verts))
  ctx.num_verts += num_verts
  
  bind : sokol.sg_bindings
  bind.vertex_buffers[0] = ctx.dyn_vbuff
  bind.vertex_buffer_offsets[0] = offset

  draw_api.apply_pipeline(ctx.pip_wire)
  draw_api.apply_uniforms(.SG_SHADERSTAGE_VS, 0, &vp[0, 0], size_of(f32) * 16)
  draw_api.apply_bindings(&bind)
  draw_api.draw(0, num_verts, 1)
}

draw_grid_on_xzplane_using_cam :: proc "c" (spacing: f32, spacing_bold: f32, dist: f32, cam: ^api.Camera, view_proj_mat: ^matrix[4, 4]f32) {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  frustum := camera_api.calc_frustum_points_using_range(cam, -dist, dist)
  draw_grid_on_xzplane(spacing, spacing_bold, view_proj_mat, frustum)
}

init :: proc(gfx: ^api.Gfx_Api, cam: ^api.Camera_Api, allocator := context.allocator) {
  ctx.alloc = allocator

  gfx_api = gfx
  camera_api = cam
  ctx.draw_api = &gfx_api.staged

  wire_vertex_layout.attributes[0] = {semantic = "POSITION", offset = int(offset_of(three_d_api.Debug_Vertex, pos))}
  wire_vertex_layout.attributes[1] = {semantic = "COLOR", offset = int(offset_of(three_d_api.Debug_Vertex, color)), format = .SG_VERTEXFORMAT_UBYTE4N}

  shader_wire := gfx_api.make_shader_with_data(
    shaders.wire_vs_size, &shaders.wire_vs_data[0], shaders.wire_vs_refl_size, &shaders.wire_vs_refl_data[0],
    shaders.wire_fs_size, &shaders.wire_fs_data[0], shaders.wire_fs_refl_size, &shaders.wire_fs_refl_data[0],
  )

  pip_desc_wire := sokol.sg_pipeline_desc {
    shader = shader_wire.shd,
    index_type = .SG_INDEXTYPE_NONE,
    primitive_type = .SG_PRIMITIVETYPE_LINES,
    depth = {
      compare = .SG_COMPAREFUNC_LESS_EQUAL,
      write_enabled = true,
    },
    sample_count = 4,
    label = "debug3d_wire",
  }
  pip_desc_wire.colors[0].pixel_format = .SG_PIXELFORMAT_RGBA8
  pip_desc_wire.depth.pixel_format = .SG_PIXELFORMAT_DEPTH
  pip_desc_wire.layout.buffers[0].stride = size_of(three_d_api.Debug_Vertex)
  
  pip_wire := gfx_api.make_pipeline(
    gfx_api.bind_shader_to_pipeline(&shader_wire, &pip_desc_wire, &wire_vertex_layout),
  )

  ctx.shader_wire = shader_wire.shd
  ctx.pip_wire = pip_wire

  ctx.dyn_vbuff = gfx_api.make_buffer(&{
    type = .SG_BUFFERTYPE_VERTEXBUFFER,
    usage = .SG_USAGE_STREAM,
    size = size_of(three_d_api.Debug_Vertex) * MAX_DYN_VERTICES,
    label = "debug3d_vbuffer",
  })
}