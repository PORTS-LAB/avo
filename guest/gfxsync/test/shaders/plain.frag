#version 450
// No array: the layer leaves the module alone.
layout(location = 0) out vec4 color;
void main() {
    color = vec4(0.0, 1.0, 0.0, 1.0);
}
// unchanged
// expect 1: 00ff00ff 00ff00ff
