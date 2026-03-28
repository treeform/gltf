#version 410

layout(location = 0) in vec3 vertexPosition;
layout(location = 1) in vec4 vertexColor;
layout(location = 2) in vec3 vertexNormal;
layout(location = 3) in vec2 vertexUV;
layout(location = 4) in vec4 vertexTangent;
layout(location = 5) in uvec4 vertexJoints;
layout(location = 6) in vec4 vertexWeights;
layout(location = 7) in vec2 vertexUV1;

uniform mat4 model;
uniform mat4 view;
uniform mat4 proj;
uniform mat4 lightSpace;
uniform bool useSkinning;
uniform mat4 jointMatrices[128];

out vec3 position;
out vec4 color;
out vec3 normal;
out vec2 uv;
out vec2 uv1;
out mat3 TBN;
out mat4 modelMat;
out vec4 vPosLightSpace;

mat4 skinMatrix() {
  return
    vertexWeights.x * jointMatrices[int(vertexJoints.x)] +
    vertexWeights.y * jointMatrices[int(vertexJoints.y)] +
    vertexWeights.z * jointMatrices[int(vertexJoints.z)] +
    vertexWeights.w * jointMatrices[int(vertexJoints.w)];
}

void main() {
  mat4 skin =
    useSkinning
    ? skinMatrix()
    : mat4(1.0);
  vec4 skinnedPosition = skin * vec4(vertexPosition, 1.0);
  vec3 skinnedNormal = (skin * vec4(vertexNormal, 0.0)).xyz;
  vec3 skinnedTangent = (skin * vec4(vertexTangent.xyz, 0.0)).xyz;

  position = (model * skinnedPosition).xyz;
  color = vertexColor;
  uv = vertexUV;
  uv1 = vertexUV1;

  // Normal, Tangent, and Bitangent
  vec3 N = normalize(mat3(model) * skinnedNormal); // Normal
  normal = N;
  vec3 T = normalize(mat3(model) * skinnedTangent); // Tangent
  vec3 B = cross(N, T) * vertexTangent.w; // Bitangent, correct handedness with tangent.w

  // Construct the TBN matrix
  TBN = mat3(T, B, N);
  modelMat = model;
  vPosLightSpace = lightSpace * vec4(position, 1.0);

  gl_Position = proj * view * model * skinnedPosition;
}
