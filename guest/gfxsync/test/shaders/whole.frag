#version 450
// The whole array stored at once.
layout(location = 0) out vec4 color[4];
void main() {
    vec4 colors[4];
    for (int i = 0; i < 4; i++) colors[i] = vec4(float(i) / 3.0, 0.0, 1.0 - float(i) / 3.0, 1.0);
    color = colors;
}
// unsplit fails
// expect 2: 0000ffff 0000ffff 5500aaff 5500aaff
