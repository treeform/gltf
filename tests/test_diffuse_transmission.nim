import std/[base64, json, os], flatty/binny, pixie, vmath, gltf

block diffuseTransmissionRoundTrip:
  var positions = newString(36)
  for i, value in [-1'f32, -1, 0, 1, -1, 0, 0, 1, 0]:
    positions.writeFloat32(i * 4, value)
  let map = newImage(1, 1)
  map.fill(rgbx(128, 64, 192, 37))
  let document = %*{
    "asset": {"version": "2.0"},
    "extensionsRequired": ["KHR_materials_diffuse_transmission"],
    "buffers": [{"byteLength": 36}], "bufferViews": [{"buffer": 0, "byteLength": 36}],
    "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}],
    "images": [{"uri": "data:image/png;base64," & encode(map.encodeStraightAlphaPng())}],
    "samplers": [{"magFilter": 9728, "minFilter": 9728, "wrapS": 33648, "wrapT": 33071}],
    "textures": [{"source": 0, "sampler": 0}],
    "materials": [
      {"extensions": {"KHR_materials_diffuse_transmission": {
        "diffuseTransmissionFactor": 0.7, "diffuseTransmissionColorFactor": [0.2, 0.5, 0.9],
        "diffuseTransmissionTexture": {"index": 0, "extensions": {"KHR_texture_transform": {
          "texCoord": 1, "offset": [0.25, 0.5], "scale": [2, 3], "rotation": 0.4}}},
        "diffuseTransmissionColorTexture": {"index": 0, "texCoord": 1}}}},
      {"extensions": {"KHR_materials_diffuse_transmission": {}}}, {}],
    "meshes": [{"primitives": [
      {"attributes": {"POSITION": 0}, "material": 0},
      {"attributes": {"POSITION": 0}, "material": 1},
      {"attributes": {"POSITION": 0}, "material": 2}]}],
    "nodes": [{"mesh": 0}], "scenes": [{"nodes": [0]}], "scene": 0}
  let root = loadModelJson(document, ".", @[positions])
  let primitives = root.nodes[0].mesh.primitives
  let material = primitives[0].material
  doAssert material.hasDiffuseTransmission and material.diffuseTransmissionFactor == 0.7'f
  doAssert material.diffuseTransmissionColorFactor == vec3(0.2, 0.5, 0.9)
  doAssert material.diffuseTransmission[0, 0] == map[0, 0]
  doAssert material.diffuseTransmissionColor[0, 0] == map[0, 0]
  doAssert material.diffuseTransmissionTransform.texCoord == 1
  doAssert material.diffuseTransmissionTransform.offset == vec2(0.25, 0.5)
  doAssert material.diffuseTransmissionTransform.scale == vec2(2, 3)
  doAssert material.diffuseTransmissionTransform.rotation == 0.4'f
  doAssert material.diffuseTransmissionSampler.wrapS == MirroredRepeatWrap
  for i in [1, 2]:
    let defaults = primitives[i].material
    doAssert defaults.hasDiffuseTransmission == (i == 1)
    doAssert defaults.diffuseTransmissionFactor == 0
    doAssert defaults.diffuseTransmissionColorFactor == vec3(1)
    doAssert defaults.diffuseTransmission == nil and defaults.diffuseTransmissionColor == nil
  for mode in [iwmEmbedded, iwmExternal]:
    let output = "tests/tmp/diffuse-transmission-" & $mode & ".glb"
    createDir(output.parentDir)
    writeGLB(root, output, mode)
    let reread = readGltfFile(output).root.nodes[0].mesh.primitives[0].material
    doAssert reread.hasDiffuseTransmission
    doAssert reread.diffuseTransmissionFactor == material.diffuseTransmissionFactor
    doAssert reread.diffuseTransmissionColorFactor == material.diffuseTransmissionColorFactor
    doAssert reread.diffuseTransmissionTransform == material.diffuseTransmissionTransform
    doAssert reread.diffuseTransmissionColorTransform == material.diffuseTransmissionColorTransform
    doAssert reread.diffuseTransmissionSampler == material.diffuseTransmissionSampler
    doAssert reread.diffuseTransmissionColorSampler == material.diffuseTransmissionColorSampler
    doAssert reread.diffuseTransmission[0, 0] == map[0, 0]
    doAssert reread.diffuseTransmissionColor[0, 0] == map[0, 0]
  echo "Diffuse transmission: required extension, defaults, straight RGBA, UV transforms, samplers and export passed"
