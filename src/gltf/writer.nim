import
  std/[json, tables],
  flatty/binny, opengl, vmath,
  common, models

export common

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

  samplers.add(Sampler(
    magFilter: GL_LINEAR,
    minFilter: GL_LINEAR_MIPMAP_LINEAR,
    wrapS: GL_REPEAT,
    wrapT: GL_REPEAT
  ))

  var materialIds = initTable[pointer, int]()

  proc materialIndex(mat: Material): int =
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

  proc addMeshForNode(n: Node): int =
    if n.points.len == 0:
      return -1

    var attributes = newJObject()

    if n.points.len > 0:
      var payload = newString(n.points.len * 12)
      for i, p in n.points:
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
        n.points.len,
        0
      )
      attributes["POSITION"] = newJInt(acc)

    if n.normals.len == n.points.len and n.normals.len > 0:
      var payload = newString(n.normals.len * 12)
      for i, p in n.normals:
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
        n.normals.len,
        0
      )
      attributes["NORMAL"] = newJInt(acc)

    if n.uvs.len == n.points.len and n.uvs.len > 0:
      var payload = newString(n.uvs.len * 8)
      for i, p in n.uvs:
        payload.writeFloat32(i * 8 + 0, p.x)
        payload.writeFloat32(i * 8 + 4, p.y)
      let acc = addAccessor(
        accessors,
        bufferViews,
        data,
        payload,
        atVEC2,
        cGL_FLOAT,
        n.uvs.len,
        0
      )
      attributes["TEXCOORD_0"] = newJInt(acc)

    if n.colors.len == n.points.len and n.colors.len > 0:
      var payload = newString(n.colors.len * 4)
      for i, c in n.colors:
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
        n.colors.len,
        0
      )
      attributes["COLOR_0"] = newJInt(acc)

    var indicesAcc = -1
    if n.indices16.len > 0:
      var payload = newString(n.indices16.len * 2)
      for i, idxVal in n.indices16:
        payload.writeUint16AtLe(i * 2, idxVal)
      indicesAcc = addAccessor(
        accessors,
        bufferViews,
        data,
        payload,
        atSCALAR,
        cGL_UNSIGNED_SHORT,
        n.indices16.len,
        0
      )
    elif n.indices32.len > 0:
      var payload = newString(n.indices32.len * 4)
      for i, idxVal in n.indices32:
        payload.writeUint32AtLe(i * 4, idxVal)
      indicesAcc = addAccessor(
        accessors,
        bufferViews,
        data,
        payload,
        atSCALAR,
        GL_UNSIGNED_INT,
        n.indices32.len,
        0
      )

    var prim = newJObject()
    prim["attributes"] = attributes
    if indicesAcc >= 0:
      prim["indices"] = newJInt(indicesAcc)
    prim["mode"] = newJInt(GL_TRIANGLES.int)
    let matIdx = materialIndex(n.material)
    if matIdx >= 0:
      prim["material"] = newJInt(matIdx)

    var meshObj = newJObject()
    meshObj["name"] = newJString(n.name)
    meshObj["primitives"] = newJArray()
    meshObj["primitives"].add(prim)
    meshes.add(meshObj)
    meshes.len - 1

  proc walk(n: Node): int =
    var nodeObj = newJObject()
    nodeObj["name"] = newJString(n.name)
    nodeObj["translation"] = %*[n.pos.x, n.pos.y, n.pos.z]
    nodeObj["rotation"] = %*[n.rot.x, n.rot.y, n.rot.z, n.rot.w]
    nodeObj["scale"] = %*[n.scale.x, n.scale.y, n.scale.z]

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
