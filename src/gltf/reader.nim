import
  std/[base64, json, os, strformat, strutils],
  chroma, flatty/binny, opengl, pixie, vmath, webby,
  common, internal, models

export common

const SupportedExtensions = [
  "KHR_texture_transform",
  "KHR_materials_transmission",
  "KHR_node_visibility",
  "KHR_animation_pointer"
]

proc unsupportedUsedExtensions(jsonRoot: JsonNode): seq[string] =
  ## Returns used extensions we do not currently support.
  if "extensionsUsed" notin jsonRoot:
    return
  for extension in jsonRoot["extensionsUsed"]:
    let name = extension.getStr()
    if name notin SupportedExtensions and name notin result:
      result.add(name)

proc readFloat32(data: string, offset: int): float32 =
  ## Reads a float32 from a byte string.
  cast[ptr float32](data[offset].unsafeAddr)[]

proc readAccessorFloats(
  accessorIdx: int,
  accessors: seq[Accessor],
  bufferViews: seq[BufferView],
  buffers: seq[string]
): seq[float32] =
  ## Reads scalar accessor data as float32 values.
  let
    accessor = accessors[accessorIdx]
    view = bufferViews[accessor.bufferView]
    buffer = buffers[view.buffer]
    start = view.byteOffset + accessor.byteOffset
    elemSize =
      case accessor.componentType
      of cGL_FLOAT:
        4
      of GL_UNSIGNED_BYTE:
        1
      of cGL_UNSIGNED_SHORT:
        2
      of GL_UNSIGNED_INT:
        4
      else:
        0
    stride = if view.byteStride > 0: view.byteStride else: elemSize
  if accessor.kind != atSCALAR:
    raise newException(GltfError, "Unsupported scalar accessor kind")
  if elemSize == 0:
    raise newException(GltfError, "Unsupported scalar accessor component type")
  result.setLen(accessor.count)
  for i in 0 ..< accessor.count:
    let off = start + i * stride
    case accessor.componentType
    of cGL_FLOAT:
      result[i] = readFloat32(buffer, off)
    of GL_UNSIGNED_BYTE:
      result[i] = buffer.readUint8(off).float32
    of cGL_UNSIGNED_SHORT:
      result[i] = buffer.readUint16(off).float32
    of GL_UNSIGNED_INT:
      result[i] = buffer.readUint32(off).float32
    else:
      discard

proc readAccessorVec3(
  accessorIdx: int,
  accessors: seq[Accessor],
  bufferViews: seq[BufferView],
  buffers: seq[string]
): seq[Vec3] =
  ## Reads vec3 accessor data.
  let
    accessor = accessors[accessorIdx]
    view = bufferViews[accessor.bufferView]
    buffer = buffers[view.buffer]
    start = view.byteOffset + accessor.byteOffset
    stride = if view.byteStride > 0: view.byteStride else: 12
  result.setLen(accessor.count)
  for i in 0 ..< accessor.count:
    let off = start + i * stride
    result[i] = vec3(
      readFloat32(buffer, off),
      readFloat32(buffer, off + 4),
      readFloat32(buffer, off + 8)
    )

proc readAccessorQuat(
  accessorIdx: int,
  accessors: seq[Accessor],
  bufferViews: seq[BufferView],
  buffers: seq[string]
): seq[Quat] =
  ## Reads quaternion accessor data.
  let
    accessor = accessors[accessorIdx]
    view = bufferViews[accessor.bufferView]
    buffer = buffers[view.buffer]
    start = view.byteOffset + accessor.byteOffset
    stride = if view.byteStride > 0: view.byteStride else: 16
  result.setLen(accessor.count)
  for i in 0 ..< accessor.count:
    let off = start + i * stride
    result[i] = quat(
      readFloat32(buffer, off),
      readFloat32(buffer, off + 4),
      readFloat32(buffer, off + 8),
      readFloat32(buffer, off + 12)
    ).normalize()

proc assertRaise(test: bool, msg: string) =
  ## Raises an exception when a glTF invariant is not met.
  if not test:
    raise newException(GltfError, msg)

proc defaultMaterialTexture(): MaterialTexture =
  ## Returns a material texture with default transform values.
  MaterialTexture(
    index: -1,
    texCoord: 0,
    offset: vec2(0, 0),
    uvScale: vec2(1, 1),
    rotation: 0,
    scale: 1,
    strength: 1
  )

proc readTextureTransform(entry: JsonNode, texInfo: var MaterialTexture) =
  ## Reads core and KHR_texture_transform texture info.
  if "texCoord" in entry:
    texInfo.texCoord = entry["texCoord"].getInt()

  if "extensions" in entry and
    "KHR_texture_transform" in entry["extensions"]:
    let transform = entry["extensions"]["KHR_texture_transform"]
    if "offset" in transform:
      texInfo.offset = vec2(
        transform["offset"][0].getFloat().float32,
        transform["offset"][1].getFloat().float32
      )
    if "scale" in transform:
      texInfo.uvScale = vec2(
        transform["scale"][0].getFloat().float32,
        transform["scale"][1].getFloat().float32
      )
    if "rotation" in transform:
      texInfo.rotation = transform["rotation"].getFloat().float32
    if "texCoord" in transform:
      texInfo.texCoord = transform["texCoord"].getInt()

proc defaultRuntimeMaterial(): Material =
  ## Returns the glTF default material for runtime rendering.
  result = Material()
  result.baseColorSampler = defaultTextureSampler()
  result.metallicRoughnessSampler = defaultTextureSampler()
  result.normalSampler = defaultTextureSampler()
  result.occlusionSampler = defaultTextureSampler()
  result.emissiveSampler = defaultTextureSampler()

  result.baseColor = newImage(1, 1)
  result.baseColor.fill(rgbx(255, 255, 255, 255))
  result.baseColorFactor = color(1, 1, 1, 1)
  result.baseColorTransform = TextureTransform(
    texCoord: 0,
    offset: vec2(0, 0),
    scale: vec2(1, 1),
    rotation: 0
  )

  result.metallicRoughness = newImage(1, 1)
  result.metallicRoughness.fill(rgbx(255, 255, 255, 255))
  result.metallicFactor = 1.0
  result.roughnessFactor = 1.0
  result.metallicRoughnessTransform = TextureTransform(
    texCoord: 0,
    offset: vec2(0, 0),
    scale: vec2(1, 1),
    rotation: 0
  )

  result.normal = newImage(1, 1)
  result.normal.fill(rgbx(128, 128, 255, 255))
  result.hasNormalTexture = false
  result.normalScale = 1.0
  result.normalTransform = TextureTransform(
    texCoord: 0,
    offset: vec2(0, 0),
    scale: vec2(1, 1),
    rotation: 0
  )

  result.occlusion = newImage(1, 1)
  result.occlusion.fill(rgbx(255, 255, 255, 255))
  result.occlusionStrength = 1.0
  result.occlusionTransform = TextureTransform(
    texCoord: 0,
    offset: vec2(0, 0),
    scale: vec2(1, 1),
    rotation: 0
  )

  result.emissive = newImage(1, 1)
  result.emissive.fill(rgbx(255, 255, 255, 255))
  result.emissiveFactor = color(0, 0, 0, 1)
  result.emissiveTransform = TextureTransform(
    texCoord: 0,
    offset: vec2(0, 0),
    scale: vec2(1, 1),
    rotation: 0
  )

  result.alphaMode = OpaqueAlphaMode
  result.alphaCutoff = -1.0
  result.doubleSided = false
  result.transmissionFactor = 0.0

proc loadPrimitive(
  primitiveIndex: int,
  primitiveDefs: seq[PrimitiveInfo],
  accessors: seq[Accessor],
  bufferViews: seq[BufferView],
  buffers: seq[string],
  images: seq[Image],
  textures: seq[Texture],
  samplers: seq[Sampler],
  materials: seq[MaterialInfo]
): Primitive =
  ## Loads one glTF primitive into a runtime primitive.
  proc getTextureSampler(textureIndex: int): TextureSampler =
    result = defaultTextureSampler()
    if textureIndex < 0 or textureIndex >= textures.len:
      return
    let samplerIndex = textures[textureIndex].sampler
    if samplerIndex < 0 or samplerIndex >= samplers.len:
      return
    let sampler = samplers[samplerIndex]
    result.magFilter = sampler.magFilter
    result.minFilter = sampler.minFilter
    result.wrapS = sampler.wrapS
    result.wrapT = sampler.wrapT

  let primInfo = primitiveDefs[primitiveIndex]
  result = Primitive(mode: primInfo.mode)
  result.material = defaultRuntimeMaterial()
  if primInfo.material >= 0:
    let material = materials[primInfo.material]

    let pbr = material.pbrMetallicRoughness
    if pbr.baseColorTexture.index >= 0:
      result.material.baseColor =
        images[textures[pbr.baseColorTexture.index].source]
      result.material.baseColorSampler =
        getTextureSampler(pbr.baseColorTexture.index)
    else:
      result.material.baseColor = newImage(1, 1)
      result.material.baseColor.fill(rgbx(255, 255, 255, 255))
    result.material.baseColorTransform = TextureTransform(
      texCoord: pbr.baseColorTexture.texCoord,
      offset: pbr.baseColorTexture.offset,
      scale: pbr.baseColorTexture.uvScale,
      rotation: pbr.baseColorTexture.rotation
    )
    result.material.baseColorFactor = pbr.baseColorFactor

    if pbr.metallicRoughnessTexture.index >= 0:
      result.material.metallicRoughness =
        images[textures[pbr.metallicRoughnessTexture.index].source]
      result.material.metallicRoughnessSampler =
        getTextureSampler(pbr.metallicRoughnessTexture.index)
    else:
      result.material.metallicRoughness = newImage(1, 1)
      result.material.metallicRoughness.fill(rgbx(255, 255, 255, 255))
    result.material.metallicRoughnessTransform = TextureTransform(
      texCoord: pbr.metallicRoughnessTexture.texCoord,
      offset: pbr.metallicRoughnessTexture.offset,
      scale: pbr.metallicRoughnessTexture.uvScale,
      rotation: pbr.metallicRoughnessTexture.rotation
    )
    result.material.metallicFactor = pbr.metallicFactor
    result.material.roughnessFactor = pbr.roughnessFactor

    if material.normalTexture.index >= 0:
      result.material.normal =
        images[textures[material.normalTexture.index].source]
      result.material.normalSampler =
        getTextureSampler(material.normalTexture.index)
      result.material.hasNormalTexture = true
      result.material.normalScale = material.normalTexture.scale
    else:
      result.material.normal = newImage(1, 1)
      result.material.normal.fill(rgbx(128, 128, 255, 255))
      result.material.hasNormalTexture = false
      result.material.normalScale = 1.0
    result.material.normalTransform = TextureTransform(
      texCoord: material.normalTexture.texCoord,
      offset: material.normalTexture.offset,
      scale: material.normalTexture.uvScale,
      rotation: material.normalTexture.rotation
    )

    if material.occlusionTexture.index >= 0:
      result.material.occlusion =
        images[textures[material.occlusionTexture.index].source]
      result.material.occlusionSampler =
        getTextureSampler(material.occlusionTexture.index)
    else:
      result.material.occlusion = newImage(1, 1)
      result.material.occlusion.fill(rgbx(255, 255, 255, 255))
    result.material.occlusionTransform = TextureTransform(
      texCoord: material.occlusionTexture.texCoord,
      offset: material.occlusionTexture.offset,
      scale: material.occlusionTexture.uvScale,
      rotation: material.occlusionTexture.rotation
    )
    result.material.occlusionStrength = material.occlusionTexture.strength

    if material.emissiveTexture.index >= 0:
      result.material.emissive =
        images[textures[material.emissiveTexture.index].source]
      result.material.emissiveSampler =
        getTextureSampler(material.emissiveTexture.index)
    else:
      result.material.emissive = newImage(1, 1)
      result.material.emissive.fill(rgbx(255, 255, 255, 255))
    result.material.emissiveTransform = TextureTransform(
      texCoord: material.emissiveTexture.texCoord,
      offset: material.emissiveTexture.offset,
      scale: material.emissiveTexture.uvScale,
      rotation: material.emissiveTexture.rotation
    )
    result.material.emissiveFactor = material.emissiveFactor
    result.material.transmissionFactor = material.transmissionFactor

    case material.alphaMode
    of "OPAQUE":
      if result.material.transmissionFactor > 0:
        result.material.alphaMode = BlendAlphaMode
      else:
        result.material.alphaMode = OpaqueAlphaMode
      result.material.alphaCutoff = -1.0
    of "MASK":
      result.material.alphaMode = MaskAlphaMode
      result.material.alphaCutoff = material.alphaCutoff
    of "BLEND":
      result.material.alphaMode = BlendAlphaMode
      result.material.alphaCutoff = -1.0
    else:
      raise newException(GltfError, &"Invalid alpha mode {material.alphaMode}")

    result.material.doubleSided = material.doubleSided

  if primInfo.indices >= 0:
    let
      accessor = accessors[primInfo.indices]
      bufferView = bufferViews[accessor.bufferView]
      buffer = buffers[bufferView.buffer]
      start = bufferView.byteOffset + accessor.byteOffset
    if accessor.componentType == GL_UNSIGNED_BYTE:
      assertRaise accessor.kind == atSCALAR, "Unsupported index kind"
      assertRaise bufferView.byteStride == 0, "Unsupported index byteStride"
      result.indices16.setLen(accessor.count)
      for i in 0 ..< accessor.count:
        result.indices16[i] = buffer[start + i].uint8
    elif accessor.componentType == cGL_UNSIGNED_SHORT:
      assertRaise accessor.kind == atSCALAR, "Unsupported index kind"
      assertRaise bufferView.byteStride == 0, "Unsupported index byteStride"
      result.indices16.setLen(accessor.count)
      copyMem(result.indices16[0].addr, buffer[start].addr, accessor.count * 2)
    elif accessor.componentType == GL_UNSIGNED_INT:
      assertRaise accessor.kind == atSCALAR, "Unsupported index kind"
      assertRaise bufferView.byteStride == 0, "Unsupported index byteStride"
      result.indices32.setLen(accessor.count)
      copyMem(result.indices32[0].addr, buffer[start].addr, accessor.count * 4)
    else:
      raise newException(
        GltfError,
        "Invalid index component type: " & $accessor.componentType.int
      )

  if primInfo.attributes.position >= 0:
    let
      accessor = accessors[primInfo.attributes.position]
      bufferView = bufferViews[accessor.bufferView]
      buffer = buffers[bufferView.buffer]
      start = bufferView.byteOffset + accessor.byteOffset
    if accessor.componentType == cGL_FLOAT:
      assertRaise accessor.kind == atVEC3, "Unsupported position kind"
      result.points.setLen(accessor.count)
      if bufferView.byteStride == 0 or bufferView.byteStride == 12:
        copyMem(result.points[0].addr, buffer[start].addr, accessor.count * 12)
      else:
        let stride = bufferView.byteStride
        for i in 0 ..< accessor.count:
          result.points[i] = vec3(
            buffer.readFloat32(start + i * stride),
            buffer.readFloat32(start + i * stride + 4),
            buffer.readFloat32(start + i * stride + 8)
          )
    elif accessor.componentType == GL_UNSIGNED_SHORT:
      assertRaise accessor.kind == atVEC3, "Unsupported position kind"
      result.points.setLen(accessor.count)
      var stride = bufferView.byteStride
      if stride == 0:
        stride = 6
      for i in 0 ..< accessor.count:
        result.points[i] = vec3(
          float32 buffer.readUint16(start + i * stride),
          float32 buffer.readUint16(start + i * stride + 2),
          float32 buffer.readUint16(start + i * stride + 4)
        )
    elif accessor.componentType == GL_UNSIGNED_INT:
      assertRaise accessor.kind == atVEC3, "Unsupported position kind"
      assertRaise bufferView.byteStride == 0, "Unsupported position byteStride"
      result.points.setLen(accessor.count)
      var stride = bufferView.byteStride
      if stride == 0:
        stride = 12
      for i in 0 ..< accessor.count:
        result.points[i] = vec3(
          float32 buffer.readUint32(start + i * stride),
          float32 buffer.readUint32(start + i * stride + 4),
          float32 buffer.readUint32(start + i * stride + 8)
        )
    else:
      raise newException(
        GltfError,
        "Invalid position component type: " & $accessor.componentType.int
      )

  if primInfo.attributes.normal >= 0:
    let
      accessor = accessors[primInfo.attributes.normal]
      bufferView = bufferViews[accessor.bufferView]
      buffer = buffers[bufferView.buffer]
      start = bufferView.byteOffset + accessor.byteOffset
    assertRaise accessor.componentType == cGL_FLOAT,
      "Unsupported normal componentType"
    assertRaise accessor.kind == atVEC3, "Unsupported normal kind"
    result.normals.setLen(accessor.count)
    if bufferView.byteStride == 0 or bufferView.byteStride == 12:
      copyMem(result.normals[0].addr, buffer[start].addr, accessor.count * 12)
    else:
      let stride = bufferView.byteStride
      for i in 0 ..< accessor.count:
        result.normals[i] = vec3(
          buffer.readFloat32(start + i * stride),
          buffer.readFloat32(start + i * stride + 4),
          buffer.readFloat32(start + i * stride + 8)
        )

  if primInfo.attributes.color0 >= 0:
    let
      accessor = accessors[primInfo.attributes.color0]
      bufferView = bufferViews[accessor.bufferView]
      buffer = buffers[bufferView.buffer]
      start = bufferView.byteOffset + accessor.byteOffset
    if accessor.kind == atVEC4:
      if accessor.componentType == cGL_FLOAT:
        var stride = bufferView.byteStride
        if stride == 0:
          stride = 16
        for i in 0 ..< accessor.count:
          result.colors.add(rgba(
            (buffer.readFloat32(start + i * stride) * 255).uint8,
            (buffer.readFloat32(start + i * stride + 4) * 255).uint8,
            (buffer.readFloat32(start + i * stride + 8) * 255).uint8,
            (buffer.readFloat32(start + i * stride + 12) * 255).uint8
          ).rgbx)
      elif accessor.componentType == GL_UNSIGNED_BYTE:
        result.colors.setLen(accessor.count)
        if bufferView.byteStride == 0 or bufferView.byteStride == 4:
          copyMem(result.colors[0].addr, buffer[start].addr, accessor.count * 4)
        else:
          let stride = bufferView.byteStride
          for i in 0 ..< accessor.count:
            result.colors[i] = rgbx(
              buffer.readUint8(start + i * stride),
              buffer.readUint8(start + i * stride + 1),
              buffer.readUint8(start + i * stride + 2),
              buffer.readUint8(start + i * stride + 3)
            )
      else:
        raise newException(
          GltfError,
          "Invalid color component type: " & $accessor.componentType.int
        )
    elif accessor.kind == atVEC3:
      if accessor.componentType == cGL_FLOAT:
        var stride = bufferView.byteStride
        if stride == 0:
          stride = 12
        for i in 0 ..< accessor.count:
          result.colors.add(rgbx(
            (buffer.readFloat32(start + i * stride) * 255).uint8,
            (buffer.readFloat32(start + i * stride + 4) * 255).uint8,
            (buffer.readFloat32(start + i * stride + 8) * 255).uint8,
            255
          ))
      elif accessor.componentType == GL_UNSIGNED_BYTE:
        result.colors.setLen(accessor.count)
        var stride = bufferView.byteStride
        if stride == 0:
          stride = 3
        for i in 0 ..< accessor.count:
          result.colors[i] = rgbx(
            buffer.readUint8(start + i * stride),
            buffer.readUint8(start + i * stride + 1),
            buffer.readUint8(start + i * stride + 2),
            255
          )
      elif accessor.componentType == GL_UNSIGNED_SHORT:
        result.colors.setLen(accessor.count)
        var stride = bufferView.byteStride
        if stride == 0:
          stride = 6
        for i in 0 ..< accessor.count:
          let base = start + i * stride
          let r = buffer.readUint16(base)
          let g = buffer.readUint16(base + 2)
          let b = buffer.readUint16(base + 4)
          result.colors[i] = rgbx(
            (r div 257).uint8,
            (g div 257).uint8,
            (b div 257).uint8,
            255
          )
    else:
      raise newException(
        GltfError,
        "Invalid color kind: " & $accessor.kind
      )

  if primInfo.attributes.texcoord0 >= 0:
    let
      accessor = accessors[primInfo.attributes.texcoord0]
      bufferView = bufferViews[accessor.bufferView]
      buffer = buffers[bufferView.buffer]
      start = bufferView.byteOffset + accessor.byteOffset
    assertRaise accessor.componentType == cGL_FLOAT,
      "Unsupported texcoord componentType"
    assertRaise accessor.kind == atVEC2, "Unsupported texcoord kind"
    result.uvs.setLen(accessor.count)
    if bufferView.byteStride == 0 or bufferView.byteStride == 8:
      copyMem(result.uvs[0].addr, buffer[start].addr, accessor.count * 8)
    else:
      let stride = bufferView.byteStride
      for i in 0 ..< accessor.count:
        result.uvs[i] = vec2(
          buffer.readFloat32(start + i * stride),
          buffer.readFloat32(start + i * stride + 4)
        )

  if primInfo.attributes.normal >= 0 and
    primInfo.attributes.texcoord0 >= 0:
    result.tangents.setLen(result.normals.len)

    template computeTangents(idx: untyped) =
      var counts = newSeq[int](result.normals.len)
      var tmpTangents = newSeq[Vec3](result.normals.len)
      for i in 0 ..< idx.len div 3:
        let
          i0 = idx[i * 3].int
          i1 = idx[i * 3 + 1].int
          i2 = idx[i * 3 + 2].int
          v0 = result.points[i0]
          v1 = result.points[i1]
          v2 = result.points[i2]
          uv0 = result.uvs[i0]
          uv1 = result.uvs[i1]
          uv2 = result.uvs[i2]
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

      for i in 0 ..< result.tangents.len:
        if counts[i] > 0:
          let tangent = normalize(tmpTangents[i] / counts[i].float32)
          let handedness = 1.0
          result.tangents[i].x = tangent.x
          result.tangents[i].y = tangent.y
          result.tangents[i].z = tangent.z
          result.tangents[i].w = handedness

    if result.indices16.len > 0:
      computeTangents(result.indices16)
    if result.indices32.len > 0:
      computeTangents(result.indices32)

type
  LoadResult = object
    root: Node
    scenes: seq[Scene]
    sceneId: int
    cameras: seq[Camera]

proc loadModelJsonInternal(
  jsonRoot: JsonNode,
  modelDir: string,
  externalBuffers: seq[string]
): LoadResult =
  ## Loads a 3D model from a parsed glTF json tree.
  if "extensionsRequired" in jsonRoot:
    for extension in jsonRoot["extensionsRequired"]:
      case extension.getStr()
      of "KHR_texture_transform", "KHR_node_visibility":
        discard
      else:
        raise newException(
          GltfError,
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
    assertRaise data.len == entry["byteLength"].getInt(),
      "Buffer length does not match declared byteLength"
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
        raise newException(GltfError, &"Invalid bufferView target {target}")

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
        GltfError,
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
          raise newException(GltfError, &"Unsupported file extension {uri}")
      elif "bufferView" in entry:
        let
          bufferViewIndex = entry["bufferView"].getInt()
          bv = bufferViews[bufferViewIndex]
          ib = buffers[bv.buffer]
          imageData = ib[bv.byteOffset ..< bv.byteOffset + bv.byteLength]
        image = decodeImage(imageData)
      else:
        raise newException(GltfError, "Unsupported image type")
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

  var materials: seq[MaterialInfo]
  if "materials" in jsonRoot:
    for entry in jsonRoot["materials"]:
      var material = MaterialInfo()
      material.pbrMetallicRoughness.baseColorTexture = defaultMaterialTexture()
      material.pbrMetallicRoughness.metallicRoughnessTexture =
        defaultMaterialTexture()
      material.normalTexture = defaultMaterialTexture()
      material.occlusionTexture = defaultMaterialTexture()
      material.emissiveTexture = defaultMaterialTexture()
      if "name" in entry:
        material.name = entry["name"].getStr()

      if "pbrMetallicRoughness" in entry:
        let pbrMetallicRoughness = entry["pbrMetallicRoughness"]
        if "baseColorTexture" in pbrMetallicRoughness:
          let baseColorTexture = pbrMetallicRoughness["baseColorTexture"]
          material.pbrMetallicRoughness.baseColorTexture.index =
            baseColorTexture["index"].getInt()
          readTextureTransform(
            baseColorTexture,
            material.pbrMetallicRoughness.baseColorTexture
          )
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
          readTextureTransform(
            metallicRoughnessTexture,
            material.pbrMetallicRoughness.metallicRoughnessTexture
          )
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
        readTextureTransform(normalTexture, material.normalTexture)
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
        readTextureTransform(occlusionTexture, material.occlusionTexture)
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
        readTextureTransform(emissiveTexture, material.emissiveTexture)
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

      material.transmissionFactor = 0
      if "extensions" in entry:
        let extensions = entry["extensions"]
        if "KHR_materials_transmission" in extensions:
          let transmission = extensions["KHR_materials_transmission"]
          if "transmissionFactor" in transmission:
            material.transmissionFactor =
              transmission["transmissionFactor"].getFloat().float32

      materials.add(material)

  var cameras: seq[Camera]
  if "cameras" in jsonRoot:
    for entry in jsonRoot["cameras"]:
      var camera = Camera()
      if "name" in entry:
        camera.name = entry["name"].getStr()
      let cameraType = entry["type"].getStr()
      case cameraType
      of "perspective":
        camera.kind = ckPerspective
        let perspectiveInfo = entry["perspective"]
        camera.perspective.yfov =
          perspectiveInfo["yfov"].getFloat().float32
        camera.perspective.znear =
          perspectiveInfo["znear"].getFloat().float32
        if "aspectRatio" in perspectiveInfo:
          camera.perspective.aspectRatio =
            perspectiveInfo["aspectRatio"].getFloat().float32
        else:
          camera.perspective.aspectRatio = 0.0
        if "zfar" in perspectiveInfo:
          camera.perspective.zfar =
            perspectiveInfo["zfar"].getFloat().float32
        else:
          camera.perspective.zfar = 0.0
      of "orthographic":
        camera.kind = ckOrthographic
        let orthographicInfo = entry["orthographic"]
        camera.orthographic.xmag =
          orthographicInfo["xmag"].getFloat().float32
        camera.orthographic.ymag =
          orthographicInfo["ymag"].getFloat().float32
        camera.orthographic.znear =
          orthographicInfo["znear"].getFloat().float32
        camera.orthographic.zfar =
          orthographicInfo["zfar"].getFloat().float32
      else:
        raise newException(GltfError, &"Invalid camera type {cameraType}")
      cameras.add(camera)

  var
    meshDefs: seq[MeshInfo]
    primitiveDefs: seq[PrimitiveInfo]
  for entry in jsonRoot["meshes"]:
    var mesh = MeshInfo()
    if "name" in entry:
      mesh.name = entry["name"].getStr()
    mesh.primitives = @[]
    for primitive in entry["primitives"]:
      var prim = PrimitiveInfo()
      assertRaise "attributes" in primitive, "Missing primitive attributes"
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
      primitiveDefs.add(prim)
      mesh.primitives.add(primitiveDefs.len - 1)
    meshDefs.add(mesh)

  var
    nodes: seq[Node]
    nodeMeshes: seq[int]
    nodeCameras: seq[int]
    nodeChildren: seq[seq[int]]
  for entry in jsonRoot["nodes"]:
    var node = Node()
    if "name" in entry:
      node.name = entry["name"].getStr()
    else:
      node.name = "node_" & $nodes.len
    node.visible = true
    if "extensions" in entry:
      let extensions = entry["extensions"]
      if "KHR_node_visibility" in extensions:
        let visibility = extensions["KHR_node_visibility"]
        if "visible" in visibility:
          node.visible = visibility["visible"].getBool()

    var meshId = -1
    if "mesh" in entry:
      meshId = entry["mesh"].getInt()
    var cameraId = -1
    if "camera" in entry:
      cameraId = entry["camera"].getInt()
      assertRaise(
        cameraId >= 0 and cameraId < cameras.len,
        &"Invalid camera index {cameraId}"
      )

    if "matrix" in entry and entry["matrix"].len >= 16:
      let matrix = entry["matrix"]
      let localMat = mat4(
        matrix[0].getFloat().float32,
        matrix[1].getFloat().float32,
        matrix[2].getFloat().float32,
        matrix[3].getFloat().float32,
        matrix[4].getFloat().float32,
        matrix[5].getFloat().float32,
        matrix[6].getFloat().float32,
        matrix[7].getFloat().float32,
        matrix[8].getFloat().float32,
        matrix[9].getFloat().float32,
        matrix[10].getFloat().float32,
        matrix[11].getFloat().float32,
        matrix[12].getFloat().float32,
        matrix[13].getFloat().float32,
        matrix[14].getFloat().float32,
        matrix[15].getFloat().float32
      )

      node.pos = localMat.pos
      let
        xAxis = localMat.left
        yAxis = localMat.up
        zAxis = localMat.forward
      node.scale = vec3(length(xAxis), length(yAxis), length(zAxis))

      let rotationMat = mat4(
        (if node.scale.x != 0: xAxis.x / node.scale.x else: 1'f32),
        (if node.scale.x != 0: xAxis.y / node.scale.x else: 0'f32),
        (if node.scale.x != 0: xAxis.z / node.scale.x else: 0'f32),
        0'f32,
        (if node.scale.y != 0: yAxis.x / node.scale.y else: 0'f32),
        (if node.scale.y != 0: yAxis.y / node.scale.y else: 1'f32),
        (if node.scale.y != 0: yAxis.z / node.scale.y else: 0'f32),
        0'f32,
        (if node.scale.z != 0: zAxis.x / node.scale.z else: 0'f32),
        (if node.scale.z != 0: zAxis.y / node.scale.z else: 0'f32),
        (if node.scale.z != 0: zAxis.z / node.scale.z else: 1'f32),
        0'f32,
        0'f32,
        0'f32,
        0'f32,
        1'f32
      )
      node.rot = rotationMat.transpose().quat()
    elif "translation" in entry:
      let translation = entry["translation"]
      node.pos = vec3(
        translation[0].getFloat().float32,
        translation[1].getFloat().float32,
        translation[2].getFloat().float32
      )
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

    node.baseVisible = node.visible
    node.basePos = node.pos
    node.baseRot = node.rot
    node.baseScale = node.scale

    var children: seq[int]
    if "children" in entry:
      for child in entry["children"]:
        children.add(child.getInt())

    nodes.add(node)
    nodeMeshes.add(meshId)
    nodeCameras.add(cameraId)
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
          var
            nodeIdx = -1
            path: AnimPath
            isPath = true

          if "extensions" in target and
             "KHR_animation_pointer" in target["extensions"]:
            let pointer =
              target["extensions"]["KHR_animation_pointer"]["pointer"].getStr()
            if pointer.startsWith("/nodes/") and
               pointer.endsWith("/extensions/KHR_node_visibility/visible"):
              let suffix = "/extensions/KHR_node_visibility/visible"
              let remainder =
                pointer.substr(
                  "/nodes/".len,
                  pointer.len - suffix.len - 1
                )
              try:
                nodeIdx = parseInt(remainder)
                path = AnimVisibility
              except ValueError:
                isPath = false
            else:
              isPath = false
          else:
            if not ("node" in target) or not ("path" in target):
              continue
            nodeIdx = target["node"].getInt()
            let pathStr = target["path"].getStr()
            case pathStr
            of "translation":
              path = AnimTranslation
            of "rotation":
              path = AnimRotation
            of "scale":
              path = AnimScale
            else:
              isPath = false

          if nodeIdx < 0 or nodeIdx >= nodes.len:
            continue

          if not isPath:
            echo "[gltf] skipping unsupported animation target"
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
          of AnimVisibility:
            channel.valuesFloat =
              readAccessorFloats(
                sampler.output,
                accessors,
                bufferViews,
                buffers
              )

          if channel.times.len == 0:
            continue
          if channel.times.len != channel.valuesVec3.len and
             channel.times.len != channel.valuesQuat.len and
             channel.times.len != channel.valuesFloat.len:
            echo "[gltf] animation sampler length mismatch"
            continue

          if channel.times.len > 0:
            clip.duration = max(clip.duration, channel.times[^1])
          clip.channels.add(channel)

      if clip.channels.len > 0:
        clips.add(clip)

  var sceneRoots: seq[seq[int]]
  var scenes: seq[Scene]
  var sceneId = 0
  if "scene" in jsonRoot:
    sceneId = jsonRoot["scene"].getInt()
  for entry in jsonRoot["scenes"]:
    var scene = Scene()
    if "name" in entry:
      scene.name = entry["name"].getStr()
    var roots: seq[int]
    for n in entry["nodes"]:
      roots.add(n.getInt())
    scenes.add(scene)
    sceneRoots.add(roots)

  proc processNode(nodeId: int): Node =
    var n = nodes[nodeId]
    let meshId = nodeMeshes[nodeId]
    let cameraId = nodeCameras[nodeId]
    if meshId >= 0:
      let meshInfo = meshDefs[meshId]
      let runtimeMesh = Mesh(name: meshInfo.name)
      for primitiveIndex in meshInfo.primitives:
        runtimeMesh.primitives.add(loadPrimitive(
          primitiveIndex,
          primitiveDefs,
          accessors,
          bufferViews,
          buffers,
          images,
          textures,
          samplers,
          materials
        ))
      n.mesh = runtimeMesh
    if cameraId >= 0:
      n.camera = cameras[cameraId]

    for childId in nodeChildren[nodeId]:
      n.nodes.add(processNode(childId))

    return n

  # Keep one convenience tree for the selected scene.
  result.root = Node()
  result.root.visible = true
  result.root.name = "Root"
  result.root.pos = vec3(0, 0, 0)
  result.root.rot = quat(0, 0, 0, 1)
  result.root.scale = vec3(1, 1, 1)
  result.root.baseVisible = result.root.visible
  result.root.basePos = result.root.pos
  result.root.baseRot = result.root.rot
  result.root.baseScale = result.root.scale
  for i, scene in scenes:
    for nodeId in sceneRoots[i]:
      scene.nodes.add(processNode(nodeId))
  if scenes.len > 0:
    let selectedScene = max(0, min(sceneId, scenes.high))
    for sceneNode in scenes[selectedScene].nodes:
      result.root.nodes.add(sceneNode)
  result.root.animations = clips
  result.root.currentClip = 0
  result.root.animTime = 0
  result.scenes = scenes
  result.cameras = cameras
  result.sceneId =
    if scenes.len > 0:
      max(0, min(sceneId, scenes.high))
    else:
      0

proc loadModelJson*(
  jsonRoot: JsonNode,
  modelDir: string,
  externalBuffers: seq[string]
): Node =
  ## Loads a 3D model from a parsed glTF json tree.
  loadModelJsonInternal(jsonRoot, modelDir, externalBuffers).root

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
  let
    jsonRoot = parseJson(readFile(file))
    modelDir = splitPath(file)[0]
    loaded = loadModelJsonInternal(jsonRoot, modelDir, @[])
  GltfFile(
    path: file,
    root: loaded.root,
    scenes: loaded.scenes,
    scene: loaded.sceneId,
    cameras: loaded.cameras,
    unsupportedUsedExtensions: unsupportedUsedExtensions(jsonRoot)
  )

proc readGltfBinaryFile*(file: string): GltfFile =
  ## Reads a binary glTF file into a glTF file wrapper.
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

  let jsonRoot = parseJson(jsonData)
  let loaded = loadModelJsonInternal(jsonRoot, modelDir, buffers)
  GltfFile(
    path: file,
    root: loaded.root,
    scenes: loaded.scenes,
    scene: loaded.sceneId,
    cameras: loaded.cameras,
    unsupportedUsedExtensions: unsupportedUsedExtensions(jsonRoot)
  )

proc readGltfFile*(file: string): GltfFile =
  ## Reads a glTF file into a glTF file wrapper.
  if file.endsWith(".glb"):
    readGltfBinaryFile(file)
  else:
    readGltfJsonFile(file)
