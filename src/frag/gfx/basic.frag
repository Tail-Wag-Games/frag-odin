#version 450

layout (location=COLOR0)  in vec2 uv;

layout (location=SV_Target0) out vec4 frag_color;

layout (binding = 0) uniform sampler2D tex;

void main()
{
    vec3 col = texture(tex, vec2(uv.x, -uv.y)).rgb;
    frag_color = vec4(col, 1.0);
}