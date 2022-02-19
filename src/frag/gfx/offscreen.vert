#version 450

layout (location=POSITION) in vec3 position;
layout (location=COLOR0) in vec4 color;

layout (location=COLOR0) out vec4 frag_color;

layout (binding=0, std140) uniform matrices {
    mat4 mvp;
};

void main() 
{
    gl_Position = mvp * vec4(position, 1.0);
    frag_color = color;
}