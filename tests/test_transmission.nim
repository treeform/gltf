import std/[base64, json, os], flatty/binny, pixie, vmath, gltf

block transmissionMaterials:
  var positions = newString(36)
  for i, value in [-1'f32, -1, 0, 1, -1, 0, 0, 1, 0]:
    positions.writeFloat32(i * 4, value)
  let map = newImage(1, 1)
  map.fill(rgbx(128, 64, 192, 0))
  let document = %*{
    "asset": {"version": "2.0"},
    "extensionsRequired": ["KHR_materials_transmission", "KHR_materials_volume", "KHR_materials_ior"],
    "buffers": [{"byteLength": 36}],
    "bufferViews": [{"buffer": 0, "byteLength": 36}],
    "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}],
    "images": [{"uri": "data:image/png;base64," & encode(map.encodeStraightAlphaPng())}],
    "samplers": [{"magFilter": 9728, "minFilter": 9728, "wrapS": 33648, "wrapT": 33071},
      {"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}],
    "textures": [{"source": 0, "sampler": 0}, {"source": 0, "sampler": 1}],
    "materials": [
      {"extensions": {
        "KHR_materials_transmission": {"transmissionFactor": 0.7,
          "transmissionTexture": {"index": 0, "extensions": {"KHR_texture_transform": {
            "texCoord": 1, "offset": [0.25, 0.5], "scale": [2, 3], "rotation": 0.4}}}},
        "KHR_materials_volume": {"thicknessFactor": 0.8, "thicknessTexture": {"index": 1},
          "attenuationColor": [0.2, 0.5, 0.9], "attenuationDistance": 1.2},
        "KHR_materials_ior": {"ior": 1.33}}},
      {"extensions": {"KHR_materials_transmission": {}, "KHR_materials_volume": {}, "KHR_materials_ior": {}}},
      {},
      {"alphaMode": "BLEND", "extensions": {"KHR_materials_transmission": {"transmissionFactor": 1}}},
      {"alphaMode": "MASK", "alphaCutoff": 0.25,
        "extensions": {"KHR_materials_transmission": {"transmissionFactor": 1}}},
      {"extensions": {"KHR_materials_ior": {"ior": 0}}}
    ],
    "meshes": [{"primitives": [
      {"attributes": {"POSITION": 0}, "material": 0},
      {"attributes": {"POSITION": 0}, "material": 1},
      {"attributes": {"POSITION": 0}, "material": 2},
      {"attributes": {"POSITION": 0}, "material": 3},
      {"attributes": {"POSITION": 0}, "material": 4},
      {"attributes": {"POSITION": 0}, "material": 5}]}],
    "nodes": [{"mesh": 0}], "scenes": [{"nodes": [0]}], "scene": 0
  }
  let root = loadModelJson(document, ".", @[positions])
  let primitives = root.nodes[0].mesh.primitives
  let glass = primitives[0].material
  primitives[0].uvs1 = @[vec2(0.2, 0.3), vec2(0.8, 0.3), vec2(0.5, 0.9)]
  doAssert glass.alphaMode == OpaqueAlphaMode, "Transmission must preserve authored coverage"
  doAssert glass.legacyAlphaMode == BlendAlphaMode
  doAssert glass.hasTransmission and glass.hasVolume
  doAssert glass.transmissionFactor == 0.7'f and glass.ior == 1.33'f
  doAssert glass.transmission[0, 0] == rgbx(128, 64, 192, 0)
  doAssert glass.thickness[0, 0] == rgbx(128, 64, 192, 0)
  doAssert glass.transmissionTransform.texCoord == 1
  doAssert glass.transmissionTransform.offset == vec2(0.25, 0.5)
  doAssert glass.transmissionTransform.scale == vec2(2, 3)
  doAssert glass.transmissionTransform.rotation == 0.4'f
  doAssert glass.transmissionSampler.wrapS == MirroredRepeatWrap
  doAssert glass.thicknessSampler.wrapS == RepeatWrap
  for i in [1, 2]:
    let defaults = primitives[i].material
    doAssert defaults.hasTransmission == (i == 1)
    doAssert defaults.transmissionFactor == 0 and defaults.thicknessFactor == 0
    doAssert defaults.attenuationColor == vec3(1) and defaults.attenuationDistance == 0
    doAssert defaults.ior == 1.5'f
    doAssert defaults.transmission == nil and defaults.thickness == nil
  doAssert primitives[3].material.alphaMode == BlendAlphaMode
  doAssert primitives[4].material.alphaMode == MaskAlphaMode
  doAssert primitives[4].material.legacyAlphaMode == MaskAlphaMode
  doAssert primitives[5].material.hasIor and primitives[5].material.ior == 0
  for mode in [iwmEmbedded, iwmExternal]:
    let output = "tests/tmp/transmission-materials-" & $mode & ".glb"
    createDir(output.parentDir)
    writeGLB(root, output, mode)
    let reread = readGltfFile(output).root.nodes[0].mesh.primitives
    for i, primitive in primitives:
      let a = primitive.material
      let b = reread[i].material
      doAssert a.alphaMode == b.alphaMode
      doAssert a.hasTransmission == b.hasTransmission and a.hasVolume == b.hasVolume
      doAssert a.transmissionFactor == b.transmissionFactor and a.ior == b.ior
      doAssert a.hasIor == b.hasIor
      doAssert a.thicknessFactor == b.thicknessFactor
      doAssert a.attenuationColor == b.attenuationColor
      doAssert a.attenuationDistance == b.attenuationDistance
      doAssert a.transmissionTransform == b.transmissionTransform
      doAssert a.thicknessTransform == b.thicknessTransform
      doAssert a.transmissionSampler == b.transmissionSampler
      doAssert a.thicknessSampler == b.thicknessSampler
    doAssert reread[0].material.transmission[0, 0] == map[0, 0]
    doAssert reread[0].uvs1 == primitives[0].uvs1
    doAssert reread[0].material.thickness[0, 0] == map[0, 0]
  let compressed = newImage(4, 4)
  compressed.fill(rgbx(128, 64, 192, 255))
  glass.transmissionKtx2 = encodeKtx2Image(compressed, VkFormatBc3UnormBlock,
    generateMipmaps = false, straightAlpha = true)
  glass.thicknessKtx2 = glass.transmissionKtx2
  glass.transmission = nil
  glass.thickness = nil
  for mode in [iwmEmbedded, iwmExternal]:
    let output = "tests/tmp/transmission-ktx-" & $mode & ".glb"
    writeGLB(root, output, mode)
    let reread = readGltfFile(output).root.nodes[0].mesh.primitives[0].material
    doAssert reread.transmissionKtx2 == glass.transmissionKtx2
    doAssert reread.thicknessKtx2 == glass.thicknessKtx2
    doAssert reread.transmissionSampler == glass.transmissionSampler
    doAssert reread.transmissionTransform == glass.transmissionTransform
  echo "Transmission/volume/IOR: defaults, coverage, PNG/KTX2 maps, transforms, samplers and round-trip passed"
