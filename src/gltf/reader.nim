import
  std/[base64, json, os, strformat, strutils],
  chroma, flatty/binny, opengl, pixie, vmath, webby,
  common, models

export common

proc loadPrimitive(
  n: Node,
  mesh: Mesh,
  primitiveIndex: int,
  primitives: seq[Primitive],
  accessors: seq[Accessor],
  bufferViews: seq[BufferView],
  buffers: seq[string],
  images: seq[Image],
  textures: seq[Texture],
  materials: seq[InnerMaterial]
) =
  ## Loads a primitive into a node.
  let primitive = primitives[primitiveIndex]
  n.material = Material()
  if primitive.material >= 0:
    let material = materials[primitive.material]

    let pbr = material.pbrMetallicRoughness
    if pbr.baseColorTexture.index >= 0:
      n.material.baseColor =
        images[textures[pbr.baseColorTexture.index].source]
    else:
      n.material.baseColor = newImage(1, 1)
      n.material.baseColor.fill(rgbx(255, 255, 255, 255))
    n.material.baseColorFactor = pbr.baseColorFactor

    if pbr.metallicRoughnessTexture.index >= 0:
      n.material.metallicRoughness =
        images[textures[pbr.metallicRoughnessTexture.index].source]
    else:
      n.material.metallicRoughness = newImage(1, 1)
      n.material.metallicRoughness.fill(rgbx(255, 255, 255, 255))
    n.material.metallicFactor = pbr.metallicFactor
    n.material.roughnessFactor = pbr.roughnessFactor

    if material.normalTexture.index >= 0:
      n.material.normal = images[textures[material.normalTexture.index].source]
      n.material.hasNormalTexture = true
      n.material.normalScale = material.normalTexture.scale
    else:
      n.material.normal = newImage(1, 1)
      n.material.normal.fill(rgbx(128, 128, 255, 255))
      n.material.hasNormalTexture = false
      n.material.normalScale = 1.0

    if material.occlusionTexture.index >= 0:
      n.material.occlusion =
        images[textures[material.occlusionTexture.index].source]
    else:
      n.material.occlusion = newImage(1, 1)
      n.material.occlusion.fill(rgbx(255, 255, 255, 255))
    n.material.occlusionStrength = material.occlusionTexture.strength

    if material.emissiveTexture.index >= 0:
      n.material.emissive =
        images[textures[material.emissiveTexture.index].source]
    else:
      n.material.emissive = newImage(1, 1)
      n.material.emissive.fill(rgbx(255, 255, 255, 255))
    n.material.emissiveFactor = material.emissiveFactor

    case material.alphaMode
    of "OPAQUE":
      n.material.alphaMode = OpaqueAlphaMode
      n.material.alphaCutoff = -1.0
    of "MASK":
      n.material.alphaMode = MaskAlphaMode
      n.material.alphaCutoff = material.alphaCutoff
    of "BLEND":
      n.material.alphaMode = BlendAlphaMode
      n.material.alphaCutoff = -1.0
    else:
      raise newException(Exception, &"Invalid alpha mode {material.alphaMode}")

    n.material.doubleSided = material.doubleSided

  if primitive.indices >= 0:
    let
      accessor = accessors[primitive.indices]
      bufferView = bufferViews[accessor.bufferView]
      buffer = buffers[bufferView.buffer]
      start = bufferView.byteOffset + accessor.byteOffset
    if accessor.componentType == GL_UNSIGNED_BYTE:
      assertRaise accessor.kind == atSCALAR, "Unsupported index kind"
      assertRaise bufferView.byteStride == 0, "Unsupported index byteStride"
      n.indices16.setLen(accessor.count)
      for i in 0 ..< accessor.count:
        n.indices16[i] = buffer[start + i].uint8
    elif accessor.componentType == cGL_UNSIGNED_SHORT:
      assertRaise accessor.kind == atSCALAR, "Unsupported index kind"
      assertRaise bufferView.byteStride == 0, "Unsupported index byteStride"
      n.indices16.setLen(accessor.count)
      copyMem(n.indices16[0].addr, buffer[start].addr, accessor.count * 2)
    elif accessor.componentType == GL_UNSIGNED_INT:
      assertRaise accessor.kind == atSCALAR, "Unsupported index kind"
      assertRaise bufferView.byteStride == 0, "Unsupported index byteStride"
      n.indices32.setLen(accessor.count)
      copyMem(n.indices32[0].addr, buffer[start].addr, accessor.count * 4)
    else:
      raise newException(
        Exception,
        "Invalid index component type: " & $accessor.componentType.int
      )

  if primitive.attributes.position >= 0:
    let
      accessor = accessors[primitive.attributes.position]
      bufferView = bufferViews[accessor.bufferView]
      buffer = buffers[bufferView.buffer]
      start = bufferView.byteOffset + accessor.byteOffset
    if accessor.componentType == cGL_FLOAT:
      assertRaise accessor.kind == atVEC3, "Unsupported position kind"
      n.points.setLen(accessor.count)
      if bufferView.byteStride == 0 or bufferView.byteStride == 12:
        copyMem(n.points[0].addr, buffer[start].addr, accessor.count * 12)
      else:
        let stride = bufferView.byteStride
        for i in 0 ..< accessor.count:
          n.points[i] = vec3(
            buffer.readFloat32(start + i * stride),
            buffer.readFloat32(start + i * stride + 4),
            buffer.readFloat32(start + i * stride + 8)
          )
    elif accessor.componentType == GL_UNSIGNED_SHORT:
      assertRaise accessor.kind == atVEC3, "Unsupported position kind"
      n.points.setLen(accessor.count)
      var stride = bufferView.byteStride
      if stride == 0:
        stride = 6
      for i in 0 ..< accessor.count:
        n.points[i] = vec3(
          float32 buffer.readUint16(start + i * stride),
          float32 buffer.readUint16(start + i * stride + 2),
          float32 buffer.readUint16(start + i * stride + 4)
        )
    elif accessor.componentType == GL_UNSIGNED_INT:
      assertRaise accessor.kind == atVEC3, "Unsupported position kind"
      assertRaise bufferView.byteStride == 0, "Unsupported position byteStride"
      n.points.setLen(accessor.count)
      var stride = bufferView.byteStride
      if stride == 0:
        stride = 12
      for i in 0 ..< accessor.count:
        n.points[i] = vec3(
          float32 buffer.readUint32(start + i * stride),
          float32 buffer.readUint32(start + i * stride + 4),
          float32 buffer.readUint32(start + i * stride + 8)
        )
    else:
      raise newException(
        Exception,
        "Invalid position component type: " & $accessor.componentType.int
      )

  if primitive.attributes.normal >= 0:
    let
      accessor = accessors[primitive.attributes.normal]
      bufferView = bufferViews[accessor.bufferView]
      buffer = buffers[bufferView.buffer]
      start = bufferView.byteOffset + accessor.byteOffset
    assertRaise accessor.componentType == cGL_FLOAT,
      "Unsupported normal componentType"
    assertRaise accessor.kind == atVEC3, "Unsupported normal kind"
    n.normals.setLen(accessor.count)
    if bufferView.byteStride == 0 or bufferView.byteStride == 12:
      copyMem(n.normals[0].addr, buffer[start].addr, accessor.count * 12)
    else:
      let stride = bufferView.byteStride
      for i in 0 ..< accessor.count:
        n.normals[i] = vec3(
          buffer.readFloat32(start + i * stride),
          buffer.readFloat32(start + i * stride + 4),
          buffer.readFloat32(start + i * stride + 8)
        )

  if primitive.attributes.color0 >= 0:
    let
      accessor = accessors[primitive.attributes.color0]
      bufferView = bufferViews[accessor.bufferView]
      buffer = buffers[bufferView.buffer]
      start = bufferView.byteOffset + accessor.byteOffset
    if accessor.kind == atVEC4:
      if accessor.componentType == cGL_FLOAT:
        var stride = bufferView.byteStride
        if stride == 0:
          stride = 16
        for i in 0 ..< accessor.count:
          n.colors.add(rgba(
            (buffer.readFloat32(start + i * stride) * 255).uint8,
            (buffer.readFloat32(start + i * stride + 4) * 255).uint8,
            (buffer.readFloat32(start + i * stride + 8) * 255).uint8,
            (buffer.readFloat32(start + i * stride + 12) * 255).uint8
          ).rgbx)
      elif accessor.componentType == GL_UNSIGNED_BYTE:
        n.colors.setLen(accessor.count)
        if bufferView.byteStride == 0 or bufferView.byteStride == 4:
          copyMem(n.colors[0].addr, buffer[start].addr, accessor.count * 4)
        else:
          let stride = bufferView.byteStride
          for i in 0 ..< accessor.count:
            n.colors[i] = rgbx(
              buffer.readUint8(start + i * stride),
              buffer.readUint8(start + i * stride + 1),
              buffer.readUint8(start + i * stride + 2),
              buffer.readUint8(start + i * stride + 3)
            )
      else:
        raise newException(
          Exception,
          "Invalid color component type: " & $accessor.componentType.int
        )
    elif accessor.kind == atVEC3:
      if accessor.componentType == cGL_FLOAT:
        var stride = bufferView.byteStride
        if stride == 0:
          stride = 12
        for i in 0 ..< accessor.count:
          n.colors.add(rgbx(
            (buffer.readFloat32(start + i * stride) * 255).uint8,
            (buffer.readFloat32(start + i * stride + 4) * 255).uint8,
            (buffer.readFloat32(start + i * stride + 8) * 255).uint8,
            255
          ))
      elif accessor.componentType == GL_UNSIGNED_BYTE:
        n.colors.setLen(accessor.count)
        var stride = bufferView.byteStride
        if stride == 0:
          stride = 3
        for i in 0 ..< accessor.count:
          n.colors[i] = rgbx(
            buffer.readUint8(start + i * stride),
            buffer.readUint8(start + i * stride + 1),
            buffer.readUint8(start + i * stride + 2),
            255
          )
      elif accessor.componentType == GL_UNSIGNED_SHORT:
        n.colors.setLen(accessor.count)
        var stride = bufferView.byteStride
        if stride == 0:
          stride = 6
        for i in 0 ..< accessor.count:
          let base = start + i * stride
          let r = buffer.readUint16(base)
          let g = buffer.readUint16(base + 2)
          let b = buffer.readUint16(base + 4)
          n.colors[i] = rgbx(
            (r div 257).uint8,
            (g div 257).uint8,
            (b div 257).uint8,
            255
          )
    else:
      raise newException(
        Exception,
        "Invalid color kind: " & $accessor.kind
      )

  if primitive.attributes.texcoord0 >= 0:
    let
      accessor = accessors[primitive.attributes.texcoord0]
      bufferView = bufferViews[accessor.bufferView]
      buffer = buffers[bufferView.buffer]
      start = bufferView.byteOffset + accessor.byteOffset
    assertRaise accessor.componentType == cGL_FLOAT,
      "Unsupported texcoord componentType"
    assertRaise accessor.kind == atVEC2, "Unsupported texcoord kind"
    n.uvs.setLen(accessor.count)
    if bufferView.byteStride == 0 or bufferView.byteStride == 8:
      copyMem(n.uvs[0].addr, buffer[start].addr, accessor.count * 8)
    else:
      let stride = bufferView.byteStride
      for i in 0 ..< accessor.count:
        n.uvs[i] = vec2(
          buffer.readFloat32(start + i * stride),
          buffer.readFloat32(start + i * stride + 4)
        )

  if primitive.attributes.normal >= 0 and primitive.attributes.texcoord0 >= 0:
    n.tangents.setLen(n.normals.len)

    template computeTangents(idx: untyped) =
      var counts = newSeq[int](n.normals.len)
      var tmpTangents = newSeq[Vec3](n.normals.len)
      for i in 0 ..< idx.len div 3:
        let
          i0 = idx[i * 3].int
          i1 = idx[i * 3 + 1].int
          i2 = idx[i * 3 + 2].int
          v0 = n.points[i0]
          v1 = n.points[i1]
          v2 = n.points[i2]
          uv0 = n.uvs[i0]
          uv1 = n.uvs[i1]
          uv2 = n.uvs[i2]
          edge1 = v1 - v0
          edge2 = v2 - v0
          deltaUv1 = uv1 - uv0
          deltaUv2 = uv2 - uv0
          f = 1.0 / (deltaUv1.x * deltaUv2.y - deltaUv2.x * deltaUv1.y)
          tangent = vec3(
            f * (deltaUv2.y * edge1.x - deltaUv1.y * edge2.x),
            f * (deltaUv2.y * edge1.y - deltaUv1.y * edge2.y),
            f * (deltaUv2.y * edge1.z - deltaUv1.y * edge2.z)
          )
        tmpTangents[i0] += tangent
        tmpTangents[i1] += tangent
        tmpTangents[i2] += tangent
        counts[i0] += 1
        counts[i1] += 1
        counts[i2] += 1

      for i in 0 ..< n.tangents.len:
        if counts[i] > 0:
          let tangent = normalize(tmpTangents[i] / counts[i].float32)
          let handedness = 1.0
          n.tangents[i].x = tangent.x
          n.tangents[i].y = tangent.y
          n.tangents[i].z = tangent.z
          n.tangents[i].w = handedness

    if n.indices16.len > 0:
      computeTangents(n.indices16)
    if n.indices32.len > 0:
      computeTangents(n.indices32)

proc loadModelJson*(
  jsonRoot: JsonNode,
  modelDir: string,
  externalBuffers: seq[string]
): Node =
  ## Loads a 3D model from a parsed glTF json tree.
  if "extensionsRequired" in jsonRoot:
    for extension in jsonRoot["extensionsRequired"]:
      case extension.getStr()
      else:
        raise newException(
          Exception,
          &"Unsupported extension required: {extension}"
        )

  var buffers: seq[string]
  var bufferIndex = 0
  for entry in jsonRoot["buffers"]:
    var data: string
    if "uri" in entry:
      let uri = entry["uri"].getStr()
      if uri.startsWith("data:application/"):
        data = decode(uri.split(',')[1])
      else:
        data = readFile(joinPath(modelDir, uri))
    else:
      data = externalBuffers[bufferIndex][0 ..< entry["byteLength"].getInt()]
      inc bufferIndex
    assert data.len == entry["byteLength"].getInt()
    buffers.add(data)

  var bufferViews: seq[BufferView]
  for entry in jsonRoot["bufferViews"]:
    var bufferView = BufferView()
    bufferView.buffer = entry["buffer"].getInt()
    bufferView.byteOffset = entry{"byteOffset"}.getInt()
    bufferView.byteLength = entry["byteLength"].getInt()
    bufferView.byteStride = entry{"byteStride"}.getInt()

    if "target" in entry:
      let target = entry["target"].getInt()
      if target notin @[GL_ARRAY_BUFFER.int, GL_ELEMENT_ARRAY_BUFFER.int]:
        raise newException(Exception, &"Invalid bufferView target {target}")

    bufferViews.add(bufferView)

  var accessors: seq[Accessor]
  for entry in jsonRoot["accessors"]:
    var accessor = Accessor()
    assertRaise "bufferView" in entry, "Missing bufferView"
    accessor.bufferView = entry["bufferView"].getInt()
    if "byteOffset" in entry:
      accessor.byteOffset = entry{"byteOffset"}.getInt()
    accessor.count = entry["count"].getInt()
    accessor.componentType = entry["componentType"].getInt().GLenum
    let accessorKind = entry["type"].getStr()
    case accessorKind
    of "SCALAR":
      accessor.kind = atSCALAR
    of "VEC2":
      accessor.kind = atVEC2
    of "VEC3":
      accessor.kind = atVEC3
    of "VEC4":
      accessor.kind = atVEC4
    of "MAT2":
      accessor.kind = atMAT2
    of "MAT3":
      accessor.kind = atMAT3
    of "MAT4":
      accessor.kind = atMAT4
    else:
      raise newException(
        Exception,
        &"Invalid accessor type {accessorKind}"
      )
    accessors.add(accessor)

  var textures: seq[Texture]
  if "textures" in jsonRoot:
    for entry in jsonRoot["textures"]:
      var texture = Texture()
      texture.source = entry["source"].getInt()
      if "sampler" in entry:
        texture.sampler = entry["sampler"].getInt()
      else:
        texture.sampler = -1
      textures.add(texture)

  var images: seq[Image]
  if "images" in jsonRoot:
    for entry in jsonRoot["images"]:
      var image: Image
      if "uri" in entry:
        let uri = entry["uri"].getStr().decodeUriComponent()
        if uri.startsWith("data:image/png") or
           uri.startsWith("data:image/jpeg"):
          image = decodeImage(decode(uri.split(',')[1]))
        elif uri.endsWith(".png") or
             uri.endsWith(".jpg") or
             uri.endsWith(".jpeg"):
          image = readImage(joinPath(modelDir, uri))
        else:
          raise newException(Exception, &"Unsupported file extension {uri}")
      elif "bufferView" in entry:
        let
          bufferViewIndex = entry["bufferView"].getInt()
          bv = bufferViews[bufferViewIndex]
          ib = buffers[bv.buffer]
          imageData = ib[bv.byteOffset ..< bv.byteOffset + bv.byteLength]
        image = decodeImage(imageData)
      else:
        raise newException(Exception, "Unsupported image type")
      images.add(image)

  var samplers: seq[Sampler]
  if "samplers" in jsonRoot:
    for entry in jsonRoot["samplers"]:
      var sampler = Sampler()
      if "magFilter" in entry:
        sampler.magFilter = entry["magFilter"].getInt().GLint
      else:
        sampler.magFilter = GL_LINEAR
      if "minFilter" in entry:
        sampler.minFilter = entry["minFilter"].getInt().GLint
      else:
        sampler.minFilter = GL_LINEAR_MIPMAP_LINEAR
      if "wrapS" in entry:
        sampler.wrapS = entry["wrapS"].getInt().GLint
      else:
        sampler.wrapS = GL_REPEAT
      if "wrapT" in entry:
        sampler.wrapT = entry["wrapT"].getInt().GLint
      else:
        sampler.wrapT = GL_REPEAT
      samplers.add(sampler)

  var materials: seq[InnerMaterial]
  if "materials" in jsonRoot:
    for entry in jsonRoot["materials"]:
      var material = InnerMaterial()
      if "name" in entry:
        material.name = entry["name"].getStr()

      if "pbrMetallicRoughness" in entry:
        let pbrMetallicRoughness = entry["pbrMetallicRoughness"]
        if "baseColorTexture" in pbrMetallicRoughness:
          let baseColorTexture = pbrMetallicRoughness["baseColorTexture"]
          material.pbrMetallicRoughness.baseColorTexture.index =
            baseColorTexture["index"].getInt()
        else:
          material.pbrMetallicRoughness.baseColorTexture.index = -1

        if "baseColorFactor" in pbrMetallicRoughness:
          let
            r = pbrMetallicRoughness["baseColorFactor"][0].getFloat()
            g = pbrMetallicRoughness["baseColorFactor"][1].getFloat()
            b = pbrMetallicRoughness["baseColorFactor"][2].getFloat()
            a = pbrMetallicRoughness["baseColorFactor"][3].getFloat()
          material.pbrMetallicRoughness.baseColorFactor = color(r, g, b, a)
        else:
          material.pbrMetallicRoughness.baseColorFactor = color(1, 1, 1, 1)

        if "metallicRoughnessTexture" in pbrMetallicRoughness:
          let metallicRoughnessTexture =
            pbrMetallicRoughness["metallicRoughnessTexture"]
          material.pbrMetallicRoughness.metallicRoughnessTexture.index =
            metallicRoughnessTexture["index"].getInt()
        else:
          material.pbrMetallicRoughness.metallicRoughnessTexture.index = -1

        if "metallicFactor" in pbrMetallicRoughness:
          material.pbrMetallicRoughness.metallicFactor =
            pbrMetallicRoughness["metallicFactor"].getFloat().float32
        else:
          material.pbrMetallicRoughness.metallicFactor = 1.0

        if "roughnessFactor" in pbrMetallicRoughness:
          material.pbrMetallicRoughness.roughnessFactor =
            pbrMetallicRoughness["roughnessFactor"].getFloat().float32
        else:
          material.pbrMetallicRoughness.roughnessFactor = 1.0
      else:
        material.pbrMetallicRoughness.baseColorTexture.index = -1
        material.pbrMetallicRoughness.metallicRoughnessTexture.index = -1
        material.pbrMetallicRoughness.baseColorFactor = color(1, 1, 1, 1)
        material.pbrMetallicRoughness.metallicFactor = 1.0
        material.pbrMetallicRoughness.roughnessFactor = 1.0

      if "normalTexture" in entry:
        let normalTexture = entry["normalTexture"]
        material.normalTexture.index = normalTexture["index"].getInt()
        if "scale" in normalTexture:
          material.normalTexture.scale =
            normalTexture["scale"].getFloat().float32
        else:
          material.normalTexture.scale = 1.0
      else:
        material.normalTexture.index = -1
        material.normalTexture.scale = 1.0

      if "occlusionTexture" in entry:
        let occlusionTexture = entry["occlusionTexture"]
        material.occlusionTexture.index = occlusionTexture["index"].getInt()
        if "strength" in occlusionTexture:
          material.occlusionTexture.strength =
            occlusionTexture["strength"].getFloat().float32
        else:
          material.occlusionTexture.strength = 1.0
      else:
        material.occlusionTexture.index = -1
        material.occlusionTexture.strength = 1.0

      if "emissiveTexture" in entry:
        let emissiveTexture = entry["emissiveTexture"]
        material.emissiveTexture.index = emissiveTexture["index"].getInt()
      else:
        material.emissiveTexture.index = -1

      if "emissiveFactor" in entry:
        let
          r = entry["emissiveFactor"][0].getFloat()
          g = entry["emissiveFactor"][1].getFloat()
          b = entry["emissiveFactor"][2].getFloat()
        material.emissiveFactor = color(r, g, b, 1)
      else:
        material.emissiveFactor = color(0, 0, 0, 1)

      if "alphaMode" in entry:
        material.alphaMode = entry["alphaMode"].getStr()
      else:
        material.alphaMode = "OPAQUE"

      if "alphaCutoff" in entry:
        material.alphaCutoff = entry["alphaCutoff"].getFloat().float32
      else:
        material.alphaCutoff = 0.5

      if "doubleSided" in entry:
        material.doubleSided = entry["doubleSided"].getBool()
      else:
        material.doubleSided = false

      materials.add(material)

  var
    meshes: seq[Mesh]
    primitives: seq[Primitive]
  for entry in jsonRoot["meshes"]:
    var mesh = Mesh()
    if "name" in entry:
      mesh.name = entry["name"].getStr()
    mesh.primitives = @[]
    for primitive in entry["primitives"]:
      var prim = Primitive()
      assert "attributes" in primitive
      let attributes = primitive["attributes"]
      if "POSITION" in attributes:
        prim.attributes.position = attributes["POSITION"].getInt()
      else:
        prim.attributes.position = -1
      if "NORMAL" in attributes:
        prim.attributes.normal = attributes["NORMAL"].getInt()
      else:
        prim.attributes.normal = -1
      if "COLOR_0" in attributes:
        prim.attributes.color0 = attributes["COLOR_0"].getInt()
      else:
        prim.attributes.color0 = -1
      if "TEXCOORD_0" in attributes:
        prim.attributes.texcoord0 = attributes["TEXCOORD_0"].getInt()
      else:
        prim.attributes.texcoord0 = -1
      if "indices" in primitive:
        prim.indices = primitive["indices"].getInt()
      else:
        prim.indices = -1
      if "material" in primitive:
        prim.material = primitive["material"].getInt()
      else:
        prim.material = -1
      if "mode" in primitive:
        prim.mode = primitive["mode"].getInt().GLenum
      else:
        prim.mode = GL_TRIANGLES
      primitives.add(prim)
      mesh.primitives.add(primitives.len - 1)
    meshes.add(mesh)

  var
    nodes: seq[Node]
    nodeMeshes: seq[int]
    nodeChildren: seq[seq[int]]
  for entry in jsonRoot["nodes"]:
    var node = Node()
    if "name" in entry:
      node.name = entry["name"].getStr()
    else:
      node.name = "node_" & $nodes.len
    node.visible = true

    var meshId = -1
    if "mesh" in entry:
      meshId = entry["mesh"].getInt()

    if "translation" in entry:
      let translation = entry["translation"]
      node.pos = vec3(
        translation[0].getFloat().float32,
        translation[1].getFloat().float32,
        translation[2].getFloat().float32
      )
    else:
      node.pos = vec3(0, 0, 0)

    if "rotation" in entry:
      let rotation = entry["rotation"]
      node.rot = quat(
        rotation[0].getFloat().float32,
        rotation[1].getFloat().float32,
        rotation[2].getFloat().float32,
        rotation[3].getFloat().float32
      )
    else:
      node.rot = quat(0, 0, 0, 1)

    if "scale" in entry and entry["scale"].len >= 3:
      let scale = entry["scale"]
      node.scale = vec3(
        scale[0].getFloat().float32,
        scale[1].getFloat().float32,
        scale[2].getFloat().float32
      )
    else:
      node.scale = vec3(1, 1, 1)

    node.basePos = node.pos
    node.baseRot = node.rot
    node.baseScale = node.scale

    var children: seq[int]
    if "children" in entry:
      for child in entry["children"]:
        children.add(child.getInt())

    nodes.add(node)
    nodeMeshes.add(meshId)
    nodeChildren.add(children)

  var clips: seq[AnimationClip]
  if "animations" in jsonRoot:
    for animEntry in jsonRoot["animations"]:
      var clip = AnimationClip()
      if "name" in animEntry:
        clip.name = animEntry["name"].getStr()
      else:
        clip.name = "anim_" & $clips.len

      type
        AnimSampler = object
          input, output: int
          interpolation: string

      var samplers: seq[AnimSampler]
      if "samplers" in animEntry:
        for s in animEntry["samplers"]:
          var sampler = AnimSampler()
          sampler.input = s["input"].getInt()
          sampler.output = s["output"].getInt()
          if "interpolation" in s:
            sampler.interpolation = s["interpolation"].getStr()
          else:
            sampler.interpolation = "LINEAR"
          samplers.add(sampler)

      if "channels" in animEntry:
        for ch in animEntry["channels"]:
          if not ("sampler" in ch):
            continue
          let samplerIdx = ch["sampler"].getInt()
          if samplerIdx < 0 or samplerIdx >= samplers.len:
            continue
          let sampler = samplers[samplerIdx]
          if not ("target" in ch):
            continue
          let target = ch["target"]
          if not ("node" in target) or not ("path" in target):
            continue
          let nodeIdx = target["node"].getInt()
          if nodeIdx < 0 or nodeIdx >= nodes.len:
            continue
          let pathStr = target["path"].getStr()

          var path: AnimPath
          var isPath = true
          case pathStr
          of "translation":
            path = AnimTranslation
          of "rotation":
            path = AnimRotation
          of "scale":
            path = AnimScale
          else:
            isPath = false

          if not isPath:
            echo &"[gltf] skipping animation path {pathStr}"
            continue

          let times =
            readAccessorFloats(
              sampler.input,
              accessors,
              bufferViews,
              buffers
            )
          if times.len == 0:
            echo "[gltf] animation sampler missing times"
            continue

          var channel = AnimationChannel()
          channel.target = nodes[nodeIdx]
          channel.path = path
          channel.times = times

          case path
          of AnimTranslation, AnimScale:
            channel.valuesVec3 =
              readAccessorVec3(
                sampler.output,
                accessors,
                bufferViews,
                buffers
              )
          of AnimRotation:
            channel.valuesQuat =
              readAccessorQuat(
                sampler.output,
                accessors,
                bufferViews,
                buffers
              )

          if channel.times.len == 0:
            continue
          if channel.times.len != channel.valuesVec3.len and
             channel.times.len != channel.valuesQuat.len:
            echo "[gltf] animation sampler length mismatch"
            continue

          if channel.times.len > 0:
            clip.duration = max(clip.duration, channel.times[^1])
          clip.channels.add(channel)

      if clip.channels.len > 0:
        clips.add(clip)

  var scenes: seq[Mesh]
  var sceneId = 0
  if "scene" in jsonRoot:
    sceneId = jsonRoot["scene"].getInt()
  for entry in jsonRoot["scenes"]:
    var scene = Mesh()
    if "name" in entry:
      scene.name = entry["name"].getStr()
    for n in entry["nodes"]:
      scene.primitives.add(n.getInt())
    scenes.add(scene)

  proc processNode(nodeId: int): Node =
    var n = nodes[nodeId]
    let meshId = nodeMeshes[nodeId]
    if meshId >= 0:
      let mesh = meshes[meshId]
      if mesh.primitives.len == 1:
        loadPrimitive(
          n,
          mesh,
          mesh.primitives[0],
          primitives,
          accessors,
          bufferViews,
          buffers,
          images,
          textures,
          materials
        )
      else:
        for primitiveIndex in mesh.primitives:
          var child = Node()
          child.name = mesh.name
          child.visible = true
          child.pos = vec3(0, 0, 0)
          child.rot = quat(0, 0, 0, 1)
          child.scale = vec3(1, 1, 1)
          child.basePos = child.pos
          child.baseRot = child.rot
          child.baseScale = child.scale
          child.mat = n.mat
          loadPrimitive(
            child,
            mesh,
            primitiveIndex,
            primitives,
            accessors,
            bufferViews,
            buffers,
            images,
            textures,
            materials
          )
          n.nodes.add(child)

    for childId in nodeChildren[nodeId]:
      n.nodes.add(processNode(childId))

    n

  result = Node()
  result.visible = true
  result.name = "Root"
  result.pos = vec3(0, 0, 0)
  result.rot = quat(0, 0, 0, 1)
  result.scale = vec3(1, 1, 1)
  result.basePos = result.pos
  result.baseRot = result.rot
  result.baseScale = result.scale
  for nodeId in scenes[sceneId].primitives:
    result.nodes.add(processNode(nodeId))
  result.animations = clips
  result.currentClip = 0
  result.animTime = 0

proc loadModelJsonFile*(file: string): Node =
  ## Loads a 3D model from a json glTF file.
  let
    jsonRoot = parseJson(readFile(file))
    modelDir = splitPath(file)[0]
  loadModelJson(jsonRoot, modelDir, @[])

proc loadModelBinaryFile*(file: string): Node =
  ## Loads a 3D model from a binary glTF file.
  let
    modelDir = splitPath(file)[0]
    data = readFile(file)
    magic = data.readUint32(0)
    version = data.readUint32(4)
    length = data.readUint32(8)

  assertRaise magic == 0x46546C67, "Invalid magic, this is not a glTF file"
  assertRaise version == 2, "Invalid version, only glTF 2.0 is supported"
  assertRaise length.int == data.len, "Length mismatch, the file is corrupted"

  var
    i = 12
    jsonData: string
    buffers: seq[string]
  while i < data.len:
    var
      chunkLength = data.readUint32(i)
      chunkType = data.readUint32(i + 4)
      chunkData = data.readStr(i + 8, chunkLength.int)
      isJson = chunkType == 0x4E4F534A
    i += 8 + chunkLength.int
    if isJson:
      jsonData = chunkData
    else:
      buffers.add(chunkData)

  loadModelJson(parseJson(jsonData), modelDir, buffers)

proc loadModel*(file: string): Node =
  ## Loads a 3D model from a glTF file.
  if file.endsWith(".glb"):
    loadModelBinaryFile(file)
  else:
    loadModelJsonFile(file)

proc readGltfJsonFile*(file: string): GltfFile =
  ## Reads a glTF json file into a glTF file wrapper.
  GltfFile(
    path: file,
    root: loadModelJsonFile(file)
  )

proc readGltfBinaryFile*(file: string): GltfFile =
  ## Reads a binary glTF file into a glTF file wrapper.
  GltfFile(
    path: file,
    root: loadModelBinaryFile(file)
  )

proc readGltfFile*(file: string): GltfFile =
  ## Reads a glTF file into a glTF file wrapper.
  if file.endsWith(".glb"):
    readGltfBinaryFile(file)
  else:
    readGltfJsonFile(file)
