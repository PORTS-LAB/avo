#version 310 es
// Like ANGLE's gl_FragData[8]: mediump (RelaxedPrecision), constant indices.
precision mediump float;
layout(location = 0) out vec4 color[8];
void main() {
    color[0] = vec4(1.0, 0.0, 0.0, 1.0);
    color[1] = vec4(0.0, 1.0, 0.0, 1.0);
}
// unsplit fails
// expect 1: ff0000ff ff0000ff
// expect 2: ff0000ff ff0000ff 00ff00ff 00ff00ff
