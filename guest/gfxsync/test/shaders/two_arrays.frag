#version 450
layout(location = 0) out vec4 a[2];
layout(location = 2) out vec4 b[2];
void main() {
    a[0] = vec4(1.0, 0.0, 0.0, 1.0);
    a[1] = vec4(0.0, 1.0, 0.0, 1.0);
    b[0] = vec4(0.0, 0.0, 1.0, 1.0);
    b[1] = vec4(1.0, 1.0, 1.0, 1.0);
}
// unsplit fails
// expect 1: ff0000ff ff0000ff
// expect 3: ff0000ff ff0000ff 00ff00ff 00ff00ff 0000ffff 0000ffff
