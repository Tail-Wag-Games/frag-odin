#version 450

layout (location=COLOR0)  in vec4 f_color;

layout (location=SV_Target0) out vec4 frag_color;

void main()
{
    frag_color = f_color;
}
