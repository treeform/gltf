#version 410

layout(location = 0) in vec3 vertexPosition;
layout(location = 3) in vec2 vertexUv;
layout(location = 5) in uvec4 vertexJoints;
layout(location = 6) in vec4 vertexWeights;

out vec2 vUv;

uniform mat4 model;
uniform mat4 view;
uniform mat4 proj;
uniform bool useSkinning;
uniform mat4 jointMatrices[128];

mat4 skinMatrix() {
  return
    vertexWeights.x * jointMatrices[int(vertexJoints.x)] +
    vertexWeights.y * jointMatrices[int(vertexJoints.y)] +
    vertexWeights.z * jointMatrices[int(vertexJoints.z)] +
    vertexWeights.w * jointMatrices[int(vertexJoints.w)];
}

void main() {
  vUv = vertexUv;
  mat4 skin =
    useSkinning
    ? skinMatrix()
    : mat4(1.0);
  gl_Position = proj * view * model * skin * vec4(vertexPosition, 1.0);
}
