#version 450

layout (location=POSITION) in vec3 a_pos;
layout (location=COLOR0) in vec4 a_color;

layout (location=COLOR0) out vec4 f_color;

layout (binding=0, std140) uniform matrices {
    mat4 mvp;
};

void main() 
{
    gl_Position = mvp * vec4(a_pos, 1.0);
    f_color = a_color;
}