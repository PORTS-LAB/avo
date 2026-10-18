#version 450
// Written from another function.
layout(location = 0) out vec4 color[3];
void paint(int i, vec4 c) {
    color[i] = c;
}
void main() {
    paint(0, vec4(1.0, 0.0, 0.0, 1.0));
    paint(1, vec4(0.0, 0.0, 1.0, 1.0));
}
// unsplit fails
// expect 1: ff0000ff ff0000ff
// expect 2: ff0000ff ff0000ff 0000ffff 0000ffff
