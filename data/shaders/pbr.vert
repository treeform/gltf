#version 410

layout(location = 0) in vec3 vertexPosition;
layout(location = 1) in vec4 vertexColor;
layout(location = 2) in vec3 vertexNormal;
layout(location = 3) in vec2 vertexUV;
layout(location = 4) in vec4 vertexTangent;

uniform mat4 model;
uniform mat4 view;
uniform mat4 proj;
uniform mat4 lightSpace;

out vec3 position;
out vec4 color;
out vec3 normal;
out vec2 uv;
out mat3 TBN;
out mat4 modelMat;
out vec4 vPosLightSpace;

void main() {
  position = (model * vec4(vertexPosition, 1.0)).xyz;
  color = vertexColor;
  uv = vertexUV;

  // Normal, Tangent, and Bitangent
  vec3 N = normalize(mat3(model) * vertexNormal); // Normal
  normal = N;
  vec3 T = normalize(mat3(model) * vertexTangent.xyz); // Tangent
  vec3 B = cross(N, T) * vertexTangent.w; // Bitangent, correct handedness with tangent.w

  // Construct the TBN matrix
  TBN = mat3(T, B, N);
  modelMat = model;
  vPosLightSpace = lightSpace * vec4(position, 1.0);

  gl_Position = proj * view * model * vec4(vertexPosition, 1.0);
}
