import
  std/algorithm,
  chroma, pixie, vmath, windy,
  ../../common, ../../models,
  ./common,
  ../shaders as shaderSources

when defined(macosx):
  import pkg/metal4

const
  VertexEntryPoint* = "vertexMain"
  FragmentEntryPoint* = "fragmentMain"
  StudioEnvSize = 8

  PbrVertexShader* = shaderSources.PbrVertMsl
  PbrFragmentShader* = shaderSources.PbrFragMsl
  SkyboxVertexShader* = shaderSources.SkyboxVertMsl
  SkyboxFragmentShader* = shaderSources.SkyboxFragMsl
  ShadowDepthVertexShader* = shaderSources.ShadowDepthVertMsl
  ShadowDepthFragmentShader* = shaderSources.ShadowDepthFragMsl

type
  MetalVertex {.packed.} = object
    position: array[3, float32]
    color: array[4, float32]
    normal: array[3, float32]
    uv: array[2, float32]
    tangent: array[4, float32]
    joints: array[4, uint32]
    weights: array[4, float32]
    uv1: array[2, float32]

  RgbaSubresource = object
    width, height: int
    pixels: seq[ColorRGBX]

  Std140Writer = object
    data: seq[uint32]
    offset: int

  Renderer* = ref object
    window*: Window
    size*: IVec2
    clearColor*: Color
    scene*: Node
    params*: RenderParams
    when defined(macosx):
      ctx*: MetalContext
      pipelineState*: MTLRenderPipelineState
      blendPipelineState*: MTLRenderPipelineState
      depthState*: MTLDepthStencilState
      depthReadState*: MTLDepthStencilState
      sampler*: MTLSamplerState
      whiteTexture*: MTLTexture
      environmentTexture*: MTLTexture
      depthTexture*: MTLTexture
      offscreenTexture*: MTLTexture
      targetWidth*: int
      targetHeight*: int

  BlendEntry = object
    node: Node
    primitive: Primitive
    transform: Mat4

when defined(macosx):
  type
    MTLVertexFormat = uint
    MTLVertexStepFunction = uint
    MTLVertexDescriptor = distinct NSObject
    MTLVertexBufferLayoutDescriptor = distinct NSObject
    MTLVertexBufferLayoutDescriptorArray = distinct NSObject
    MTLVertexAttributeDescriptor = distinct NSObject
    MTLVertexAttributeDescriptorArray = distinct NSObject

const
  MetalVertexBufferIndex = 2'u

when defined(macosx):
  const
    MTLVertexFormatFloat2: MTLVertexFormat = 29
    MTLVertexFormatFloat3: MTLVertexFormat = 30
    MTLVertexFormatFloat4: MTLVertexFormat = 31
    MTLVertexFormatUInt4: MTLVertexFormat = 39
    MTLVertexStepFunctionPerVertex: MTLVertexStepFunction = 1
    MTLTextureTypeCube = 5'u

when defined(macosx):
  objc:
    proc vertexDescriptor*(
      class: typedesc[MTLVertexDescriptor]
    ): MTLVertexDescriptor
    proc setVertexDescriptor*(
      self: MTLRenderPipelineDescriptor,
      x: MTLVertexDescriptor
    )
    proc layouts*(
      self: MTLVertexDescriptor
    ): MTLVertexBufferLayoutDescriptorArray
    proc attributes*(
      self: MTLVertexDescriptor
    ): MTLVertexAttributeDescriptorArray
    proc objectAtIndexedSubscript*(
      self: MTLVertexBufferLayoutDescriptorArray,
      x: uint
    ): MTLVertexBufferLayoutDescriptor
    proc objectAtIndexedSubscript*(
      self: MTLVertexAttributeDescriptorArray,
      x: uint
    ): MTLVertexAttributeDescriptor
    proc setStride*(
      self: MTLVertexBufferLayoutDescriptor,
      x: uint
    )
    proc setStepFunction*(
      self: MTLVertexBufferLayoutDescriptor,
      x: MTLVertexStepFunction
    )
    proc setFormat*(
      self: MTLVertexAttributeDescriptor,
      x: MTLVertexFormat
    )
    proc setOffset*(
      self: MTLVertexAttributeDescriptor,
      x: uint
    )
    proc setBufferIndex*(
      self: MTLVertexAttributeDescriptor,
      x: uint
    )
    proc setTextureType*(
      self: MTLTextureDescriptor,
      x: uint
    )
    proc replaceRegion*(
      self: MTLTexture,
      x: MTLRegion,
      mipmapLevel: uint,
      slice: uint,
      withBytes: pointer,
      bytesPerRow: uint,
      bytesPerImage: uint
    )
    proc setFragmentBytes*(
      self: MTLRenderCommandEncoder,
      x: pointer,
      length: uint,
      atIndex: uint
    )
    proc getBytes*(
      self: MTLTexture,
      x: pointer,
      bytesPerRow: uint,
      fromRegion: MTLRegion,
      mipmapLevel: uint
    )
    proc waitUntilCompleted*(self: MTLCommandBuffer)

proc clampSize(size: IVec2): IVec2 =
  ivec2(max(1'i32, size.x), max(1'i32, size.y))

when not defined(macosx):
  proc toRgbx(value: Color): ColorRGBX =
    proc channel(v: float32): uint8 =
      var c = v
      if c < 0:
        c = 0
      elif c > 1:
        c = 1
      uint8(c * 255 + 0.5)
    rgbx(channel(value.r), channel(value.g), channel(value.b), channel(value.a))

when defined(macosx):
  proc toMetalColor(value: Color): MTLClearColor =
    MTLClearColor(
      red: value.r.float64,
      green: value.g.float64,
      blue: value.b.float64,
      alpha: value.a.float64
    )

proc copyVec2(dst: var array[2, float32], src: Vec2) =
  dst[0] = src.x
  dst[1] = src.y

proc copyVec3(dst: var array[3, float32], src: Vec3) =
  dst[0] = src.x
  dst[1] = src.y
  dst[2] = src.z

proc copyVec4(dst: var array[4, float32], src: Vec4) =
  dst[0] = src.x
  dst[1] = src.y
  dst[2] = src.z
  dst[3] = src.w

proc copyColor(dst: var array[4, float32], src: ColorRGBX) =
  dst[0] = src.r.float32 / 255.0
  dst[1] = src.g.float32 / 255.0
  dst[2] = src.b.float32 / 255.0
  dst[3] = src.a.float32 / 255.0

proc copyJoints(dst: var array[4, uint32], src: array[4, uint16]) =
  for i in 0 ..< 4:
    dst[i] = src[i].uint32

proc f32bits(value: float32): uint32 =
  cast[uint32](value)

proc align(value, alignment: int): int =
  ((value + alignment - 1) div alignment) * alignment

proc alignOffset(writer: var Std140Writer, alignment: int) =
  writer.offset = align(writer.offset, alignment)

proc ensureBytes(writer: var Std140Writer, byteCount: int) =
  let words = (max(0, byteCount) + 3) div 4
  if writer.data.len < words:
    writer.data.setLen(words)

proc putU32(writer: var Std140Writer, value: uint32) =
  writer.ensureBytes(writer.offset + 4)
  writer.data[writer.offset div 4] = value
  writer.offset += 4

proc putFloat(writer: var Std140Writer, value: float32) =
  writer.putU32(value.f32bits)

proc putInt(writer: var Std140Writer, value: int) =
  writer.putU32(value.uint32)

proc putBool(writer: var Std140Writer, value: bool) =
  writer.putU32(value.ord.uint32)

proc putVec2(writer: var Std140Writer, value: Vec2) =
  writer.alignOffset(8)
  writer.putFloat(value.x)
  writer.putFloat(value.y)

proc putVec3(writer: var Std140Writer, value: Vec3) =
  writer.alignOffset(16)
  writer.putFloat(value.x)
  writer.putFloat(value.y)
  writer.putFloat(value.z)
  writer.ensureBytes(writer.offset + 4)
  writer.offset += 4

proc putColor(writer: var Std140Writer, value: Color) =
  writer.alignOffset(16)
  writer.putFloat(value.r)
  writer.putFloat(value.g)
  writer.putFloat(value.b)
  writer.putFloat(value.a)

proc putMat4(writer: var Std140Writer, value: Mat4) =
  writer.alignOffset(16)
  for i in 0 ..< 4:
    for j in 0 ..< 4:
      writer.putFloat(value[i, j])

proc putMat4Array(writer: var Std140Writer, values: openArray[Mat4], count: int) =
  writer.alignOffset(16)
  for i in 0 ..< count:
    if i < values.len:
      writer.putMat4(values[i])
    else:
      writer.ensureBytes(writer.offset + 64)
      writer.offset += 64

proc finish(writer: var Std140Writer): seq[uint32] =
  writer.ensureBytes(max(4, align(writer.offset, 4)))
  writer.data

proc downsample(src: RgbaSubresource): RgbaSubresource =
  result.width = max(1, src.width div 2)
  result.height = max(1, src.height div 2)
  result.pixels = newSeq[ColorRGBX](result.width * result.height)
  for y in 0 ..< result.height:
    let
      sy0 = y * src.height div result.height
      sy1 = min(src.height, max(sy0 + 1, (y + 1) * src.height div result.height))
    for x in 0 ..< result.width:
      let
        sx0 = x * src.width div result.width
        sx1 = min(src.width, max(sx0 + 1, (x + 1) * src.width div result.width))
      var r, g, b, a, count: uint32
      for sy in sy0 ..< sy1:
        for sx in sx0 ..< sx1:
          let pixel = src.pixels[sy * src.width + sx]
          r += pixel.r.uint32
          g += pixel.g.uint32
          b += pixel.b.uint32
          a += pixel.a.uint32
          inc count
      result.pixels[y * result.width + x] = rgbx(
        uint8(r div count),
        uint8(g div count),
        uint8(b div count),
        uint8(a div count)
      )

proc buildMipChain(base: RgbaSubresource): seq[RgbaSubresource] =
  result.add(base)
  while result[^1].width > 1 or result[^1].height > 1:
    result.add(result[^1].downsample())

proc studioFaceDirection(face, x, y, size: int): Vec3 =
  let
    u = ((x.float32 + 0.5'f) / size.float32) * 2.0'f - 1.0'f
    v = ((y.float32 + 0.5'f) / size.float32) * 2.0'f - 1.0'f
  case face
  of 0: normalize(vec3(1.0'f, -v, -u))
  of 1: normalize(vec3(-1.0'f, -v, u))
  of 2: normalize(vec3(u, 1.0'f, v))
  of 3: normalize(vec3(u, -1.0'f, -v))
  of 4: normalize(vec3(u, -v, 1.0'f))
  of 5: normalize(vec3(-u, -v, -1.0'f))
  else: vec3(0, 1, 0)

proc studioColor(dir: Vec3): ColorRGBX =
  let
    hemi = clamp(dir.y * 0.5'f + 0.5'f, 0.0'f, 1.0'f)
    keyDir = normalize(vec3(0.35'f, 0.85'f, 0.25'f))
    fillDir = normalize(vec3(-0.45'f, 0.65'f, -0.35'f))
    key = pow(max(dot(dir, keyDir), 0.0'f), 24.0'f)
    fill = pow(max(dot(dir, fillDir), 0.0'f), 8.0'f)
    cool = vec3(0.18'f, 0.19'f, 0.21'f)
    neutral = vec3(0.58'f, 0.6'f, 0.63'f)
    sky = vec3(0.92'f, 0.94'f, 0.97'f)
  var color = mix(cool, neutral, hemi)
  color = mix(color, sky, hemi * hemi)
  color += vec3(0.28'f, 0.27'f, 0.25'f) * key
  color += vec3(0.10'f, 0.11'f, 0.12'f) * fill
  rgbx(
    uint8(clamp((color.x * 255.0'f).int, 0, 255)),
    uint8(clamp((color.y * 255.0'f).int, 0, 255)),
    uint8(clamp((color.z * 255.0'f).int, 0, 255)),
    255
  )

proc buildStudioCubeMips(): seq[RgbaSubresource] =
  for face in 0 ..< 6:
    var base = RgbaSubresource(
      width: StudioEnvSize,
      height: StudioEnvSize,
      pixels: newSeq[ColorRGBX](StudioEnvSize * StudioEnvSize)
    )
    for y in 0 ..< StudioEnvSize:
      for x in 0 ..< StudioEnvSize:
        base.pixels[y * StudioEnvSize + x] =
          studioColor(studioFaceDirection(face, x, y, StudioEnvSize))
    for mip in base.buildMipChain():
      result.add(mip)

proc fillVertex(
  vertex: var MetalVertex,
  primitive: Primitive,
  index: int
) =
  vertex.position.copyVec3(primitive.points[index])
  if index < primitive.colors.len:
    vertex.color.copyColor(primitive.colors[index])
  else:
    vertex.color = [1.0'f, 1.0, 1.0, 1.0]
  if index < primitive.normals.len:
    vertex.normal.copyVec3(primitive.normals[index])
  if index < primitive.uvs.len:
    vertex.uv.copyVec2(primitive.uvs[index])
  if index < primitive.tangents.len:
    vertex.tangent.copyVec4(primitive.tangents[index])
  if index < primitive.jointIds.len:
    vertex.joints.copyJoints(primitive.jointIds[index])
  if index < primitive.jointWeights.len:
    vertex.weights.copyVec4(primitive.jointWeights[index])
  if index < primitive.uvs1.len:
    vertex.uv1.copyVec2(primitive.uvs1[index])

proc buildVertices(primitive: Primitive): seq[MetalVertex] =
  if primitive.indices32.len > 0:
    result.setLen(primitive.indices32.len)
    for i, index in primitive.indices32:
      result[i].fillVertex(primitive, index.int)
  elif primitive.indices16.len > 0:
    result.setLen(primitive.indices16.len)
    for i, index in primitive.indices16:
      result[i].fillVertex(primitive, index.int)
  else:
    result.setLen(primitive.points.len)
    for i in 0 ..< result.len:
      result[i].fillVertex(primitive, i)

when defined(macosx):
  proc createTexture(
    renderer: Renderer,
    width,
    height: int,
    usage: MTLTextureUsage
  ): MTLTexture =
    let descriptor = MTLTextureDescriptor.texture2DDescriptorWithPixelFormat(
      MTLPixelFormatBGRA8Unorm,
      width.uint,
      height.uint,
      false
    )
    descriptor.setUsage(usage)
    result = renderer.ctx.device.newTextureWithDescriptor(descriptor)
    checkNil(result, "Could not create a Metal texture")

  proc ensureTargets(renderer: Renderer, width, height: int) =
    let
      targetWidth = max(1, width)
      targetHeight = max(1, height)
    if renderer.targetWidth == targetWidth and
        renderer.targetHeight == targetHeight and
        not renderer.depthTexture.isNil and
        not renderer.offscreenTexture.isNil:
      return

    let depthDescriptor =
      MTLTextureDescriptor.texture2DDescriptorWithPixelFormat(
        MTLPixelFormatDepth32Float,
        targetWidth.uint,
        targetHeight.uint,
        false
      )
    depthDescriptor.setUsage(
      MTLTextureUsageRenderTarget or MTLTextureUsageShaderRead
    )
    renderer.depthTexture =
      renderer.ctx.device.newTextureWithDescriptor(depthDescriptor)
    checkNil(renderer.depthTexture, "Could not create a Metal depth texture")
    renderer.offscreenTexture = renderer.createTexture(
      targetWidth,
      targetHeight,
      MTLTextureUsageRenderTarget
    )
    renderer.targetWidth = targetWidth
    renderer.targetHeight = targetHeight

  proc createWhiteTexture(renderer: Renderer): MTLTexture =
    var pixel = [255'u8, 255, 255, 255]
    let descriptor = MTLTextureDescriptor.texture2DDescriptorWithPixelFormat(
      MTLPixelFormatRGBA8Unorm,
      1,
      1,
      false
    )
    descriptor.setUsage(MTLTextureUsageShaderRead)
    result = renderer.ctx.device.newTextureWithDescriptor(descriptor)
    checkNil(result, "Could not create a white Metal texture")
    result.replaceRegion(
      MTLRegion(
        origin: MTLOrigin(x: 0, y: 0, z: 0),
        size: MTLSize(width: 1, height: 1, depth: 1)
      ),
      0,
      pixel[0].addr,
      4
    )

  proc setAttribute(
    descriptor: MTLVertexDescriptor,
    index: uint,
    format: MTLVertexFormat,
    offset: uint
  ) =
    let attribute = descriptor.attributes().objectAtIndexedSubscript(index)
    attribute.setFormat(format)
    attribute.setOffset(offset)
    attribute.setBufferIndex(MetalVertexBufferIndex)

  proc createVertexDescriptor(): MTLVertexDescriptor =
    result = MTLVertexDescriptor.vertexDescriptor()
    checkNil(result, "Could not create a Metal vertex descriptor")
    result.setAttribute(0, MTLVertexFormatFloat3, 0)
    result.setAttribute(1, MTLVertexFormatFloat4, 12)
    result.setAttribute(2, MTLVertexFormatFloat3, 28)
    result.setAttribute(3, MTLVertexFormatFloat2, 40)
    result.setAttribute(4, MTLVertexFormatFloat4, 48)
    result.setAttribute(5, MTLVertexFormatUInt4, 64)
    result.setAttribute(6, MTLVertexFormatFloat4, 80)
    result.setAttribute(7, MTLVertexFormatFloat2, 96)
    let layout =
      result.layouts().objectAtIndexedSubscript(MetalVertexBufferIndex)
    layout.setStride(sizeof(MetalVertex).uint)
    layout.setStepFunction(MTLVertexStepFunctionPerVertex)

  proc createStudioCubeTexture(renderer: Renderer): MTLTexture =
    let descriptor = MTLTextureDescriptor.texture2DDescriptorWithPixelFormat(
      MTLPixelFormatRGBA8Unorm,
      StudioEnvSize.uint,
      StudioEnvSize.uint,
      true
    )
    descriptor.setTextureType(MTLTextureTypeCube)
    descriptor.setUsage(MTLTextureUsageShaderRead)
    result = renderer.ctx.device.newTextureWithDescriptor(descriptor)
    checkNil(result, "Could not create a Metal environment texture")

    let
      region = MTLRegion(
        origin: MTLOrigin(x: 0, y: 0, z: 0),
        size: MTLSize(width: 0, height: 0, depth: 1)
      )
      mipsPerFace = 4
      mips = buildStudioCubeMips()
    for face in 0 ..< 6:
      for mip in 0 ..< mipsPerFace:
        let subresource = mips[face * mipsPerFace + mip]
        var mipRegion = region
        mipRegion.size.width = subresource.width.uint
        mipRegion.size.height = subresource.height.uint
        result.replaceRegion(
          mipRegion,
          mip.uint,
          face.uint,
          subresource.pixels[0].addr,
          (subresource.width * sizeof(ColorRGBX)).uint,
          (subresource.width * subresource.height * sizeof(ColorRGBX)).uint
        )

  proc initPipeline(renderer: Renderer) =
    var error: NSError
    let vertexLibrary = renderer.ctx.device.newLibraryWithSource(
      @PbrVertexShader,
      0.ID,
      error.addr
    )
    checkNSError(error, "Could not compile Metal glTF vertex shader")
    checkNil(vertexLibrary, "Metal glTF vertex shader library was nil")
    error = 0.NSError
    let fragmentLibrary = renderer.ctx.device.newLibraryWithSource(
      @PbrFragmentShader,
      0.ID,
      error.addr
    )
    checkNSError(error, "Could not compile Metal glTF fragment shader")
    checkNil(fragmentLibrary, "Metal glTF fragment shader library was nil")

    let vertexFunction = vertexLibrary.newFunctionWithName(@VertexEntryPoint)
    checkNil(vertexFunction, "Could not load Metal vertex entry point")
    let fragmentFunction =
      fragmentLibrary.newFunctionWithName(@FragmentEntryPoint)
    checkNil(fragmentFunction, "Could not load Metal fragment entry point")

    let pipelineDescriptor = MTLRenderPipelineDescriptor.alloc().init()
    checkNil(pipelineDescriptor, "Could not create a Metal pipeline descriptor")
    let colorAttachment =
      pipelineDescriptor.colorAttachments().objectAtIndexedSubscript(0)
    pipelineDescriptor.setVertexFunction(vertexFunction)
    pipelineDescriptor.setFragmentFunction(fragmentFunction)
    pipelineDescriptor.setVertexDescriptor(createVertexDescriptor())
    colorAttachment.setPixelFormat(MTLPixelFormatBGRA8Unorm)
    pipelineDescriptor.setDepthAttachmentPixelFormat(MTLPixelFormatDepth32Float)
    renderer.pipelineState =
      renderer.ctx.device.newRenderPipelineStateWithDescriptor(
        pipelineDescriptor,
        error.addr
      )
    checkNSError(error, "Could not create Metal glTF pipeline")
    checkNil(renderer.pipelineState, "Metal glTF pipeline state was nil")
    error = 0.NSError
    colorAttachment.setBlendingEnabled(true)
    colorAttachment.setSourceRGBBlendFactor(MTLBlendFactorSourceAlpha)
    colorAttachment.setDestinationRGBBlendFactor(
      MTLBlendFactorOneMinusSourceAlpha
    )
    colorAttachment.setRgbBlendOperation(MTLBlendOperationAdd)
    colorAttachment.setSourceAlphaBlendFactor(MTLBlendFactorOne)
    colorAttachment.setDestinationAlphaBlendFactor(
      MTLBlendFactorOneMinusSourceAlpha
    )
    colorAttachment.setAlphaBlendOperation(MTLBlendOperationAdd)
    renderer.blendPipelineState =
      renderer.ctx.device.newRenderPipelineStateWithDescriptor(
        pipelineDescriptor,
        error.addr
      )
    checkNSError(error, "Could not create Metal blended glTF pipeline")
    checkNil(
      renderer.blendPipelineState,
      "Metal blended glTF pipeline state was nil"
    )

    let depthDescriptor = MTLDepthStencilDescriptor.alloc().init()
    checkNil(depthDescriptor, "Could not create a Metal depth descriptor")
    depthDescriptor.setDepthCompareFunction(MTLCompareFunctionLess)
    depthDescriptor.setDepthWriteEnabled(true)
    renderer.depthState =
      renderer.ctx.device.newDepthStencilStateWithDescriptor(depthDescriptor)
    checkNil(renderer.depthState, "Could not create a Metal depth state")
    depthDescriptor.setDepthWriteEnabled(false)
    renderer.depthReadState =
      renderer.ctx.device.newDepthStencilStateWithDescriptor(depthDescriptor)
    checkNil(
      renderer.depthReadState,
      "Could not create a Metal depth read state"
    )

    let samplerDescriptor = MTLSamplerDescriptor.alloc().init()
    checkNil(samplerDescriptor, "Could not create a Metal sampler descriptor")
    samplerDescriptor.setMinFilter(MTLSamplerMinMagFilterLinear)
    samplerDescriptor.setMagFilter(MTLSamplerMinMagFilterLinear)
    samplerDescriptor.setMipFilter(MTLSamplerMipFilterLinear)
    samplerDescriptor.setSAddressMode(MTLSamplerAddressModeRepeat)
    samplerDescriptor.setTAddressMode(MTLSamplerAddressModeRepeat)
    renderer.sampler =
      renderer.ctx.device.newSamplerStateWithDescriptor(samplerDescriptor)
    checkNil(renderer.sampler, "Could not create a Metal sampler state")
    renderer.whiteTexture = renderer.createWhiteTexture()
    renderer.environmentTexture = renderer.createStudioCubeTexture()

  proc uploadBuffer[T](
    renderer: Renderer,
    values: openArray[T]
  ): MTLBuffer =
    if values.len == 0:
      return 0.MTLBuffer
    result = renderer.ctx.device.newBufferWithBytes(
      unsafeAddr values[0],
      uint(values.len * sizeof(T)),
      0
    )
    checkNil(result, "Could not create a Metal buffer")

  proc uploadImage(renderer: Renderer, image: Image): MetalTexture =
    if image == nil or image.width <= 0 or image.height <= 0:
      return nil

    result = MetalTexture(width: image.width, height: image.height)
    let descriptor = MTLTextureDescriptor.texture2DDescriptorWithPixelFormat(
      MTLPixelFormatRGBA8Unorm,
      image.width.uint,
      image.height.uint,
      false
    )
    descriptor.setUsage(MTLTextureUsageShaderRead)
    result.texture = renderer.ctx.device.newTextureWithDescriptor(descriptor)
    checkNil(result.texture, "Could not create a Metal texture")
    result.texture.replaceRegion(
      MTLRegion(
        origin: MTLOrigin(x: 0, y: 0, z: 0),
        size: MTLSize(
          width: image.width.uint,
          height: image.height.uint,
          depth: 1
        )
      ),
      0,
      unsafeAddr image.data[0],
      uint(image.width * 4)
    )

proc ensurePrimitive(renderer: Renderer, primitive: Primitive) =
  if primitive == nil:
    return
  if primitive.data == nil:
    primitive.data = PrimitiveData()
  when defined(macosx):
    if primitive.data.geometryVersion == primitive.geometryVersion and
        not primitive.data.vertexBuffer.isNil:
      return
  else:
    if primitive.data.geometryVersion == primitive.geometryVersion:
      return

  let vertices = primitive.buildVertices()
  primitive.data.vertexCount = vertices.len
  primitive.data.uses32BitIndices = primitive.indices32.len > 0
  primitive.data.indexCount =
    if primitive.indices32.len > 0:
      primitive.indices32.len
    else:
      primitive.indices16.len
  primitive.data.geometryVersion = primitive.geometryVersion

  when defined(macosx):
    primitive.data.vertexBuffer = renderer.uploadBuffer(vertices)
    if primitive.indices32.len > 0:
      primitive.data.indexBuffer = renderer.uploadBuffer(primitive.indices32)
    else:
      primitive.data.indexBuffer = renderer.uploadBuffer(primitive.indices16)
  else:
    discard renderer

proc ensureMaterial(renderer: Renderer, material: Material) =
  if material == nil:
    return
  if material.data == nil:
    material.data = MaterialData()
  when defined(macosx):
    if material.data.materialVersion == material.materialVersion and
        material.data.baseColor != nil:
      return
  else:
    if material.data.materialVersion == material.materialVersion:
      return

  material.data.materialVersion = material.materialVersion
  when defined(macosx):
    material.data.baseColor = renderer.uploadImage(material.baseColor)
    material.data.metallicRoughness =
      renderer.uploadImage(material.metallicRoughness)
    material.data.normal = renderer.uploadImage(material.normal)
    material.data.occlusion = renderer.uploadImage(material.occlusion)
    material.data.emissive = renderer.uploadImage(material.emissive)
  else:
    discard renderer

proc prepareNode(renderer: Renderer, node: Node) =
  if node == nil:
    return
  if node.mesh != nil:
    for primitive in node.mesh.primitives:
      renderer.ensurePrimitive(primitive)
      renderer.ensureMaterial(primitive.material)
  for child in node.nodes:
    renderer.prepareNode(child)

proc putTextureTransform(
  writer: var Std140Writer,
  transform: TextureTransform
) =
  writer.putInt(transform.texCoord)
  writer.putVec2(transform.offset)
  writer.putVec2(transform.scale)
  writer.putFloat(transform.rotation)

proc shadyVertexConstants(
  owner,
  root: Node,
  transform,
  view,
  proj: Mat4
): seq[uint32] =
  var writer: Std140Writer
  let jointMatrices = root.skinMatrices(owner)
  writer.putBool(jointMatrices.len > 0)
  writer.putMat4Array(jointMatrices, 128)
  writer.putMat4(transform)
  writer.putMat4(mat4())
  writer.putMat4(proj)
  writer.putMat4(view)
  writer.finish()

proc shadyFragmentConstants(
  primitive: Primitive,
  tint: Color,
  ambientLightColor: Color,
  sunLightDirection: Vec3,
  sunLightColor: Color,
  rimLightDirection: Vec3,
  rimLightColor: Color,
  debugView: DebugView,
  cameraPosition: Vec3
): seq[uint32] =
  var writer: Std140Writer
  let material = primitive.material
  if material != nil:
    writer.putTextureTransform(material.baseColorTransform)
    writer.putTextureTransform(material.metallicRoughnessTransform)
    writer.putTextureTransform(material.normalTransform)
    writer.putTextureTransform(material.occlusionTransform)
    writer.putTextureTransform(material.emissiveTransform)
    writer.putColor(material.baseColorFactor)
    writer.putFloat(
      if material.alphaMode == MaskAlphaMode: material.alphaCutoff else: -1.0'f
    )
    writer.putFloat(material.roughnessFactor)
    writer.putFloat(material.metallicFactor)
    writer.putFloat(material.transmissionFactor)
    writer.putFloat(material.occlusionStrength)
    writer.putVec3(vec3(
      material.emissiveFactor.r,
      material.emissiveFactor.g,
      material.emissiveFactor.b
    ))
    writer.putFloat(material.normalScale)
    writer.putBool(
      material.hasNormalTexture and
      primitive.normals.len > 0 and
      primitive.tangents.len > 0
    )
  else:
    let identityTransform = TextureTransform(
      texCoord: 0,
      offset: vec2(0, 0),
      scale: vec2(1, 1),
      rotation: 0.0'f
    )
    writer.putTextureTransform(identityTransform)
    writer.putTextureTransform(identityTransform)
    writer.putTextureTransform(identityTransform)
    writer.putTextureTransform(identityTransform)
    writer.putTextureTransform(identityTransform)
    writer.putColor(color(1, 1, 1, 1))
    writer.putFloat(-1.0'f)
    writer.putFloat(1.0'f)
    writer.putFloat(1.0'f)
    writer.putFloat(0.0'f)
    writer.putFloat(1.0'f)
    writer.putVec3(vec3(0, 0, 0))
    writer.putFloat(1.0'f)
    writer.putBool(false)

  writer.putVec3(sunLightDirection)
  writer.putVec3(rimLightDirection)
  writer.putVec3(cameraPosition)
  writer.putColor(sunLightColor)
  writer.putColor(rimLightColor)
  writer.putFloat(3.0'f)
  writer.putBool(false)
  writer.putFloat(0.0005'f)
  writer.putVec2(vec2(1.0'f / 2048.0'f, 1.0'f / 2048.0'f))
  writer.putInt(debugView.int)
  writer.putColor(tint)
  writer.putColor(ambientLightColor)
  writer.finish()

when defined(macosx):
  proc metalPrimitive(mode: PrimitiveMode): MTLPrimitiveType =
    case mode
    of PointsMode:
      MTLPrimitiveTypePoint
    of LinesMode, LineLoopMode:
      MTLPrimitiveTypeLine
    of LineStripMode:
      MTLPrimitiveTypeLineStrip
    of TrianglesMode, TriangleFanMode:
      MTLPrimitiveTypeTriangle
    of TriangleStripMode:
      MTLPrimitiveTypeTriangleStrip

  proc renderPrimitive(
    renderer: Renderer,
    encoder: MTLRenderCommandEncoder,
    primitive: Primitive,
    owner,
    root: Node,
    transform: Mat4,
    params: RenderParams,
    deferBlend: bool,
    blended: var seq[BlendEntry]
  ) =
    if primitive == nil:
      return
    let isBlend =
      primitive.material != nil and
      primitive.material.alphaMode == BlendAlphaMode
    if deferBlend and isBlend:
      blended.add(
        BlendEntry(
          node: owner,
          primitive: primitive,
          transform: transform
        )
      )
      return
    renderer.ensurePrimitive(primitive)
    renderer.ensureMaterial(primitive.material)

    let data = primitive.data
    if data == nil or data.vertexCount == 0 or data.vertexBuffer.isNil:
      return
    if primitive.mode in {LineLoopMode, TriangleFanMode}:
      return

    if isBlend:
      encoder.setRenderPipelineState(renderer.blendPipelineState)
    else:
      encoder.setRenderPipelineState(renderer.pipelineState)

    var baseColor = renderer.whiteTexture
    var metallicRoughness = renderer.whiteTexture
    var normal = renderer.whiteTexture
    var occlusion = renderer.whiteTexture
    var emissive = renderer.whiteTexture
    if primitive.material != nil and
        primitive.material.data != nil and
        primitive.material.data.baseColor != nil and
        not primitive.material.data.baseColor.texture.isNil:
      baseColor = primitive.material.data.baseColor.texture
    if primitive.material != nil and
        primitive.material.data != nil and
        primitive.material.data.metallicRoughness != nil and
        not primitive.material.data.metallicRoughness.texture.isNil:
      metallicRoughness = primitive.material.data.metallicRoughness.texture
    if primitive.material != nil and
        primitive.material.data != nil and
        primitive.material.data.normal != nil and
        not primitive.material.data.normal.texture.isNil:
      normal = primitive.material.data.normal.texture
    if primitive.material != nil and
        primitive.material.data != nil and
        primitive.material.data.occlusion != nil and
        not primitive.material.data.occlusion.texture.isNil:
      occlusion = primitive.material.data.occlusion.texture
    if primitive.material != nil and
        primitive.material.data != nil and
        primitive.material.data.emissive != nil and
        not primitive.material.data.emissive.texture.isNil:
      emissive = primitive.material.data.emissive.texture

    var vertexConstants = shadyVertexConstants(
      owner,
      root,
      transform,
      params.view,
      params.proj
    )
    var fragmentConstants = shadyFragmentConstants(
      primitive,
      params.tint,
      params.ambientLightColor,
      params.sunLightDirection,
      params.sunLightColor,
      params.rimLightDirection,
      params.rimLightColor,
      params.debugView,
      params.cameraPosition
    )
    encoder.setVertexBuffer(data.vertexBuffer, 0, MetalVertexBufferIndex)
    encoder.setVertexBytes(
      vertexConstants[0].addr,
      (vertexConstants.len * sizeof(uint32)).uint,
      0
    )
    encoder.setFragmentBytes(
      fragmentConstants[0].addr,
      (fragmentConstants.len * sizeof(uint32)).uint,
      1
    )
    encoder.setFragmentTexture(baseColor, 0)
    encoder.setFragmentTexture(metallicRoughness, 1)
    encoder.setFragmentTexture(occlusion, 2)
    encoder.setFragmentTexture(emissive, 3)
    encoder.setFragmentTexture(normal, 4)
    encoder.setFragmentTexture(renderer.environmentTexture, 5)
    encoder.setFragmentTexture(renderer.depthTexture, 6)
    for i in 0 .. 6:
      encoder.setFragmentSamplerState(renderer.sampler, i.uint)
    if primitive.material != nil and primitive.material.doubleSided:
      encoder.setCullMode(MTLCullModeNone)
    else:
      encoder.setCullMode(MTLCullModeBack)
    encoder.drawPrimitives(
      primitive.mode.metalPrimitive(),
      0,
      data.vertexCount.uint
    )

  proc renderNode(
    renderer: Renderer,
    encoder: MTLRenderCommandEncoder,
    node: Node,
    params: RenderParams,
    deferBlend: bool,
    blended: var seq[BlendEntry]
  ) =
    if node == nil or not node.visible:
      return
    if node.mesh != nil:
      for primitive in node.mesh.primitives:
        renderer.renderPrimitive(
          encoder,
          primitive,
          node,
          renderer.scene,
          node.mat,
          params,
          deferBlend,
          blended
        )
    for child in node.nodes:
      renderer.renderNode(encoder, child, params, deferBlend, blended)

  proc encodeScene(
    renderer: Renderer,
    commandBuffer: MTLCommandBuffer,
    colorTexture: MTLTexture,
    width,
    height: int,
    storeDepth: bool
  ) =
    let renderPass = MTLRenderPassDescriptor.renderPassDescriptor()
    let colorAttachment =
      renderPass.colorAttachments().objectAtIndexedSubscript(0)
    colorAttachment.setTexture(colorTexture)
    colorAttachment.setLoadAction(MTLLoadActionClear)
    colorAttachment.setStoreAction(MTLStoreActionStore)
    colorAttachment.setClearColor(renderer.clearColor.toMetalColor())

    let depthAttachment = renderPass.depthAttachment()
    depthAttachment.setTexture(renderer.depthTexture)
    depthAttachment.setLoadAction(MTLLoadActionClear)
    depthAttachment.setStoreAction(
      if storeDepth:
        MTLStoreActionStore
      else:
        MTLStoreActionDontCare
    )
    depthAttachment.setClearDepth(1.0)

    let encoder = commandBuffer.renderCommandEncoderWithDescriptor(renderPass)
    checkNil(encoder, "Could not create a Metal render encoder")
    encoder.setRenderPipelineState(renderer.pipelineState)
    encoder.setViewport(
      MTLViewport(
        originX: 0,
        originY: 0,
        width: width.float64,
        height: height.float64,
        znear: 0,
        zfar: 1
      )
    )
    encoder.setCullMode(MTLCullModeBack)
    encoder.setFrontFacingWinding(MTLWindingCounterClockwise)
    encoder.setDepthStencilState(renderer.depthState)
    if renderer.scene != nil:
      renderer.scene.updateTransforms(
        renderer.params.transform,
        renderer.params.useTrs
      )
      var blended: seq[BlendEntry]
      renderer.renderNode(
        encoder,
        renderer.scene,
        renderer.params,
        deferBlend = true,
        blended = blended
      )
      if blended.len > 0:
        encoder.setDepthStencilState(renderer.depthReadState)
        var sorted = blended
        sorted.sort(proc(a, b: BlendEntry): int =
          let
            pa = (a.transform * vec4(0, 0, 0, 1)).xyz
            pb = (b.transform * vec4(0, 0, 0, 1)).xyz
            da = (renderer.params.cameraPosition - pa).lengthSq
            db = (renderer.params.cameraPosition - pb).lengthSq
          if da > db:
            -1
          elif da < db:
            1
          else:
            0
        )
        for entry in sorted:
          var dummy: seq[BlendEntry]
          renderer.renderPrimitive(
            encoder,
            entry.primitive,
            entry.node,
            renderer.scene,
            entry.transform,
            renderer.params,
            deferBlend = false,
            blended = dummy
          )
        encoder.setDepthStencilState(renderer.depthState)
    encoder.endEncoding()

proc newRenderer*(window: Window): Renderer =
  result = Renderer(
    window: window,
    size: clampSize(window.size),
    clearColor: color(0, 0, 0, 1)
  )
  when defined(macosx):
    result.ctx = newMetalContext(window)
    result.initPipeline()

proc beginFrame*(renderer: Renderer; window: Window; size: IVec2) =
  renderer.window = window
  renderer.size = clampSize(size)
  when defined(macosx):
    renderer.ctx.window = window
    renderer.ctx.updateDrawableSize()

proc clearScreen*(renderer: Renderer; color: ColorRGBX) =
  renderer.clearColor = color.color

proc clearScreen*(renderer: Renderer; color: Color) =
  renderer.clearColor = color

proc render*(renderer: Renderer; node: Node; params: RenderParams) =
  if node != nil:
    renderer.prepareNode(node)
  renderer.scene = node
  renderer.params = params

proc render*(renderer: Renderer; file: GltfFile; params: RenderParams) =
  if file != nil:
    if file.data == nil:
      file.data = GltfFileData()
    file.data.sceneVersion = file.sceneVersion
    renderer.render(file.root, params)

proc endFrame*(renderer: Renderer) =
  when defined(macosx):
    renderer.ctx.window = renderer.window
    let drawable = renderer.ctx.currentDrawable()
    if drawable.isNil:
      return

    let
      drawableSize = renderer.ctx.layer.drawableSize()
      width = max(1, drawableSize.width.int)
      height = max(1, drawableSize.height.int)
    renderer.ensureTargets(width, height)
    let
      commandBuffer = renderer.ctx.newCommandBuffer()
      texture = drawable.texture()
    renderer.encodeScene(commandBuffer, texture, width, height, false)
    commandBuffer.presentDrawable(drawable)
    commandBuffer.commit()
  else:
    discard renderer

proc captureScreenshot*(renderer: Renderer): Image =
  when defined(macosx):
    let
      width = max(1, renderer.size.x.int)
      height = max(1, renderer.size.y.int)
      sampleScale = 4
      renderWidth = width * sampleScale
      renderHeight = height * sampleScale
    renderer.ensureTargets(renderWidth, renderHeight)
    let commandBuffer = renderer.ctx.newCommandBuffer()
    renderer.encodeScene(
      commandBuffer,
      renderer.offscreenTexture,
      renderWidth,
      renderHeight,
      true
    )
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    var pixels = newSeq[uint8](renderWidth * renderHeight * 4)
    renderer.offscreenTexture.getBytes(
      pixels[0].addr,
      (renderWidth * 4).uint,
      MTLRegion(
        origin: MTLOrigin(x: 0, y: 0, z: 0),
        size: MTLSize(
          width: renderWidth.uint,
          height: renderHeight.uint,
          depth: 1
        )
      ),
      0
    )

    let supersampled = newImage(renderWidth, renderHeight)
    for y in 0 ..< renderHeight:
      for x in 0 ..< renderWidth:
        let i = (y * renderWidth + x) * 4
        supersampled[x, y] = rgbx(
          pixels[i + 2],
          pixels[i + 1],
          pixels[i],
          pixels[i + 3]
        )
    result = supersampled.resize(width, height)
  else:
    result = newImage(renderer.size.x.int, renderer.size.y.int)
    result.fill(renderer.clearColor.toRgbx())

proc release*(renderer: Renderer; node: Node) =
  discard renderer
  if node == nil:
    return
  if node.mesh != nil:
    for primitive in node.mesh.primitives:
      primitive.data = nil
      if primitive.material != nil:
        primitive.material.data = nil
  for child in node.nodes:
    renderer.release(child)

proc shutdown*(renderer: Renderer) =
  discard renderer
