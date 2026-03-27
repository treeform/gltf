#version 410
layout(location = 0) in vec2 vertexPosition;
out vec3 rayDir;
uniform mat4 invProj;
uniform mat4 invView;
void main() {
    gl_Position = vec4(vertexPosition, 1.0, 1.0);
    vec4 far = invProj * vec4(vertexPosition, 1.0, 1.0);
    rayDir = mat3(invView) * far.xyz;
}
