#version 450
// A return before the end, and an output read back through a component.
layout(location = 0) out vec4 color[2];
void main() {
    color[0] = vec4(0.0, 0.5, 0.0, 1.0);
    color[1] = vec4(0.0, 0.0, 0.0, 1.0);
    if (gl_FragCoord.x < 1.0) {
        color[0] = vec4(1.0, 0.0, 1.0, 1.0);
        return;
    }
    color[0].g *= 2.0;
    color[0].r = 1.0;
}
// unsplit fails
// expect 1: ff00ffff ffff00ff
