import std/strutils

import gltf/backends/shaders

proc require(haystack, needle, label: string) =
  doAssert needle in haystack, label & " missing: " & needle

require(PbrVertSrc, "#version 410", "OpenGL PBR vertex shader")
require(PbrVertSrc, "uniform mat4 jointMatrices[128];", "OpenGL skinning")
require(PbrFragSrc, "samplerCube environmentMap", "OpenGL environment map")
require(PbrFragSrc, "sampler2DShadow shadowMap", "OpenGL shadow map")

require(PbrVertHlsl, "float4x4 jointMatrices[128];", "DirectX skinning")
require(PbrFragHlsl, "TextureCube<float4> environmentMap", "DirectX cubemap")
require(PbrFragHlsl, "SamplerComparisonState shadowMapSampler", "DirectX shadow sampler")
require(PbrFragHlsl, "shadowMap.SampleCmpLevelZero", "DirectX shadow sample")
require(PbrFragHlsl, "SV_IsFrontFace", "DirectX front-facing input")

require(PbrVertVulkan, "#version 450", "Vulkan version")
require(PbrVertVulkan, "layout(set = 1, binding = 0, std140)", "Vulkan vertex uniforms")
require(PbrVertVulkan, "layout(location = 0) in vec3 vertexPosition;", "Vulkan inputs")
require(PbrFragVulkan, "layout(set = 0, binding =", "Vulkan descriptors")

require(PbrVertMsl, "vertex VertexOut vertexMain", "Metal vertex stub")
require(PbrFragMsl, "fragment float4 fragmentMain", "Metal fragment stub")

doAssert not PbrVertSrc.startsWith("\0")
echo "glTF backend shader codegen tests passed"
