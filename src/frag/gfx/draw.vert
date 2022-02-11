#version 450

layout (location=POSITION)  in  vec2 a_pos;
layout (location=TEXCOORD0) in  vec2 a_coord;

layout (location=TEXCOORD0) out vec2 f_coord;

void main() 
{
    gl_Position = vec4(a_pos, 0.0, 1.0);
    f_coord = a_coord;
}