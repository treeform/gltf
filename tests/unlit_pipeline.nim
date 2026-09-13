## Exercise unlit materials through both real OpenGL presentation paths.
import std/[json, math], flatty/binny, opengl, windy, vmath, chroma, pixie, gltf

proc constantTexture(target: GLenum): GLuint =
  glGenTextures(1, result.addr)
  glBindTexture(target, result)
  var rgba = [2'f32, 0.5'f32, 4'f32, 1'f32]
  if target == GL_TEXTURE_CUBE_MAP:
    for face in 0 ..< 6:
      glTexImage2D((GL_TEXTURE_CUBE_MAP_POSITIVE_X.int + face).GLenum, 0,
        GL_RGBA16F.GLint, 1, 1, 0, GL_RGBA, cGL_FLOAT, rgba[0].addr)
  else:
    glTexImage2D(target, 0, GL_RGBA16F.GLint, 1, 1, 0,
      GL_RGBA, cGL_FLOAT, rgba[0].addr)
  glTexParameteri(target, GL_TEXTURE_MIN_FILTER, GL_NEAREST.GLint)
  glTexParameteri(target, GL_TEXTURE_MAG_FILTER, GL_NEAREST.GLint)

proc decode(v: float64): float64 =
  if v <= 0.04045: v / 12.92 else: pow((v + 0.055) / 1.055, 2.4)

let window = newWindow("Unlit pipeline test", ivec2(32, 32), visible = false)
makeContextCurrent(window)
loadExtensions()
let renderer = newRenderer(window)
var positions = newString(72)
for i, value in [-0.9'f32, -0.9, 0, 0.9, -0.9, 0, 0.9, 0.9, 0,
    -0.9'f32, -0.9, 0, 0.9, 0.9, 0, -0.9, 0.9, 0]:
  positions.writeFloat32(i * 4, value)
let root = loadModelJson(%*{
  "asset": {"version": "2.0"},
  "buffers": [{"byteLength": 72}],
  "bufferViews": [{"buffer": 0, "byteLength": 72}],
  "accessors": [{"bufferView": 0, "componentType": 5126, "count": 6, "type": "VEC3"}],
  "materials": [{"extensions": {"KHR_materials_unlit": {}},
    "pbrMetallicRoughness": {"baseColorFactor": [0.5, 0.75, 1, 0.5]},
    "emissiveFactor": [1, 0, 1]}],
  "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "material": 0}]}],
  "nodes": [{"mesh": 0}], "scenes": [{"nodes": [0]}], "scene": 0
}, ".", @[positions])
let primitive = root.nodes[0].mesh.primitives[0]
for i in 0 ..< primitive.points.len:
  primitive.uvs.add(vec2(0, 0))
  primitive.colors.add(rgbx(128, 255, 128, 255))
let material = primitive.material
material.baseColor = newImage(1, 1)
material.baseColor.fill(rgbx(128, 64, 192, 255))
material.baseColorPlaceholder = false
let linear = [decode(128.0 / 255) * 0.5 * 128 / 255,
  decode(64.0 / 255) * 0.75, decode(192.0 / 255) * 128 / 255]
for hdr in [false, true]:
  let pbr = newPbrContext(renderer)
  if hdr:
    pbr.attachIblEnvironment(IblEnvironment(
      diffuse: constantTexture(GL_TEXTURE_CUBE_MAP),
      specular: constantTexture(GL_TEXTURE_CUBE_MAP),
      lut: constantTexture(GL_TEXTURE_2D), mipCount: 1, intensityScale: 1))
  else:
    pbr.attachEnvironmentMap(EnvironmentMap(
      textureId: constantTexture(GL_TEXTURE_CUBE_MAP), mipCount: 1))
  pbr.size = window.size
  pbr.clearColor = color(0, 0, 0, 1)
  pbr.view = mat4()
  pbr.proj = mat4()
  pbr.transform = mat4()
  pbr.tint = color(1, 1, 1, 1)
  pbr.cameraPosition = vec3(0, 0, 1)
  pbr.useShadows = false
  pbr.drawSkybox = false
  for exposure in [0.25'f32, 1'f32, 4'f32]:
    pbr.exposure = exposure
    pbr.sunLightColor = color(exposure, 0, 0, 1)
    pbr.ambientLightColor = color(0, exposure, 0, 1)
    pbr.fogColor = color(1, 0, 0, 1)
    pbr.fogStrength = 1
    pbr.fogDensity = 100
    for testCase in 0 ..< 4:
      material.alphaMode = [OpaqueAlphaMode, MaskAlphaMode, MaskAlphaMode, BlendAlphaMode][testCase]
      material.alphaCutoff = if testCase == 2: 0.75 else: 0.25
      inc material.materialVersion
      renderer.beginFrame(window, window.size)
      renderer.clearScreen(color(0, 0, 0, 1))
      if hdr: pbr.beginIblFrame()
      pbr.draw(root)
      if hdr: pbr.endIblFrame()
      renderer.endFrame()
      var actual: array[4, uint8]
      glReadBuffer(GL_BACK)
      glReadPixels(16, 16, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, actual[0].addr)
      for channel in 0 ..< 3:
        let expected =
          if testCase == 2: 0
          elif testCase == 3 and hdr: round(pow(linear[channel] * 0.5, 1 / 2.2) * 255).int
          elif testCase == 3: round(pow(linear[channel], 1 / 2.2) * 255 * 0.5).int
          else: round(pow(linear[channel], 1 / 2.2) * 255).int
        doAssert abs(actual[channel].int - expected) <= 2,
          "Unlit HDR=" & $hdr & " case=" & $testCase & " channel=" & $channel &
          " got=" & $actual[channel] & " expected=" & $expected
      doAssert glGetError() == GL_NO_ERROR
  pbr.destroy()
renderer.release(root)
renderer.shutdown()
echo "Unlit GPU pipeline: texture/factor/vertex colors, alpha modes, and lighting/exposure independence passed"
