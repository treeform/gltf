import
  std/[json, tables],
  flatty/binny, opengl, pixie, pixie/fileformats/png, vmath,
  common, internal

export common

proc pad4(data: var string) =
  ## Pads a string to a 4-byte boundary.
  while data.len mod 4 != 0:
    data.add(char(0))

proc writeUint32Le(s: var string, v: uint32) =
  ## Writes a little-endian uint32 value.
  s.add(char(v and 0xFF))
  s.add(char((v shr 8) and 0xFF))
  s.add(char((v shr 16) and 0xFF))
  s.add(char((v shr 24) and 0xFF))

proc writeUint16AtLe(s: var string, offset: int, v: uint16) =
  ## Writes a little-endian uint16 at an offset.
  s[offset] = char(v and 0xFF)
  s[offset + 1] = char((v shr 8) and 0xFF)

proc writeUint32AtLe(s: var string, offset: int, v: uint32) =
  ## Writes a little-endian uint32 at an offset.
  s[offset + 0] = char(v and 0xFF)
  s[offset + 1] = char((v shr 8) and 0xFF)
  s[offset + 2] = char((v shr 16) and 0xFF)
  s[offset + 3] = char((v shr 24) and 0xFF)

proc addView(
  data: var string,
  payload: string,
  stride = 0
): BufferView =
  ## Appends payload bytes and returns a buffer view.
  let offset = data.len
  data.add(payload)
  pad4(data)
  BufferView(
    buffer: 0,
    byteOffset: offset,
    byteLength: payload.len,
    byteStride: stride
  )

proc addAccessor(
  accessors: var seq[Accessor],
  bufferViews: var seq[BufferView],
  data: var string,
  payload: string,
  kind: AccessorKind,
  component: GLenum,
  count: int,
  stride = 0
): int =
  ## Adds an accessor and its backing buffer view.
  bufferViews.add(addView(data, payload, stride))
  let
    viewIdx = bufferViews.len - 1
    accessor = Accessor(
      bufferView: viewIdx,
      byteOffset: 0,
      count: count,
      componentType: component,
      kind: kind
    )
  accessors.add(accessor)
  accessors.len - 1

proc writeImagePng(
  images: var seq[JsonNode],
  bufferViews: var seq[BufferView],
  data: var string,
  img: Image
) =
  ## Encodes and appends an image as PNG data.
  let pngData = img.encodePng()
  bufferViews.add(addView(data, pngData))
  let viewIdx = bufferViews.len - 1
  var node = newJObject()
  node["bufferView"] = newJInt(viewIdx)
  node["mimeType"] = newJString("image/png")
  images.add(node)

proc writeGLB*(root: Node, path: string) =
  ## Writes a node hierarchy to a binary glTF file.
  var
    data = newString(0)
    bufferViews: seq[BufferView]
    accessors: seq[Accessor]
    samplers: seq[Sampler]
    textures: seq[JsonNode]
    images: seq[JsonNode]
    materials: seq[JsonNode]
    meshes: seq[JsonNode]
    nodesJson: seq[JsonNode]
    usesNodeVisibility = false

  samplers.add(Sampler(
    magFilter: GL_LINEAR,
    minFilter: GL_LINEAR_MIPMAP_LINEAR,
    wrapS: GL_REPEAT,
    wrapT: GL_REPEAT
  ))

  var materialIds = initTable[pointer, int]()

  proc materialIndex(mat: Material): int =
    ## Returns the output material index for a material.
    if mat == nil:
      return -1
    let key = cast[pointer](mat)
    if key in materialIds:
      return materialIds[key]

    var matNode = newJObject()
    matNode["name"] = newJString(mat.name)
    var pbr = newJObject()
    let cf = mat.baseColorFactor
    pbr["baseColorFactor"] = newJArray()
    pbr["baseColorFactor"].add(newJFloat(cf.r))
    pbr["baseColorFactor"].add(newJFloat(cf.g))
    pbr["baseColorFactor"].add(newJFloat(cf.b))
    pbr["baseColorFactor"].add(newJFloat(cf.a))
    pbr["metallicFactor"] = newJFloat(mat.metallicFactor)
    pbr["roughnessFactor"] = newJFloat(mat.roughnessFactor)

    if mat.baseColor != nil:
      writeImagePng(images, bufferViews, data, mat.baseColor)
      let imgIdx = images.len - 1
      textures.add(%*{"source": imgIdx, "sampler": 0})
      let texIdx = textures.len - 1
      pbr["baseColorTexture"] = %*{"index": texIdx}

    matNode["pbrMetallicRoughness"] = pbr
    matNode["doubleSided"] = newJBool(mat.doubleSided)
    case mat.alphaMode
    of OpaqueAlphaMode:
      matNode["alphaMode"] = newJString("OPAQUE")
    of MaskAlphaMode:
      matNode["alphaMode"] = newJString("MASK")
      let cutoff =
        if mat.alphaCutoff > 0:
          mat.alphaCutoff
        else:
          0.5
      matNode["alphaCutoff"] = newJFloat(cutoff)
    of BlendAlphaMode:
      matNode["alphaMode"] = newJString("BLEND")
    materials.add(matNode)
    let idx = materials.len - 1
    materialIds[key] = idx
    idx

  var meshIds = initTable[pointer, int]()

  proc primitiveJson(primitive: Primitive): JsonNode =
    ## Builds one glTF primitive entry from runtime data.
    var attributes = newJObject()

    if primitive.points.len > 0:
      var payload = newString(primitive.points.len * 12)
      for i, p in primitive.points:
        payload.writeFloat32(i * 12 + 0, p.x)
        payload.writeFloat32(i * 12 + 4, p.y)
        payload.writeFloat32(i * 12 + 8, p.z)
      let acc = addAccessor(
        accessors,
        bufferViews,
        data,
        payload,
        atVEC3,
        cGL_FLOAT,
        primitive.points.len,
        0
      )
      attributes["POSITION"] = newJInt(acc)

    if primitive.normals.len == primitive.points.len and
      primitive.normals.len > 0:
      var payload = newString(primitive.normals.len * 12)
      for i, p in primitive.normals:
        payload.writeFloat32(i * 12 + 0, p.x)
        payload.writeFloat32(i * 12 + 4, p.y)
        payload.writeFloat32(i * 12 + 8, p.z)
      let acc = addAccessor(
        accessors,
        bufferViews,
        data,
        payload,
        atVEC3,
        cGL_FLOAT,
        primitive.normals.len,
        0
      )
      attributes["NORMAL"] = newJInt(acc)

    if primitive.uvs.len == primitive.points.len and primitive.uvs.len > 0:
      var payload = newString(primitive.uvs.len * 8)
      for i, p in primitive.uvs:
        payload.writeFloat32(i * 8 + 0, p.x)
        payload.writeFloat32(i * 8 + 4, p.y)
      let acc = addAccessor(
        accessors,
        bufferViews,
        data,
        payload,
        atVEC2,
        cGL_FLOAT,
        primitive.uvs.len,
        0
      )
      attributes["TEXCOORD_0"] = newJInt(acc)

    if primitive.colors.len == primitive.points.len and
      primitive.colors.len > 0:
      var payload = newString(primitive.colors.len * 4)
      for i, c in primitive.colors:
        payload[i * 4 + 0] = char(c.r)
        payload[i * 4 + 1] = char(c.g)
        payload[i * 4 + 2] = char(c.b)
        payload[i * 4 + 3] = char(c.a)
      let acc = addAccessor(
        accessors,
        bufferViews,
        data,
        payload,
        atVEC4,
        GL_UNSIGNED_BYTE,
        primitive.colors.len,
        0
      )
      attributes["COLOR_0"] = newJInt(acc)

    var indicesAcc = -1
    if primitive.indices16.len > 0:
      var fitsUint8 = true
      for idxVal in primitive.indices16:
        if idxVal > 255:
          fitsUint8 = false
          break
      if fitsUint8:
        var payload = newString(primitive.indices16.len)
        for i, idxVal in primitive.indices16:
          payload[i] = char(idxVal.uint8)
        indicesAcc = addAccessor(
          accessors,
          bufferViews,
          data,
          payload,
          atSCALAR,
          GL_UNSIGNED_BYTE,
          primitive.indices16.len,
          0
        )
      else:
        var payload = newString(primitive.indices16.len * 2)
        for i, idxVal in primitive.indices16:
          payload.writeUint16AtLe(i * 2, idxVal)
        indicesAcc = addAccessor(
          accessors,
          bufferViews,
          data,
          payload,
          atSCALAR,
          cGL_UNSIGNED_SHORT,
          primitive.indices16.len,
          0
        )
    elif primitive.indices32.len > 0:
      var payload = newString(primitive.indices32.len * 4)
      for i, idxVal in primitive.indices32:
        payload.writeUint32AtLe(i * 4, idxVal)
      indicesAcc = addAccessor(
        accessors,
        bufferViews,
        data,
        payload,
        atSCALAR,
        GL_UNSIGNED_INT,
        primitive.indices32.len,
        0
      )

    result = newJObject()
    result["attributes"] = attributes
    if indicesAcc >= 0:
      result["indices"] = newJInt(indicesAcc)
    result["mode"] = newJInt(primitive.mode.int)
    let matIdx = materialIndex(primitive.material)
    if matIdx >= 0:
      result["material"] = newJInt(matIdx)

  proc addMeshForNode(n: Node): int =
    ## Adds mesh data for a node and returns its index.
    if n.mesh == nil or n.mesh.primitives.len == 0:
      return -1
    let key = cast[pointer](n.mesh)
    if key in meshIds:
      return meshIds[key]

    var meshObj = newJObject()
    let meshName =
      if n.mesh.name.len > 0:
        n.mesh.name
      else:
        n.name
    meshObj["name"] = newJString(meshName)
    meshObj["primitives"] = newJArray()
    for primitive in n.mesh.primitives:
      meshObj["primitives"].add(primitiveJson(primitive))
    meshes.add(meshObj)
    let idx = meshes.len - 1
    meshIds[key] = idx
    idx

  proc walk(n: Node): int =
    ## Walks the node tree and returns the node index.
    var nodeObj = newJObject()
    nodeObj["name"] = newJString(n.name)
    nodeObj["translation"] = %*[n.pos.x, n.pos.y, n.pos.z]
    nodeObj["rotation"] = %*[n.rot.x, n.rot.y, n.rot.z, n.rot.w]
    nodeObj["scale"] = %*[n.scale.x, n.scale.y, n.scale.z]
    if not n.visible:
      usesNodeVisibility = true
      nodeObj["extensions"] = %*{
        "KHR_node_visibility": {
          "visible": false
        }
      }

    let meshIdx = addMeshForNode(n)
    if meshIdx >= 0:
      nodeObj["mesh"] = newJInt(meshIdx)

    if n.nodes.len > 0:
      nodeObj["children"] = newJArray()
      for child in n.nodes:
        let childIdx = walk(child)
        nodeObj["children"].add(newJInt(childIdx))

    nodesJson.add(nodeObj)
    nodesJson.len - 1

  let rootIdx = walk(root)

  var jsonRoot = newJObject()
  jsonRoot["asset"] = %*{"version": "2.0"}
  if usesNodeVisibility:
    jsonRoot["extensionsUsed"] = %*["KHR_node_visibility"]
  jsonRoot["buffers"] = %*[{"byteLength": data.len}]

  jsonRoot["bufferViews"] = newJArray()
  for bv in bufferViews:
    jsonRoot["bufferViews"].add(%*{
      "buffer": bv.buffer,
      "byteOffset": bv.byteOffset,
      "byteLength": bv.byteLength,
      "byteStride": bv.byteStride
    })

  jsonRoot["accessors"] = newJArray()
  for acc in accessors:
    jsonRoot["accessors"].add(%*{
      "bufferView": acc.bufferView,
      "byteOffset": acc.byteOffset,
      "componentType": acc.componentType.int,
      "count": acc.count,
      "type": (
        case acc.kind
        of atSCALAR: "SCALAR"
        of atVEC2: "VEC2"
        of atVEC3: "VEC3"
        of atVEC4: "VEC4"
        of atMAT2: "MAT2"
        of atMAT3: "MAT3"
        of atMAT4: "MAT4"
      )
    })

  jsonRoot["samplers"] = newJArray()
  for s in samplers:
    jsonRoot["samplers"].add(%*{
      "magFilter": s.magFilter,
      "minFilter": s.minFilter,
      "wrapS": s.wrapS,
      "wrapT": s.wrapT
    })

  if textures.len > 0:
    jsonRoot["textures"] = %*textures
  if images.len > 0:
    jsonRoot["images"] = %*images
  if materials.len > 0:
    jsonRoot["materials"] = %*materials

  jsonRoot["meshes"] = %*meshes
  jsonRoot["nodes"] = %*nodesJson
  jsonRoot["scenes"] = %*[{"nodes": %*[rootIdx]}]
  jsonRoot["scene"] = newJInt(0)

  var jsonStr = $jsonRoot
  while jsonStr.len mod 4 != 0:
    jsonStr.add(' ')

  var glb = newString(0)
  writeUint32Le(glb, 0x46546C67)
  writeUint32Le(glb, 2)
  writeUint32Le(glb, 0)

  writeUint32Le(glb, jsonStr.len.uint32)
  writeUint32Le(glb, 0x4E4F534A)
  glb.add(jsonStr)

  pad4(data)
  writeUint32Le(glb, data.len.uint32)
  writeUint32Le(glb, 0x004E4942)
  glb.add(data)

  let totalLen = glb.len
  glb[8] = char(totalLen and 0xFF)
  glb[9] = char((totalLen shr 8) and 0xFF)
  glb[10] = char((totalLen shr 16) and 0xFF)
  glb[11] = char((totalLen shr 24) and 0xFF)

  writeFile(path, glb)
