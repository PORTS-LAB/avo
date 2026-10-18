#version 450
// Indices only known per pixel.
layout(location = 0) out vec4 color[4];
void main() {
    int i = int(gl_FragCoord.x) % 2;
    color[i] = vec4(0.0, 0.0, 1.0, 1.0);
    color[1 - i] = vec4(1.0, 1.0, 0.0, 1.0);
}
// unsplit fails
// expect 1: 0000ffff ffff00ff
// expect 2: 0000ffff ffff00ff ffff00ff 0000ffff
