#version 450
// SPIR-V 1.6: the entry point lists every global variable.
// target vulkan1.3
layout(location = 0) out vec4 color[2];
void main() {
    int i = int(gl_FragCoord.x) % 2;
    color[i] = vec4(1.0, 0.0, 0.0, 1.0);
    color[1 - i] = vec4(0.0, 1.0, 0.0, 1.0);
}
// unsplit fails
// expect 2: ff0000ff 00ff00ff 00ff00ff ff0000ff
