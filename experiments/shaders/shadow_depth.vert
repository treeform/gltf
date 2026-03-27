#version 410

layout(location = 0) in vec3 vertexPosition;
layout(location = 3) in vec2 vertexUv;

out vec2 vUv;

uniform mat4 model;
uniform mat4 view;
uniform mat4 proj;

void main() {
  vUv = vertexUv;
  gl_Position = proj * view * model * vec4(vertexPosition, 1.0);
}
