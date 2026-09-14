## Rebuild checked-in Vulkan binaries entirely from the shared Shady shaders.
## Run: nim r tools/build_backend_shaders.nim (requires glslangValidator).
import std/os, shady, gltf/backends/shaders

const outputDirectory = currentSourcePath().parentDir.parentDir /
  "src/gltf/backends/shaders"
const scratchDirectory = getTempDir() / "gltf-shady-binary-build"

static:
  for (name, source, stage) in [
      ("gltf_pbr.vert", PbrVertVulkan, binaryVertex),
      ("gltf_pbr.frag", PbrFragVulkan, binaryFragment),
      ("gltf_ibl.frag", IblFragVulkan, binaryFragment),
      ("gltf_post.vert", HdrPostVertVulkan, binaryVertex),
      ("gltf_post.frag", HdrPostFragVulkan, binaryFragment)]:
    let binary = compileSpirvShader(source, scratchDirectory / name,
      scratchDirectory / (name & ".spv"), stage)
    writeFile(outputDirectory / (name & ".spv"), binary)

echo "Rebuilt five Shady-generated Vulkan shader binaries"
