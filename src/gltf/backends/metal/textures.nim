when defined(macosx):
  objc:
    proc blitCommandEncoder(self: MTLCommandBuffer): MTLCommandEncoder
    proc generateMipmapsForTexture(self: MTLCommandEncoder, x: MTLTexture)
    proc setRAddressMode(self: MTLSamplerDescriptor, x: MTLSamplerAddressMode)
    proc setMaxAnisotropy(self: MTLSamplerDescriptor, x: uint)
    proc setSampleCount(self: MTLTextureDescriptor, x: uint)
    proc setRasterSampleCount(self: MTLRenderPipelineDescriptor, x: uint)
    proc setStorageMode(self: MTLTextureDescriptor, x: uint)
    proc setResolveTexture(self: MTLRenderPassColorAttachmentDescriptor,
      x: MTLTexture)

  proc createTarget(renderer: Renderer, width, height: int,
      format: MTLPixelFormat, samples = 1, mipmapped = false): MTLTexture =
    ## Allocates a color or depth target with explicit format and samples.
    let descriptor = MTLTextureDescriptor.texture2DDescriptorWithPixelFormat(
      format,
      width.uint,
      height.uint,
      mipmapped
    )
    descriptor.setUsage(MTLTextureUsageRenderTarget or MTLTextureUsageShaderRead)
    if samples > 1:
      descriptor.setTextureType(4)
      descriptor.setSampleCount(samples.uint)
      descriptor.setStorageMode(2)
    result = renderer.ctx.device.newTextureWithDescriptor(descriptor)
    checkNil(result, "Could not create a parity render target")

  proc mipmaps(renderer: Renderer, texture: MTLTexture) =
    ## Generates linear mip levels on the same GPU used for drawing.
    let
      command = renderer.ctx.newCommandBuffer()
      encoder = command.blitCommandEncoder()
    encoder.generateMipmapsForTexture(texture)
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()

  proc uploadIblImage(renderer: Renderer, image: Image,
      srgb: bool): MetalTexture =
    ## Uploads straight-alpha pixels with hardware color-space decoding.
    if image == nil:
      return
    result = MetalTexture(width: image.width, height: image.height)
    let descriptor = MTLTextureDescriptor.texture2DDescriptorWithPixelFormat(
      if srgb: MTLPixelFormatRGBA8Unorm_sRGB else: MTLPixelFormatRGBA8Unorm,
      image.width.uint, image.height.uint, true)
    descriptor.setUsage(MTLTextureUsageShaderRead)
    result.texture = renderer.ctx.device.newTextureWithDescriptor(descriptor)
    checkNil(result.texture, "Could not upload a material texture")
    result.texture.replaceRegion(
      MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
        size: MTLSize(
          width: image.width.uint,
          height: image.height.uint,
          depth: 1
        )),
      0, image.data[0].unsafeAddr, (image.width * 4).uint)
    renderer.mipmaps(result.texture)

  proc prepareIblMaterial(renderer: Renderer, material: Material) =
    ## Uploads every authored material channel used by the shared shader.
    if material == nil:
      return
    if material.data == nil:
      material.data = MaterialData()
    if material.data.iblTextures[0] == nil and material.baseColor != nil:
      material.data.iblTextures[0] = renderer.uploadIblImage(
        material.baseColor,
        true
      )
    if material.data.iblTextures[1] == nil and material.metallicRoughness != nil:
      material.data.iblTextures[1] = renderer.uploadIblImage(
        material.metallicRoughness,
        false
      )
    if material.data.iblTextures[2] == nil and material.normal != nil:
      material.data.iblTextures[2] = renderer.uploadIblImage(
        material.normal,
        false
      )
    if material.data.iblTextures[3] == nil and material.occlusion != nil:
      material.data.iblTextures[3] = renderer.uploadIblImage(
        material.occlusion,
        false
      )
    if material.data.iblTextures[4] == nil and material.emissive != nil:
      material.data.iblTextures[4] = renderer.uploadIblImage(
        material.emissive,
        true
      )
    if material.data.iblTextures[13] == nil and material.transmission != nil:
      material.data.iblTextures[13] = renderer.uploadIblImage(
        material.transmission,
        false
      )
    if material.data.iblTextures[14] == nil and material.thickness != nil:
      material.data.iblTextures[14] = renderer.uploadIblImage(
        material.thickness,
        false
      )
    if material.data.iblTextures[15] == nil and material.diffuseTransmission != nil:
      material.data.iblTextures[15] = renderer.uploadIblImage(
        material.diffuseTransmission,
        false
      )
    if material.data.iblTextures[16] == nil and
        material.diffuseTransmissionColor != nil:
        material.data.iblTextures[16] = renderer.uploadIblImage(
          material.diffuseTransmissionColor,
          true
        )
    if material.data.iblTextures[17] == nil and material.anisotropy != nil:
      material.data.iblTextures[17] = renderer.uploadIblImage(
        material.anisotropy,
        false
      )
    if material.data.iblTextures[18] == nil and material.clearcoat != nil:
      material.data.iblTextures[18] = renderer.uploadIblImage(
        material.clearcoat,
        false
      )
    if material.data.iblTextures[19] == nil and material.clearcoatRoughness != nil:
      material.data.iblTextures[19] = renderer.uploadIblImage(
        material.clearcoatRoughness,
        false
      )
    if material.data.iblTextures[20] == nil and material.clearcoatNormal != nil:
      material.data.iblTextures[20] = renderer.uploadIblImage(
        material.clearcoatNormal,
        false
      )
    if material.data.iblTextures[21] == nil and material.iridescence != nil:
      material.data.iblTextures[21] = renderer.uploadIblImage(
        material.iridescence,
        false
      )
    if material.data.iblTextures[22] == nil and material.iridescenceThickness != nil:
      material.data.iblTextures[22] = renderer.uploadIblImage(
        material.iridescenceThickness,
        false
      )
    if material.data.iblTextures[23] == nil and material.specular != nil:
      material.data.iblTextures[23] = renderer.uploadIblImage(
        material.specular,
        false
      )
    if material.data.iblTextures[24] == nil and material.specularColor != nil:
      material.data.iblTextures[24] = renderer.uploadIblImage(
        material.specularColor,
        true
      )
    if material.data.iblTextures[25] == nil and material.sheenColor != nil:
      material.data.iblTextures[25] = renderer.uploadIblImage(
        material.sheenColor,
        true
      )
    if material.data.iblTextures[26] == nil and material.sheenRoughness != nil:
      material.data.iblTextures[26] = renderer.uploadIblImage(
        material.sheenRoughness,
        false
      )
    if material.data.iblTextures[27] == nil and material.diffuse != nil:
      material.data.iblTextures[27] = renderer.uploadIblImage(
        material.diffuse,
        true
      )
    if material.data.iblTextures[28] == nil and material.specularGlossiness != nil:
      material.data.iblTextures[28] = renderer.uploadIblImage(
        material.specularGlossiness,
        true
      )

  proc textureSampler(material: Material, unit: int): TextureSampler =
    ## Selects the glTF sampler or the fixed filtered-lighting sampler.
    case unit
    of 0: result = material.baseColorSampler
    of 1: result = material.metallicRoughnessSampler
    of 2: result = material.normalSampler
    of 3: result = material.occlusionSampler
    of 4: result = material.emissiveSampler
    of 13: result = material.transmissionSampler
    of 14: result = material.thicknessSampler
    of 15: result = material.diffuseTransmissionSampler
    of 16: result = material.diffuseTransmissionColorSampler
    of 17: result = material.anisotropySampler
    of 18: result = material.clearcoatSampler
    of 19: result = material.clearcoatRoughnessSampler
    of 20: result = material.clearcoatNormalSampler
    of 21: result = material.iridescenceSampler
    of 22: result = material.iridescenceThicknessSampler
    of 23: result = material.specularSampler
    of 24: result = material.specularColorSampler
    of 25: result = material.sheenColorSampler
    of 26: result = material.sheenRoughnessSampler
    of 27: result = material.diffuseSampler
    of 28: result = material.specularGlossinessSampler
    else:
      result = defaultTextureSampler()
      result.wrapS = ClampToEdgeWrap
      result.wrapT = ClampToEdgeWrap
      result.minFilter = LinearMipmapLinearMinFilter
      if unit == 12:
        result.magFilter = NearestMagFilter

  proc createSampler(renderer: Renderer, settings: TextureSampler,
      environment: bool): MTLSamplerState =
    ## Maps glTF filtering and wrap modes to an explicit Metal sampler.
    let descriptor = MTLSamplerDescriptor.alloc().init()
    descriptor.setMagFilter(if settings.magFilter == NearestMagFilter:
      MTLSamplerMinMagFilterNearest else: MTLSamplerMinMagFilterLinear)
    descriptor.setMinFilter(if settings.minFilter in
      {NearestMinFilter, NearestMipmapNearestMinFilter,
          NearestMipmapLinearMinFilter}:
        MTLSamplerMinMagFilterNearest else: MTLSamplerMinMagFilterLinear)
    descriptor.setMipFilter(case settings.minFilter
      of NearestMipmapNearestMinFilter, LinearMipmapNearestMinFilter:
        MTLSamplerMipFilterNearest
      of NearestMipmapLinearMinFilter, LinearMipmapLinearMinFilter:
        MTLSamplerMipFilterLinear
      else: MTLSamplerMipFilterNotMipmapped)
    proc wrap(mode: TextureWrap): MTLSamplerAddressMode =
      ## Converts one glTF addressing mode.
      case mode
      of ClampToEdgeWrap: MTLSamplerAddressModeClampToEdge
      of MirroredRepeatWrap: MTLSamplerAddressModeMirrorRepeat
      of RepeatWrap: MTLSamplerAddressModeRepeat
    descriptor.setSAddressMode(wrap(settings.wrapS))
    descriptor.setTAddressMode(wrap(settings.wrapT))
    descriptor.setRAddressMode(MTLSamplerAddressModeClampToEdge)
    if not environment and settings.magFilter != NearestMagFilter and
      settings.minFilter in {NearestMipmapLinearMinFilter,
          LinearMipmapLinearMinFilter}:
        descriptor.setMaxAnisotropy(16)
    result = renderer.ctx.device.newSamplerStateWithDescriptor(descriptor)
    cast[NSObject](descriptor).release()
    checkNil(result, "Could not create a material sampler")

  proc textureNames(source: string): seq[string] =
    ## Reads Shady's emitted texture binding order.
    for line in source.splitLines():
      if "[[texture(" in line:
        result.add(strutils.splitWhitespace(strutils.strip(line))[1])

  const IblTextureNames = textureNames(shaderSources.IblFragMsl)

  proc materialBindings(renderer: Renderer, material: Material):
      tuple[key: string, indices: seq[int], states: seq[MTLSamplerState]] =
    ## Shares equivalent sampler states without merging texture resources.
    var settings: seq[tuple[sampler: TextureSampler, environment: bool]]
    for name in IblTextureNames:
      let
        unit = IblSamplerNames.find(name)
        sampler = textureSampler(material, unit)
        environment = unit in [5, 7, 8, 9, 10, 11, 12]
        setting = (sampler, environment)
      var index = settings.find(setting)
      if index < 0:
        index = settings.len
        settings.add(setting)
        result.states.add(renderer.createSampler(sampler, environment))
      result.indices.add(index)
      result.key.add($index & ",")
