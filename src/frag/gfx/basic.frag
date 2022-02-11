#version 450

layout (location=TEXCOORD0)  in vec2 f_coord;

layout (location=SV_Target0) out vec4 frag_color;

layout (binding=0) uniform sampler2D diffuse_texture;

void main()
{
    frag_color = texture(diffuse_texture, f_coord);
}
