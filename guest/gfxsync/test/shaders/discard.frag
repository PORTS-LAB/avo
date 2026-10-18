#version 450
layout(location = 0) out vec4 color[2];
void main() {
    if (gl_FragCoord.x < 1.0) discard;
    color[0] = vec4(1.0);
}
// unsplit fails
// expect 1: 00000000 ffffffff
