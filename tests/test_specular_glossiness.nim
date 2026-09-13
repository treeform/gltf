import std/[base64, json, os], flatty/binny, pixie, vmath, chroma, gltf

block specularGlossinessRoundTrip:
  var positions = newString(36)
  for i, value in [-1'f, -1, 0, 1, -1, 0, 0, 1, 0]: positions.writeFloat32(i * 4, value)
  let map = newImage(1, 1)
  map.fill(rgbx(128, 64, 192, 0))
  let doc = %*{
    "asset": {"version": "2.0"}, "extensionsRequired": ["KHR_materials_pbrSpecularGlossiness"],
    "buffers": [{"byteLength": 36}], "bufferViews": [{"buffer": 0, "byteLength": 36}],
    "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}],
    "images": [{"uri": "data:image/png;base64," & encode(map.encodeStraightAlphaPng())}],
    "samplers": [{"magFilter": 9728, "minFilter": 9728, "wrapS": 33648, "wrapT": 33071}],
    "textures": [{"source": 0, "sampler": 0}],
    "materials": [{"alphaMode": "MASK", "alphaCutoff": 0.25,
      "pbrMetallicRoughness": {"baseColorFactor": [0.1, 0.2, 0.3, 1], "metallicFactor": 0.4, "roughnessFactor": 0.6},
      "extensions": {"KHR_materials_pbrSpecularGlossiness": {
        "diffuseFactor": [0.7, 0.8, 0.9, 0.5], "specularFactor": [0.2, 0.3, 0.4], "glossinessFactor": 0.75,
        "diffuseTexture": {"index": 0, "extensions": {"KHR_texture_transform": {
          "texCoord": 1, "offset": [0.25, 0.5], "scale": [2, 3], "rotation": 0.4}}},
        "specularGlossinessTexture": {"index": 0, "texCoord": 1}}}},
      {"extensions": {"KHR_materials_pbrSpecularGlossiness": {}}}, {}],
    "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "material": 0},
      {"attributes": {"POSITION": 0}, "material": 1}, {"attributes": {"POSITION": 0}, "material": 2}]}],
    "nodes": [{"mesh": 0}], "scenes": [{"nodes": [0]}], "scene": 0}
  let root = loadModelJson(doc, ".", @[positions])
  let primitives = root.nodes[0].mesh.primitives
  let m = primitives[0].material
  doAssert m.hasSpecularGlossiness and m.glossinessFactor == 0.75'f
  doAssert m.diffuseFactor == color(0.7, 0.8, 0.9, 0.5) and m.specularGlossinessFactor == vec3(0.2, 0.3, 0.4)
  doAssert m.baseColorFactor == color(0.1, 0.2, 0.3, 1) and m.metallicFactor == 0.4'f and m.roughnessFactor == 0.6'f
  doAssert m.diffuse[0, 0] == map[0, 0] and m.specularGlossiness[0, 0] == map[0, 0]
  doAssert m.diffuseTransform.texCoord == 1 and m.diffuseTransform.offset == vec2(0.25, 0.5)
  doAssert m.diffuseTransform.scale == vec2(2, 3) and m.diffuseTransform.rotation == 0.4'f
  for i in [1, 2]:
    let other = primitives[i].material
    doAssert other.hasSpecularGlossiness == (i == 1)
    doAssert other.diffuseFactor == color(1, 1, 1, 1) and other.specularGlossinessFactor == vec3(1)
    doAssert other.glossinessFactor == 1
  for mode in [iwmEmbedded, iwmExternal]:
    let output = "tests/tmp/specular-glossiness-" & $mode & ".glb"
    createDir(output.parentDir)
    writeGLB(root, output, mode)
    let reread = readGltfFile(output).root.nodes[0].mesh.primitives[0].material
    doAssert reread.hasSpecularGlossiness and reread.diffuseFactor == m.diffuseFactor
    doAssert reread.specularGlossinessFactor == m.specularGlossinessFactor and reread.glossinessFactor == m.glossinessFactor
    doAssert reread.diffuseTransform == m.diffuseTransform and reread.specularGlossinessTransform == m.specularGlossinessTransform
    doAssert reread.diffuseSampler == m.diffuseSampler and reread.specularGlossinessSampler == m.specularGlossinessSampler
    doAssert reread.diffuse[0, 0] == map[0, 0] and reread.specularGlossiness[0, 0] == map[0, 0]
    doAssert reread.baseColorFactor == m.baseColorFactor and reread.metallicFactor == m.metallicFactor
    doAssert reread.roughnessFactor == m.roughnessFactor and reread.alphaMode == m.alphaMode and reread.alphaCutoff == m.alphaCutoff
  echo "Specular/glossiness: defaults, factors, packed texture, straight alpha, UV/samplers and fallback-preserving export passed"
