when defined(macosx):
  type
    MetalConstants = object
      layout: UniformLayout
      data: seq[uint8]

  const
    IblLayout = metalUniformLayout(shaderSources.IblFragMsl)
    PbrLayout = metalUniformLayout(shaderSources.PbrFragMsl)

  proc constants(layout: UniformLayout): MetalConstants =
    ## Allocates zeroed constants using Shady's generated native layout.
    MetalConstants(layout: layout, data: newSeq[uint8](layout.size))

  proc put[T](data: var MetalConstants, name: string, value: T) =
    ## Copies a scalar or vector into its reflected shader field.
    if data.layout.offsets.hasKey(name):
      let offset = data.layout.offsets[name]
      copyMem(data.data[offset].addr, value.unsafeAddr, sizeof(T))

  proc put(data: var MetalConstants, name: string, value: Mat3) =
    ## Pads matrix columns to the native sixteen-byte stride.
    if data.layout.offsets.hasKey(name):
      let offset = data.layout.offsets[name]
      for i in 0 ..< 3:
        let column = value[i]
        copyMem(data.data[offset + i * 16].addr, column.unsafeAddr, 12)

  proc put(data: var MetalConstants, name: string, value: Color) =
    ## Stores a color as four floating-point channels.
    data.put(name, vec4(value.r, value.g, value.b, value.a))

  proc putVectors[T](data: var MetalConstants, name: string,
      values: openArray[T]) =
    ## Stores vector arrays at their reflected sixteen-byte stride.
    if data.layout.offsets.hasKey(name):
      let offset = data.layout.offsets[name]
      for i, value in values:
        copyMem(data.data[offset + i * 16].addr, value.unsafeAddr, sizeof(T))

  proc materialConstants(ctx: PbrContext, primitive: Primitive,
      transform: Mat4, layout: UniformLayout): seq[uint8] =
    ## Packs the shared Shady material and lighting inputs for one draw.
    var data = constants(layout)
    let material = primitive.material
    data.put("view", ctx.view)
    data.put("proj", ctx.proj)
    data.put("tint", ctx.tint)
    data.put("cameraPosition", ctx.cameraPosition)
    data.put("sunLightDirection", ctx.sunLightDirection)
    data.put("sunLightColor", ctx.sunLightColor)
    data.put("rimLightDirection", ctx.rimLightDirection)
    data.put("rimLightColor", ctx.rimLightColor)
    data.put("ambientLightColor", ctx.ambientLightColor)
    data.put("fogColor", ctx.fogColor)
    data.put("fogStart", ctx.fogStart)
    data.put("fogEnd", ctx.fogEnd)
    data.put("fogDensity", ctx.fogDensity)
    data.put("fogStrength", ctx.fogStrength)
    data.put("debugViewMode", ctx.debugView.int32)
    data.put("useShadow", false)
    data.put("shadowBias", 0.0005'f)
    data.put("shadowMapTexelSize", vec2(1.0'f / 2048.0'f))
    data.put("exposure", ctx.exposure)
    data.put("renderTextureYFlip", true)
    data.put("environmentMapStrength", ctx.environmentMapStrength)
    data.put("environmentMipCount", if ctx.iblEnvironment.specular.isNil:
      3.0'f else: ctx.iblEnvironment.mipCount.float32)
    let
      angle = degToRad(ctx.environmentRotation)
      c = cos(angle)
      s = sin(angle)
      rotation = mat3(
        vec3(c, 0.0'f, -s),
        vec3(0.0'f, 1.0'f, 0.0'f),
        vec3(s, 0.0'f, c)
      )
    data.put("environmentRotation", rotation)
    data.put("transmissionBufferLod", 10.0'f)
    data.put("transmissionBackground", ctx.transmissionBackground)
    data.put("volumeScale", vec3(transform[0].xyz.length,
      transform[1].xyz.length, transform[2].xyz.length))
    data.put("punctualLightCount", ctx.punctualLightCount)
    data.putVectors("punctualLightDirections", ctx.punctualLightDirections)
    data.putVectors("punctualLightPositions", ctx.punctualLightPositions)
    data.putVectors("punctualLightColors", ctx.punctualLightColors)
    data.putVectors("punctualLightParameters", ctx.punctualLightParameters)
    data.put("hasVertexTangent", primitive.tangents.len > 0)
    if material == nil:
      return data.data
    data.put("unlitMaterial", material.unlit.int32)
    let alphaMode = if ctx.iblEnvironment.specular.isNil:
      material.legacyAlphaMode else: material.alphaMode
    data.put("opaqueMaterial", (alphaMode == OpaqueAlphaMode).int32)
    data.put("alphaCutoff", if material.alphaMode == MaskAlphaMode:
      material.alphaCutoff else: -1.0'f)
    data.put("baseColorFactor", material.baseColorFactor)
    data.put("useNormalTexture", material.hasNormalTexture)
    data.put("specularGlossinessMaterial", material.hasSpecularGlossiness)
    data.put("materialIor", if material.hasIor and material.ior == 0:
      1e8'f elif material.ior > 0: material.ior else: 1.5'f)
    data.put("specularFactor", if material.hasSpecular:
      material.specularFactor else: 1.0'f)
    data.put("specularColorFactor", if material.hasSpecular:
      material.specularColorFactor else: vec3(1))
    data.put("sheenEnabled", material.sheenColorFactor != vec3(0))
    data.put(
      "anisotropyEnabled",
      material.hasAnisotropy or material.anisotropyStrength > 0
    )
    data.put("anisotropyParameters", vec3(
      cos(material.anisotropyRotation),
      sin(material.anisotropyRotation),
      material.anisotropyStrength
    ))
    data.put("iridescenceThicknessRange", vec2(
      material.iridescenceThicknessMinimum,
      material.iridescenceThicknessMaximum
    ))
    let emissive = material.emissiveRadiance
    data.put("emissiveFactor", vec3(emissive.r, emissive.g, emissive.b))
    data.put("metallicFactor", material.metallicFactor)
    data.put("roughnessFactor", material.roughnessFactor)
    data.put("normalScale", material.normalScale)
    data.put("occlusionStrength", material.occlusionStrength)
    data.put("transmissionFactor", material.transmissionFactor)
    data.put("diffuseTransmissionFactor", material.diffuseTransmissionFactor)
    data.put(
      "diffuseTransmissionColorFactor",
      material.diffuseTransmissionColorFactor
    )
    data.put("thicknessFactor", material.thicknessFactor)
    data.put("attenuationDistance", material.attenuationDistance)
    data.put("attenuationColor", material.attenuationColor)
    data.put("diffuseFactor", material.diffuseFactor)
    data.put("specularGlossinessFactor", material.specularGlossinessFactor)
    data.put("glossinessFactor", material.glossinessFactor)
    data.put("sheenColorFactor", material.sheenColorFactor)
    data.put("sheenRoughnessFactor", material.sheenRoughnessFactor)
    data.put("clearcoatFactor", material.clearcoatFactor)
    data.put("clearcoatRoughnessFactor", material.clearcoatRoughnessFactor)
    data.put("clearcoatNormalScale", material.clearcoatNormalScale)
    data.put("iridescenceFactor", material.iridescenceFactor)
    data.put("iridescenceIor", material.iridescenceIor)
    data.put(
      "hasTransmissionTexture",
      material.transmission != nil or material.transmissionKtx2.len > 0
    )
    data.put(
      "hasThicknessTexture",
      material.thickness != nil or material.thicknessKtx2.len > 0
    )
    data.put("hasDiffuseTransmissionTexture",
      material.diffuseTransmission != nil or
      material.diffuseTransmissionKtx2.len > 0)
    data.put("hasDiffuseTransmissionColorTexture",
      material.diffuseTransmissionColor != nil or
      material.diffuseTransmissionColorKtx2.len > 0)
    data.put(
      "hasAnisotropyTexture",
      material.anisotropy != nil or material.anisotropyKtx2.len > 0
    )
    data.put(
      "hasClearcoatTexture",
      material.clearcoat != nil or material.clearcoatKtx2.len > 0
    )
    data.put("hasClearcoatRoughnessTexture",
      material.clearcoatRoughness != nil or
      material.clearcoatRoughnessKtx2.len > 0)
    data.put(
      "hasClearcoatNormalTexture",
      material.clearcoatNormal != nil or material.clearcoatNormalKtx2.len > 0
    )
    data.put(
      "hasIridescenceTexture",
      material.iridescence != nil or material.iridescenceKtx2.len > 0
    )
    data.put("hasIridescenceThicknessTexture",
      material.iridescenceThickness != nil or
      material.iridescenceThicknessKtx2.len > 0)
    data.put(
      "hasSpecularTexture",
      material.specular != nil or material.specularKtx2.len > 0
    )
    data.put(
      "hasSpecularColorTexture",
      material.specularColor != nil or material.specularColorKtx2.len > 0
    )
    data.put(
      "hasSheenColorTexture",
      material.sheenColor != nil or material.sheenColorKtx2.len > 0
    )
    data.put(
      "hasSheenRoughnessTexture",
      material.sheenRoughness != nil or material.sheenRoughnessKtx2.len > 0
    )
    data.put(
      "hasDiffuseTexture",
      material.diffuse != nil or material.diffuseKtx2.len > 0
    )
    data.put("hasSpecularGlossinessTexture",
      material.specularGlossiness != nil or
      material.specularGlossinessKtx2.len > 0)
    for (prefix, transform) in [
        ("baseColor", material.baseColorTransform),
        ("metallicRoughness", material.metallicRoughnessTransform),
        ("normal", material.normalTransform),
        ("occlusion", material.occlusionTransform),
        ("emissive", material.emissiveTransform),
        ("transmission", material.transmissionTransform),
        ("thickness", material.thicknessTransform),
        ("diffuseTransmission", material.diffuseTransmissionTransform),
        ("diffuseTransmissionColor", material.diffuseTransmissionColorTransform),
        ("anisotropy", material.anisotropyTransform),
        ("clearcoat", material.clearcoatTransform),
        ("clearcoatRoughness", material.clearcoatRoughnessTransform),
        ("clearcoatNormal", material.clearcoatNormalTransform),
        ("iridescence", material.iridescenceTransform),
        ("iridescenceThickness", material.iridescenceThicknessTransform),
        ("specular", material.specularTransform),
        ("specularColor", material.specularColorTransform),
        ("sheenColor", material.sheenColorTransform),
        ("sheenRoughness", material.sheenRoughnessTransform),
        ("diffuse", material.diffuseTransform),
        ("specularGlossiness", material.specularGlossinessTransform)]:
      data.put(prefix & "TexCoord", transform.texCoord.int32)
      data.put(prefix & "UvOffset", transform.offset)
      data.put(prefix & "UvScale", transform.scale)
      data.put(prefix & "UvRotation", transform.rotation)
    result = data.data

  proc updatePunctualLights(ctx: PbrContext, root: Node) =
    ## Authored lights use the same animated world transforms as the meshes.
    ctx.punctualLightCount = 0
    if ctx.iblEnvironment.specular.isNil: return
    proc visit(node: Node) =
      if node == nil or not node.visible: return
      if node.punctualLight != nil:
          let i = ctx.punctualLightCount.int
          if i >= ctx.punctualLightDirections.len:
            raise newException(
              GltfError,
              "IBL supports at most 32 authored punctual lights"
            )
          let light = node.punctualLight
          var rotation = mat4()
          for axis in 0 ..< 3:
            let column = node.mat[axis].xyz
            if column.lengthSq > 0:
              let unit = normalize(column)
              for row in 0 ..< 3: rotation[axis, row] = unit[row]
          ctx.punctualLightDirections[i] = quatRotate(
            normalize(quat(rotation)),
            vec3(0, 0, -1)
          )
          ctx.punctualLightPositions[i] = node.mat[3].xyz
          ctx.punctualLightColors[i] = vec3(
            light.color.r,
            light.color.g,
            light.color.b
          ) * light.intensity
          ctx.punctualLightParameters[i] = vec4(
            light.kind.ord.float32,
            light.range,
            cos(light.innerConeAngle),
            cos(light.outerConeAngle)
          )
          inc ctx.punctualLightCount
      for child in node.nodes: visit(child)
    visit(root)

