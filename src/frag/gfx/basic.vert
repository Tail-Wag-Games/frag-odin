#version 450

layout (location=POSITION) in vec2 position;
layout (location=TEXCOORD0) in vec2 texcoord0;

layout (location=TEXCOORD0) out vec2 uv;

void main() 
{
    gl_Position = vec4(position.x, position.y, 0.0, 1.0);
    uv = texcoord0;
}