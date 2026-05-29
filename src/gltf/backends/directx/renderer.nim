## DirectX backend shader sources and renderer.

when not defined(windows):
  {.error: "The glTF DirectX backend requires Windows.".}

import
  std/[algorithm, math, tables],
  chroma, pixie, vmath, windy,
  pkg/dx12, pkg/dx12/context,
  ../../common, ../../models,
  ./common,
  ../shaders as shaderSources

const
  VertexEntryPoint* = "VSMain"
  FragmentEntryPoint* = "PSMain"

  PbrVertexShader* = shaderSources.PbrVertHlsl
  PbrFragmentShader* = shaderSources.PbrFragHlsl
  SkyboxVertexShader* = shaderSources.SkyboxVertHlsl
  SkyboxFragmentShader* = shaderSources.SkyboxFragHlsl
  ShadowDepthVertexShader* = shaderSources.ShadowDepthVertHlsl
  ShadowDepthFragmentShader* = shaderSources.ShadowDepthFragHlsl

  TextureDescriptorCount = 7
  RootTextureDescriptorCount = 7
  VertexConstantRegisters = 529
  PixelConstantRegisters = 21
  StudioEnvSize = 8
  PreferredMsaaSamples = 8'u32

type
  DxVertex {.packed.} = object
    position: array[3, float32]
    color: array[4, float32]
    normal: array[3, float32]
    uv: array[2, float32]
    tangent: array[4, float32]
    joints: array[4, uint16]
    weights: array[4, float32]
    uv1: array[2, float32]

  RgbaSubresource = object
    width, height: int
    pixels: seq[ColorRGBX]

  BlendEntry = object
    node: Node
    primitive: Primitive
    transform: Mat4

  Renderer* = ref object
    window: Window
    ctx: D3D12Context
    rootSignature: ID3D12RootSignature
    pipelineStates: Table[PipelineKey, ID3D12PipelineState]
    sampleCount: uint32
    msaaColorBuffer: ID3D12Resource
    msaaRtvHeap: ID3D12DescriptorHeap
    msaaRtvHandle: D3D12_CPU_DESCRIPTOR_HANDLE
    depthBuffer: ID3D12Resource
    dsvHeap: ID3D12DescriptorHeap
    dsvHandle: D3D12_CPU_DESCRIPTOR_HANDLE
    readbackBuffer: ID3D12Resource
    readbackFootprint: D3D12_PLACED_SUBRESOURCE_FOOTPRINT
    readbackSize: IVec2
    srvDescriptorSize: UINT
    frameResources: seq[ID3D12Resource]

proc f32bits(value: float32): uint32 =
  cast[uint32](value)

proc putFloat(data: var openArray[uint32], index: int, value: float32) =
  data[index] = value.f32bits

proc putVec2(data: var openArray[uint32], index: int, value: Vec2) =
  data.putFloat(index + 0, value.x)
  data.putFloat(index + 1, value.y)

proc putVec3(data: var openArray[uint32], index: int, value: Vec3) =
  data.putFloat(index + 0, value.x)
  data.putFloat(index + 1, value.y)
  data.putFloat(index + 2, value.z)

proc putColor(data: var openArray[uint32], index: int, value: Color) =
  data.putFloat(index + 0, value.r)
  data.putFloat(index + 1, value.g)
  data.putFloat(index + 2, value.b)
  data.putFloat(index + 3, value.a)

proc putMat4(data: var openArray[uint32], registerIndex: int, value: Mat4) =
  var outIndex = registerIndex * 4
  for i in 0 ..< 4:
    for j in 0 ..< 4:
      data.putFloat(outIndex, value[i, j])
      inc outIndex

proc perspectiveDxRh*(fovY, aspect, nearPlane, farPlane: float32): Mat4 =
  ## DirectX right-handed projection matrix for vmath camera transforms.
  let
    h = 1.0'f32 / tan(degToRad(fovY) * 0.5'f32)
    w = h / aspect
    depth = nearPlane - farPlane
  result[0, 0] = w
  result[1, 1] = h
  result[2, 2] = farPlane / depth
  result[2, 3] = -1.0'f32
  result[3, 2] = (nearPlane * farPlane) / depth

proc bufferDesc(size: uint64): D3D12_RESOURCE_DESC =
  result.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER
  result.Alignment = 0
  result.Width = size
  result.Height = 1
  result.DepthOrArraySize = 1
  result.MipLevels = 1
  result.Format = DXGI_FORMAT_UNKNOWN
  result.SampleDesc = DXGI_SAMPLE_DESC(Count: 1, Quality: 0)
  result.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR
  result.Flags = D3D12_RESOURCE_FLAG_NONE

proc defaultHeap(): D3D12_HEAP_PROPERTIES =
  result.typ = D3D12_HEAP_TYPE_DEFAULT
  result.CPUPageProperty = 0
  result.MemoryPoolPreference = 0
  result.CreationNodeMask = 1
  result.VisibleNodeMask = 1

proc uploadHeap(): D3D12_HEAP_PROPERTIES =
  result.typ = D3D12_HEAP_TYPE_UPLOAD
  result.CPUPageProperty = 0
  result.MemoryPoolPreference = 0
  result.CreationNodeMask = 1
  result.VisibleNodeMask = 1

proc supportsMsaa(device: ID3D12Device, format, sampleCount: uint32): bool =
  var levels = D3D12_FEATURE_DATA_MULTISAMPLE_QUALITY_LEVELS(
    Format: format,
    SampleCount: sampleCount,
    Flags: D3D12_MULTISAMPLE_QUALITY_LEVELS_FLAG_NONE,
    NumQualityLevels: 0
  )
  try:
    device.checkFeatureSupport(
      D3D12_FEATURE_MULTISAMPLE_QUALITY_LEVELS,
      addr levels,
      UINT(sizeof(levels))
    )
    levels.NumQualityLevels > 0
  except:
    false

proc chooseMsaaSampleCount(device: ID3D12Device): uint32 =
  for sampleCount in [PreferredMsaaSamples, 4'u32, 2'u32]:
    if device.supportsMsaa(DXGI_FORMAT_R8G8B8A8_UNORM, sampleCount) and
      device.supportsMsaa(DXGI_FORMAT_D32_FLOAT, sampleCount):
      return sampleCount
  1'u32

proc msaaEnabled(renderer: Renderer): bool =
  renderer.sampleCount > 1

proc readbackHeap(): D3D12_HEAP_PROPERTIES =
  result.typ = D3D12_HEAP_TYPE_READBACK
  result.CPUPageProperty = 0
  result.MemoryPoolPreference = 0
  result.CreationNodeMask = 1
  result.VisibleNodeMask = 1

proc createUploadResource(
  renderer: Renderer,
  byteSize: uint64,
  mapped: var pointer
): ID3D12Resource =
  var
    heap = uploadHeap()
    desc = bufferDesc(max(1'u64, byteSize))
  result = renderer.ctx.device.createCommittedResource(
    addr heap,
    D3D12_HEAP_FLAG_NONE,
    addr desc,
    D3D12_RESOURCE_STATE_GENERIC_READ,
    nil
  )
  result.map(0, nil, addr mapped)

proc alignConstantBufferSize(size: int): int =
  ((max(1, size) + 255) div 256) * 256

proc createFrameConstantBuffer(
  renderer: Renderer,
  data: openArray[uint32]
): uint64 =
  let
    dataBytes = data.len * sizeof(uint32)
    byteSize = alignConstantBufferSize(dataBytes)
  var mapped: pointer
  let resource = renderer.createUploadResource(uint64(byteSize), mapped)
  if dataBytes > 0:
    copyMem(mapped, unsafeAddr data[0], dataBytes)
  if byteSize > dataBytes:
    zeroMem(cast[pointer](cast[uint](mapped) + uint(dataBytes)), byteSize - dataBytes)
  resource.unmap(0, nil)
  renderer.frameResources.add(resource)
  resource.getGPUVirtualAddress()

proc offsetCpuHandle(
  base: D3D12_CPU_DESCRIPTOR_HANDLE,
  descriptorSize: UINT,
  index: int
): D3D12_CPU_DESCRIPTOR_HANDLE =
  result = base
  result.ptrValue = base.ptrValue + uint64(descriptorSize) * uint64(index)

proc textureDesc2D(
  width,
  height: int,
  format: uint32,
  flags = D3D12_RESOURCE_FLAG_NONE,
  mipLevels = 1,
  sampleCount = 1'u32
): D3D12_RESOURCE_DESC =
  result.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D
  result.Alignment = 0
  result.Width = uint64(max(1, width))
  result.Height = UINT(max(1, height))
  result.DepthOrArraySize = 1
  result.MipLevels = uint16(max(1, mipLevels))
  result.Format = format
  result.SampleDesc = DXGI_SAMPLE_DESC(Count: sampleCount, Quality: 0)
  result.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN
  result.Flags = flags

proc textureDescCube(size: int, format: uint32, mipLevels = 1): D3D12_RESOURCE_DESC =
  result = textureDesc2D(size, size, format, mipLevels = mipLevels)
  result.DepthOrArraySize = 6

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
      var
        r, g, b, a, count: uint32
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

proc buildImageMips(image: Image): seq[RgbaSubresource] =
  result = buildMipChain(RgbaSubresource(
    width: image.width,
    height: image.height,
    pixels: image.data
  ))

proc studioFaceDirection(face, x, y, size: int): Vec3 =
  let
    u = ((x.float32 + 0.5'f32) / size.float32) * 2.0'f32 - 1.0'f32
    v = ((y.float32 + 0.5'f32) / size.float32) * 2.0'f32 - 1.0'f32
  case face
  of 0:
    normalize(vec3(1.0'f32, -v, -u))
  of 1:
    normalize(vec3(-1.0'f32, -v, u))
  of 2:
    normalize(vec3(u, 1.0'f32, v))
  of 3:
    normalize(vec3(u, -1.0'f32, -v))
  of 4:
    normalize(vec3(u, -v, 1.0'f32))
  of 5:
    normalize(vec3(-u, -v, -1.0'f32))
  else:
    vec3(0, 1, 0)

proc studioColor(dir: Vec3): ColorRGBX =
  let
    hemi = clamp(dir.y * 0.5'f32 + 0.5'f32, 0.0'f32, 1.0'f32)
    keyDir = normalize(vec3(0.35'f32, 0.85'f32, 0.25'f32))
    fillDir = normalize(vec3(-0.45'f32, 0.65'f32, -0.35'f32))
    key = pow(max(dot(dir, keyDir), 0.0'f32), 24.0'f32)
    fill = pow(max(dot(dir, fillDir), 0.0'f32), 8.0'f32)
    cool = vec3(0.18'f32, 0.19'f32, 0.21'f32)
    neutral = vec3(0.58'f32, 0.6'f32, 0.63'f32)
    sky = vec3(0.92'f32, 0.94'f32, 0.97'f32)
  var color = mix(cool, neutral, hemi)
  color = mix(color, sky, hemi * hemi)
  color += vec3(0.28'f32, 0.27'f32, 0.25'f32) * key
  color += vec3(0.10'f32, 0.11'f32, 0.12'f32) * fill
  rgbx(
    uint8(clamp((color.x * 255.0'f32).int, 0, 255)),
    uint8(clamp((color.y * 255.0'f32).int, 0, 255)),
    uint8(clamp((color.z * 255.0'f32).int, 0, 255)),
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

proc executeUpload(renderer: Renderer) =
  renderer.ctx.commandList.close()
  var cmdList = cast[ID3D12CommandList](renderer.ctx.commandList)
  renderer.ctx.commandQueue.executeCommandLists(1, addr cmdList)
  renderer.ctx.waitForGpu()

proc uploadTextureBytes(
  renderer: Renderer,
  desc: var D3D12_RESOURCE_DESC,
  pixels: pointer,
  srcRowSize: int,
  srcRowCount: int,
  format: uint32,
  isCube = false
): DxTexture =
  var heap = defaultHeap()
  let resource = renderer.ctx.device.createCommittedResource(
    addr heap,
    D3D12_HEAP_FLAG_NONE,
    addr desc,
    D3D12_RESOURCE_STATE_COPY_DEST,
    nil
  )

  var
    footprints = newSeq[D3D12_PLACED_SUBRESOURCE_FOOTPRINT](int(desc.DepthOrArraySize))
    numRows = newSeq[UINT](int(desc.DepthOrArraySize))
    rowSizes = newSeq[UINT64](int(desc.DepthOrArraySize))
    totalBytes: UINT64
  renderer.ctx.device.getCopyableFootprints(
    addr desc,
    0,
    UINT(desc.DepthOrArraySize),
    0'u64,
    addr footprints[0],
    addr numRows[0],
    addr rowSizes[0],
    addr totalBytes
  )

  var
    uploadDesc = bufferDesc(totalBytes)
    uploadHeapProps = uploadHeap()
  let uploadBuffer = renderer.ctx.device.createCommittedResource(
    addr uploadHeapProps,
    D3D12_HEAP_FLAG_NONE,
    addr uploadDesc,
    D3D12_RESOURCE_STATE_GENERIC_READ,
    nil
  )

  var uploadPtr: pointer
  uploadBuffer.map(0, nil, addr uploadPtr)
  let uploadBase = cast[uint](uploadPtr)
  let sourceBase = cast[uint](pixels)
  for face in 0 ..< int(desc.DepthOrArraySize):
    let rowPitch = int(footprints[face].Footprint.RowPitch)
    var dst = cast[ptr uint8](uploadBase + uint(footprints[face].Offset))
    let faceBase = sourceBase + uint(face * srcRowSize * srcRowCount)
    for y in 0 ..< srcRowCount:
      let src = cast[pointer](faceBase + uint(y * srcRowSize))
      copyMem(dst, src, srcRowSize)
      if rowPitch > srcRowSize:
        zeroMem(
          cast[pointer](cast[uint](dst) + uint(srcRowSize)),
          rowPitch - srcRowSize
        )
      dst = cast[ptr uint8](cast[uint](dst) + uint(rowPitch))
  uploadBuffer.unmap(0, nil)

  renderer.ctx.commandAllocator.reset()
  renderer.ctx.commandList.reset(renderer.ctx.commandAllocator, nil)
  for subresource in 0 ..< int(desc.DepthOrArraySize):
    var dstLocation = D3D12_TEXTURE_COPY_LOCATION(
      pResource: resource,
      typ: D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX,
      data: D3D12_TEXTURE_COPY_LOCATION_UNION(SubresourceIndex: uint32(subresource))
    )
    var srcLocation = D3D12_TEXTURE_COPY_LOCATION(
      pResource: uploadBuffer,
      typ: D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT,
      data: D3D12_TEXTURE_COPY_LOCATION_UNION(PlacedFootprint: footprints[subresource])
    )
    renderer.ctx.commandList.copyTextureRegion(
      addr dstLocation,
      0,
      0,
      0,
      addr srcLocation,
      nil
    )

  var barrier = D3D12_RESOURCE_BARRIER(
    typ: D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
    Flags: D3D12_RESOURCE_BARRIER_FLAG_NONE,
    data: D3D12_RESOURCE_BARRIER_union(Transition: D3D12_RESOURCE_TRANSITION_BARRIER(
      pResource: resource,
      Subresource: D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
      StateBefore: D3D12_RESOURCE_STATE_COPY_DEST,
      StateAfter: D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE
    ))
  )
  renderer.ctx.commandList.resourceBarrier(1, addr barrier)
  renderer.executeUpload()
  uploadBuffer.release()

  DxTexture(resource: resource, format: format, isCube: isCube, mipLevels: 1)

proc uploadRgbaSubresources(
  renderer: Renderer,
  desc: var D3D12_RESOURCE_DESC,
  subresources: openArray[RgbaSubresource],
  isCube = false
): DxTexture =
  var heap = defaultHeap()
  let resource = renderer.ctx.device.createCommittedResource(
    addr heap,
    D3D12_HEAP_FLAG_NONE,
    addr desc,
    D3D12_RESOURCE_STATE_COPY_DEST,
    nil
  )

  let subresourceCount = int(desc.DepthOrArraySize) * int(desc.MipLevels)
  var
    footprints = newSeq[D3D12_PLACED_SUBRESOURCE_FOOTPRINT](subresourceCount)
    numRows = newSeq[UINT](subresourceCount)
    rowSizes = newSeq[UINT64](subresourceCount)
    totalBytes: UINT64
  renderer.ctx.device.getCopyableFootprints(
    addr desc,
    0,
    UINT(subresourceCount),
    0'u64,
    addr footprints[0],
    addr numRows[0],
    addr rowSizes[0],
    addr totalBytes
  )

  var
    uploadDesc = bufferDesc(totalBytes)
    uploadHeapProps = uploadHeap()
  let uploadBuffer = renderer.ctx.device.createCommittedResource(
    addr uploadHeapProps,
    D3D12_HEAP_FLAG_NONE,
    addr uploadDesc,
    D3D12_RESOURCE_STATE_GENERIC_READ,
    nil
  )

  var uploadPtr: pointer
  uploadBuffer.map(0, nil, addr uploadPtr)
  let uploadBase = cast[uint](uploadPtr)
  for subresource in 0 ..< subresourceCount:
    let
      source = subresources[subresource]
      srcRowSize = source.width * 4
      rowPitch = int(footprints[subresource].Footprint.RowPitch)
    var dst = cast[ptr uint8](uploadBase + uint(footprints[subresource].Offset))
    for y in 0 ..< source.height:
      let src = cast[pointer](
        cast[uint](unsafeAddr source.pixels[0]) + uint(y * srcRowSize)
      )
      copyMem(dst, src, srcRowSize)
      if rowPitch > srcRowSize:
        zeroMem(
          cast[pointer](cast[uint](dst) + uint(srcRowSize)),
          rowPitch - srcRowSize
        )
      dst = cast[ptr uint8](cast[uint](dst) + uint(rowPitch))
  uploadBuffer.unmap(0, nil)

  renderer.ctx.commandAllocator.reset()
  renderer.ctx.commandList.reset(renderer.ctx.commandAllocator, nil)
  for subresource in 0 ..< subresourceCount:
    var dstLocation = D3D12_TEXTURE_COPY_LOCATION(
      pResource: resource,
      typ: D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX,
      data: D3D12_TEXTURE_COPY_LOCATION_UNION(SubresourceIndex: uint32(subresource))
    )
    var srcLocation = D3D12_TEXTURE_COPY_LOCATION(
      pResource: uploadBuffer,
      typ: D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT,
      data: D3D12_TEXTURE_COPY_LOCATION_UNION(PlacedFootprint: footprints[subresource])
    )
    renderer.ctx.commandList.copyTextureRegion(
      addr dstLocation,
      0,
      0,
      0,
      addr srcLocation,
      nil
    )

  var barrier = D3D12_RESOURCE_BARRIER(
    typ: D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
    Flags: D3D12_RESOURCE_BARRIER_FLAG_NONE,
    data: D3D12_RESOURCE_BARRIER_union(Transition: D3D12_RESOURCE_TRANSITION_BARRIER(
      pResource: resource,
      Subresource: D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
      StateBefore: D3D12_RESOURCE_STATE_COPY_DEST,
      StateAfter: D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE
    ))
  )
  renderer.ctx.commandList.resourceBarrier(1, addr barrier)
  renderer.executeUpload()
  uploadBuffer.release()

  DxTexture(
    resource: resource,
    format: desc.Format,
    isCube: isCube,
    mipLevels: int(desc.MipLevels)
  )

proc uploadImage(renderer: Renderer, image: Image): DxTexture =
  let mips = image.buildImageMips()
  var desc = textureDesc2D(
    image.width,
    image.height,
    DXGI_FORMAT_R8G8B8A8_UNORM,
    mipLevels = mips.len
  )
  renderer.uploadRgbaSubresources(desc, mips)

proc uploadSolidImage(renderer: Renderer, color: ColorRGBX): DxTexture =
  var image = newImage(1, 1)
  image.fill(color)
  renderer.uploadImage(image)

proc uploadStudioCube(renderer: Renderer): DxTexture =
  let mips = buildStudioCubeMips()
  var desc = textureDescCube(
    StudioEnvSize,
    DXGI_FORMAT_R8G8B8A8_UNORM,
    mips.len div 6
  )
  renderer.uploadRgbaSubresources(desc, mips, isCube = true)

proc uploadShadowPlaceholder(renderer: Renderer): DxTexture =
  var pixel = 1.0'f32
  var desc = textureDesc2D(1, 1, DXGI_FORMAT_R32_FLOAT)
  renderer.uploadTextureBytes(
    desc,
    addr pixel,
    sizeof(float32),
    1,
    DXGI_FORMAT_R32_FLOAT
  )

proc createSrv(
  renderer: Renderer,
  texture: DxTexture,
  handle: D3D12_CPU_DESCRIPTOR_HANDLE
) =
  var srvDesc: D3D12_SHADER_RESOURCE_VIEW_DESC
  srvDesc.Format = texture.format
  srvDesc.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING
  if texture.isCube:
    srvDesc.ViewDimension = D3D12_SRV_DIMENSION_TEXTURECUBE
    srvDesc.data = D3D12_SHADER_RESOURCE_VIEW_DESC_UNION(
      TextureCube: D3D12_TEXCUBE_SRV(
        MostDetailedMip: 0,
        MipLevels: UINT(texture.mipLevels),
        ResourceMinLODClamp: 0.0
      )
    )
  else:
    srvDesc.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D
    srvDesc.data = D3D12_SHADER_RESOURCE_VIEW_DESC_UNION(
      Texture2D: D3D12_TEX2D_SRV(
        MostDetailedMip: 0,
        MipLevels: UINT(texture.mipLevels),
        PlaneSlice: 0,
        ResourceMinLODClamp: 0.0
      )
    )
  renderer.ctx.device.createShaderResourceView(
    texture.resource,
    addr srvDesc,
    handle
  )

proc createColorBuffer(renderer: Renderer, size: IVec2) =
  if renderer.msaaColorBuffer != nil:
    renderer.msaaColorBuffer.release()
    renderer.msaaColorBuffer = nil
  if renderer.msaaRtvHeap != nil:
    renderer.msaaRtvHeap.release()
    renderer.msaaRtvHeap = nil
  if not renderer.msaaEnabled:
    return

  var rtvHeapDesc = D3D12_DESCRIPTOR_HEAP_DESC(
    typ: D3D12_DESCRIPTOR_HEAP_TYPE_RTV,
    NumDescriptors: 1,
    Flags: D3D12_DESCRIPTOR_HEAP_FLAG_NONE,
    NodeMask: 0
  )
  renderer.msaaRtvHeap =
    renderer.ctx.device.createDescriptorHeap(addr rtvHeapDesc)
  renderer.msaaRtvHandle =
    renderer.msaaRtvHeap.getCPUDescriptorHandleForHeapStart()

  var colorDesc = textureDesc2D(
    size.x.int,
    size.y.int,
    DXGI_FORMAT_R8G8B8A8_UNORM,
    D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,
    sampleCount = renderer.sampleCount
  )
  var
    heap = defaultHeap()
    clearColor = [0.0.FLOAT, 0.0.FLOAT, 0.0.FLOAT, 1.0.FLOAT]
    clearValue = D3D12_CLEAR_VALUE(
      Format: DXGI_FORMAT_R8G8B8A8_UNORM,
      data: D3D12_CLEAR_VALUE_UNION(Color: clearColor)
    )
  renderer.msaaColorBuffer = renderer.ctx.device.createCommittedResource(
    addr heap,
    D3D12_HEAP_FLAG_NONE,
    addr colorDesc,
    D3D12_RESOURCE_STATE_RENDER_TARGET,
    addr clearValue
  )
  renderer.ctx.device.createRenderTargetView(
    renderer.msaaColorBuffer,
    nil,
    renderer.msaaRtvHandle
  )

proc createDepthBuffer(renderer: Renderer, size: IVec2) =
  if renderer.depthBuffer != nil:
    renderer.depthBuffer.release()
    renderer.depthBuffer = nil
  if renderer.dsvHeap != nil:
    renderer.dsvHeap.release()
    renderer.dsvHeap = nil

  var dsvHeapDesc = D3D12_DESCRIPTOR_HEAP_DESC(
    typ: D3D12_DESCRIPTOR_HEAP_TYPE_DSV,
    NumDescriptors: 1,
    Flags: D3D12_DESCRIPTOR_HEAP_FLAG_NONE,
    NodeMask: 0
  )
  renderer.dsvHeap = renderer.ctx.device.createDescriptorHeap(addr dsvHeapDesc)
  renderer.dsvHandle = renderer.dsvHeap.getCPUDescriptorHandleForHeapStart()

  var depthDesc = textureDesc2D(
    size.x.int,
    size.y.int,
    DXGI_FORMAT_D32_FLOAT,
    D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL,
    sampleCount = renderer.sampleCount
  )
  var heap = defaultHeap()
  var clearValue = D3D12_CLEAR_VALUE(
    Format: DXGI_FORMAT_D32_FLOAT,
    data: D3D12_CLEAR_VALUE_UNION(
      DepthStencil: D3D12_DEPTH_STENCIL_VALUE(Depth: 1.0'f32, Stencil: 0)
    )
  )
  renderer.depthBuffer = renderer.ctx.device.createCommittedResource(
    addr heap,
    D3D12_HEAP_FLAG_NONE,
    addr depthDesc,
    D3D12_RESOURCE_STATE_DEPTH_WRITE,
    addr clearValue
  )
  renderer.ctx.device.createDepthStencilView(
    renderer.depthBuffer,
    nil,
    renderer.dsvHandle
  )

proc createReadbackBuffer(renderer: Renderer, size: IVec2) =
  if renderer.readbackBuffer != nil:
    renderer.readbackBuffer.release()
    renderer.readbackBuffer = nil

  var readbackDesc = textureDesc2D(
    size.x.int,
    size.y.int,
    DXGI_FORMAT_R8G8B8A8_UNORM
  )
  var
    numRows: UINT
    rowSize: UINT64
    totalBytes: UINT64
  renderer.ctx.device.getCopyableFootprints(
    addr readbackDesc,
    0,
    1,
    0'u64,
    addr renderer.readbackFootprint,
    addr numRows,
    addr rowSize,
    addr totalBytes
  )

  var
    heap = readbackHeap()
    desc = bufferDesc(totalBytes)
  renderer.readbackBuffer = renderer.ctx.device.createCommittedResource(
    addr heap,
    D3D12_HEAP_FLAG_NONE,
    addr desc,
    D3D12_RESOURCE_STATE_COPY_DEST,
    nil
  )
  renderer.readbackSize = size

proc createPipeline(
  renderer: Renderer,
  key: PipelineKey,
  vsCode,
  psCode: string
): ID3D12PipelineState =
  let
    vsBlob = compileShader(vsCode, VertexEntryPoint, "vs_5_0")
    psBlob = compileShader(psCode, FragmentEntryPoint, "ps_5_0")

  var inputElements = [
    D3D12_INPUT_ELEMENT_DESC(
      SemanticName: "POSITION",
      SemanticIndex: 0,
      Format: DXGI_FORMAT_R32G32B32_FLOAT,
      InputSlot: 0,
      AlignedByteOffset: 0,
      InputSlotClass: D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,
      InstanceDataStepRate: 0
    ),
    D3D12_INPUT_ELEMENT_DESC(
      SemanticName: "COLOR",
      SemanticIndex: 0,
      Format: DXGI_FORMAT_R32G32B32A32_FLOAT,
      InputSlot: 0,
      AlignedByteOffset: 12,
      InputSlotClass: D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,
      InstanceDataStepRate: 0
    ),
    D3D12_INPUT_ELEMENT_DESC(
      SemanticName: "NORMAL",
      SemanticIndex: 0,
      Format: DXGI_FORMAT_R32G32B32_FLOAT,
      InputSlot: 0,
      AlignedByteOffset: 28,
      InputSlotClass: D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,
      InstanceDataStepRate: 0
    ),
    D3D12_INPUT_ELEMENT_DESC(
      SemanticName: "TEXCOORD",
      SemanticIndex: 0,
      Format: DXGI_FORMAT_R32G32_FLOAT,
      InputSlot: 0,
      AlignedByteOffset: 40,
      InputSlotClass: D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,
      InstanceDataStepRate: 0
    ),
    D3D12_INPUT_ELEMENT_DESC(
      SemanticName: "TEXCOORD",
      SemanticIndex: 1,
      Format: DXGI_FORMAT_R32G32B32A32_FLOAT,
      InputSlot: 0,
      AlignedByteOffset: 48,
      InputSlotClass: D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,
      InstanceDataStepRate: 0
    ),
    D3D12_INPUT_ELEMENT_DESC(
      SemanticName: "TEXCOORD",
      SemanticIndex: 2,
      Format: DXGI_FORMAT_R16G16B16A16_UINT,
      InputSlot: 0,
      AlignedByteOffset: 64,
      InputSlotClass: D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,
      InstanceDataStepRate: 0
    ),
    D3D12_INPUT_ELEMENT_DESC(
      SemanticName: "TEXCOORD",
      SemanticIndex: 3,
      Format: DXGI_FORMAT_R32G32B32A32_FLOAT,
      InputSlot: 0,
      AlignedByteOffset: 72,
      InputSlotClass: D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,
      InstanceDataStepRate: 0
    ),
    D3D12_INPUT_ELEMENT_DESC(
      SemanticName: "TEXCOORD",
      SemanticIndex: 4,
      Format: DXGI_FORMAT_R32G32_FLOAT,
      InputSlot: 0,
      AlignedByteOffset: 88,
      InputSlotClass: D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,
      InstanceDataStepRate: 0
    )
  ]

  var blendDesc: D3D12_BLEND_DESC
  blendDesc.AlphaToCoverageEnable = 0
  blendDesc.IndependentBlendEnable = 0
  blendDesc.RenderTarget[0] = D3D12_RENDER_TARGET_BLEND_DESC(
    BlendEnable: if key.blended: 1 else: 0,
    LogicOpEnable: 0,
    SrcBlend: if key.blended: D3D12_BLEND_SRC_ALPHA else: D3D12_BLEND_ONE,
    DestBlend: if key.blended: D3D12_BLEND_INV_SRC_ALPHA else: D3D12_BLEND_ZERO,
    BlendOp: D3D12_BLEND_OP_ADD,
    SrcBlendAlpha: D3D12_BLEND_ONE,
    DestBlendAlpha: if key.blended: D3D12_BLEND_INV_SRC_ALPHA else: D3D12_BLEND_ZERO,
    BlendOpAlpha: D3D12_BLEND_OP_ADD,
    LogicOp: 0,
    RenderTargetWriteMask: uint8(D3D12_COLOR_WRITE_ENABLE_ALL)
  )

  let depthOp = D3D12_DEPTH_STENCILOP_DESC(
    StencilFailOp: D3D12_STENCIL_OP_KEEP,
    StencilDepthFailOp: D3D12_STENCIL_OP_KEEP,
    StencilPassOp: D3D12_STENCIL_OP_KEEP,
    StencilFunc: D3D12_COMPARISON_FUNC_ALWAYS
  )

  var psoDesc = D3D12_GRAPHICS_PIPELINE_STATE_DESC(
    pRootSignature: renderer.rootSignature,
    VS: shaderBytecode(vsBlob),
    PS: shaderBytecode(psBlob),
    StreamOutput: D3D12_STREAM_OUTPUT_DESC(),
    BlendState: blendDesc,
    SampleMask: D3D12_DEFAULT_SAMPLE_MASK,
    RasterizerState: D3D12_RASTERIZER_DESC(
      FillMode: D3D12_FILL_MODE_SOLID,
      CullMode: if key.doubleSided: D3D12_CULL_MODE_NONE else: D3D12_CULL_MODE_BACK,
      FrontCounterClockwise: 1,
      DepthBias: 0,
      DepthBiasClamp: 0.0,
      SlopeScaledDepthBias: 0.0,
      DepthClipEnable: 1,
      MultisampleEnable: if renderer.msaaEnabled: 1 else: 0,
      AntialiasedLineEnable: 0,
      ForcedSampleCount: 0,
      ConservativeRaster: D3D12_CONSERVATIVE_RASTERIZATION_MODE_OFF
    ),
    DepthStencilState: D3D12_DEPTH_STENCIL_DESC(
      DepthEnable: 1,
      DepthWriteMask:
        if key.blended: D3D12_DEPTH_WRITE_MASK_ZERO
        else: D3D12_DEPTH_WRITE_MASK_ALL,
      DepthFunc: D3D12_COMPARISON_FUNC_LESS,
      StencilEnable: 0,
      StencilReadMask: 0xff'u8,
      StencilWriteMask: 0xff'u8,
      FrontFace: depthOp,
      BackFace: depthOp
    ),
    InputLayout: D3D12_INPUT_LAYOUT_DESC(
      pInputElementDescs: addr inputElements[0],
      NumElements: uint32(inputElements.len)
    ),
    IBStripCutValue: 0,
    PrimitiveTopologyType:
      case key.topology
      of dtPoint: D3D12_PRIMITIVE_TOPOLOGY_TYPE_POINT
      of dtLine: D3D12_PRIMITIVE_TOPOLOGY_TYPE_LINE
      of dtTriangle: D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE,
    NumRenderTargets: 1,
    DSVFormat: DXGI_FORMAT_D32_FLOAT,
    SampleDesc: DXGI_SAMPLE_DESC(Count: renderer.sampleCount, Quality: 0),
    NodeMask: 0,
    CachedPSO: D3D12_CACHED_PIPELINE_STATE(),
    Flags: 0
  )
  psoDesc.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM
  result = renderer.ctx.device.createGraphicsPipelineState(addr psoDesc)
  release(vsBlob)
  release(psBlob)

proc getPipeline(renderer: Renderer, key: PipelineKey): ID3D12PipelineState =
  if key notin renderer.pipelineStates:
    renderer.pipelineStates[key] = renderer.createPipeline(
      key,
      PbrVertexShader,
      PbrFragmentShader
    )
  renderer.pipelineStates[key]

proc createRootSignature(renderer: Renderer) =
  var srvRange = D3D12_DESCRIPTOR_RANGE(
    RangeType: D3D12_DESCRIPTOR_RANGE_TYPE_SRV,
    NumDescriptors: RootTextureDescriptorCount,
    BaseShaderRegister: 0,
    RegisterSpace: 0,
    OffsetInDescriptorsFromTableStart: D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND
  )
  var rootParams = [
    D3D12_ROOT_PARAMETER(
      ParameterType: D3D12_ROOT_PARAMETER_TYPE_CBV,
      data: D3D12_ROOT_PARAMETER_UNION(
        Descriptor: D3D12_ROOT_DESCRIPTOR(
          ShaderRegister: 0,
          RegisterSpace: 0
        )
      ),
      ShaderVisibility: D3D12_SHADER_VISIBILITY_VERTEX
    ),
    D3D12_ROOT_PARAMETER(
      ParameterType: D3D12_ROOT_PARAMETER_TYPE_CBV,
      data: D3D12_ROOT_PARAMETER_UNION(
        Descriptor: D3D12_ROOT_DESCRIPTOR(
          ShaderRegister: 1,
          RegisterSpace: 0
        )
      ),
      ShaderVisibility: D3D12_SHADER_VISIBILITY_PIXEL
    ),
    D3D12_ROOT_PARAMETER(
      ParameterType: D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE,
      data: D3D12_ROOT_PARAMETER_UNION(
        DescriptorTable: D3D12_ROOT_DESCRIPTOR_TABLE(
          NumDescriptorRanges: 1,
          pDescriptorRanges: addr srvRange
        )
      ),
      ShaderVisibility: D3D12_SHADER_VISIBILITY_PIXEL
    )
  ]

  var samplers: array[RootTextureDescriptorCount, D3D12_STATIC_SAMPLER_DESC]
  for i in 0 ..< samplers.len:
    samplers[i] = D3D12_STATIC_SAMPLER_DESC(
      Filter:
        if i == 6: D3D12_FILTER_COMPARISON_MIN_MAG_LINEAR_MIP_POINT
        else: D3D12_FILTER_MIN_MAG_MIP_LINEAR,
      AddressU:
        if i == 5 or i == 6: D3D12_TEXTURE_ADDRESS_MODE_CLAMP
        else: D3D12_TEXTURE_ADDRESS_MODE_WRAP,
      AddressV:
        if i == 5 or i == 6: D3D12_TEXTURE_ADDRESS_MODE_CLAMP
        else: D3D12_TEXTURE_ADDRESS_MODE_WRAP,
      AddressW:
        if i == 5 or i == 6: D3D12_TEXTURE_ADDRESS_MODE_CLAMP
        else: D3D12_TEXTURE_ADDRESS_MODE_WRAP,
      MipLODBias: 0.0,
      MaxAnisotropy: 1,
      ComparisonFunc:
        if i == 6: D3D12_COMPARISON_FUNC_LESS_EQUAL
        else: D3D12_COMPARISON_FUNC_ALWAYS,
      BorderColor: D3D12_STATIC_BORDER_COLOR_OPAQUE_WHITE,
      MinLOD: 0.0,
      MaxLOD: 1000.0,
      ShaderRegister: uint32(i),
      RegisterSpace: 0,
      ShaderVisibility: D3D12_SHADER_VISIBILITY_PIXEL
    )
  var rootDesc = D3D12_ROOT_SIGNATURE_DESC(
    NumParameters: uint32(rootParams.len),
    pParameters: addr rootParams[0],
    NumStaticSamplers: uint32(samplers.len),
    pStaticSamplers: addr samplers[0],
    Flags: D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT
  )
  let rootBlob = serializeRootSignature(addr rootDesc)
  renderer.rootSignature = renderer.ctx.device.createRootSignature(
    0,
    getBufferPointer(rootBlob),
    getBufferSize(rootBlob)
  )
  release(rootBlob)

proc newRenderer*(window: Window): Renderer =
  ## Creates a DirectX 12 renderer bound to a Windy window.
  let safeSize = ivec2(max(1'i32, window.size.x), max(1'i32, window.size.y))
  result = Renderer(window: window)
  let hwnd = window.getHWND()
  if hwnd == 0:
    raise newException(GltfError, "Failed to acquire HWND for DirectX renderer.")
  result.ctx.initDevice(hwnd, safeSize.x.int, safeSize.y.int)
  result.sampleCount = chooseMsaaSampleCount(result.ctx.device)
  result.srvDescriptorSize =
    result.ctx.device.getDescriptorHandleIncrementSize(
      D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV
    )
  result.createRootSignature()
  result.createColorBuffer(safeSize)
  result.createDepthBuffer(safeSize)
  result.createReadbackBuffer(safeSize)

proc releaseTexture(texture: DxTexture) =
  if texture != nil and texture.resource != nil:
    texture.resource.release()
    texture.resource = nil

proc releaseMaterial(material: DxMaterial) =
  if material == nil:
    return
  for texture in material.textures:
    texture.releaseTexture()
  material.textures.setLen(0)
  if material.heap != nil:
    material.heap.release()
    material.heap = nil

proc releasePrimitive(primitive: DxPrimitive) =
  if primitive == nil:
    return
  if primitive.vertexBuffer != nil:
    if primitive.vertexBufferPtr != nil:
      primitive.vertexBuffer.unmap(0, nil)
      primitive.vertexBufferPtr = nil
    primitive.vertexBuffer.release()
    primitive.vertexBuffer = nil
  if primitive.indexBuffer != nil:
    if primitive.indexBufferPtr != nil:
      primitive.indexBuffer.unmap(0, nil)
      primitive.indexBufferPtr = nil
    primitive.indexBuffer.release()
    primitive.indexBuffer = nil

proc resize(renderer: Renderer, size: IVec2) =
  let safeSize = ivec2(max(1'i32, size.x), max(1'i32, size.y))
  if renderer.readbackSize == safeSize:
    return
  renderer.ctx.resize(safeSize.x.int, safeSize.y.int)
  renderer.createColorBuffer(safeSize)
  renderer.createDepthBuffer(safeSize)
  renderer.createReadbackBuffer(safeSize)

proc vertexAt(primitive: Primitive, index: int): DxVertex =
  let colorValue =
    if index < primitive.colors.len:
      primitive.colors[index].color
    else:
      color(1, 1, 1, 1)
  result.position = [
    primitive.points[index].x,
    primitive.points[index].y,
    primitive.points[index].z
  ]
  result.color = [
    colorValue.r,
    colorValue.g,
    colorValue.b,
    colorValue.a
  ]
  let normal =
    if index < primitive.normals.len:
      primitive.normals[index]
    else:
      vec3(0, 0, 0)
  result.normal = [normal.x, normal.y, normal.z]
  let uv =
    if index < primitive.uvs.len:
      primitive.uvs[index]
    else:
      vec2(0, 0)
  result.uv = [uv.x, uv.y]
  let tangent =
    if index < primitive.tangents.len:
      primitive.tangents[index]
    else:
      vec4(1, 0, 0, 1)
  result.tangent = [tangent.x, tangent.y, tangent.z, tangent.w]
  let joints =
    if index < primitive.jointIds.len:
      primitive.jointIds[index]
    else:
      [0'u16, 0'u16, 0'u16, 0'u16]
  result.joints = joints
  let weights =
    if index < primitive.jointWeights.len:
      primitive.jointWeights[index]
    else:
      vec4(0, 0, 0, 0)
  result.weights = [weights.x, weights.y, weights.z, weights.w]
  let uv1 =
    if index < primitive.uvs1.len:
      primitive.uvs1[index]
    else:
      vec2(0, 0)
  result.uv1 = [uv1.x, uv1.y]

proc primitiveSourceIndices(primitive: Primitive): seq[uint32] =
  if primitive.indices32.len > 0:
    result = primitive.indices32
  elif primitive.indices16.len > 0:
    result.setLen(primitive.indices16.len)
    for i, value in primitive.indices16:
      result[i] = value.uint32
  else:
    result.setLen(primitive.points.len)
    for i in 0 ..< primitive.points.len:
      result[i] = i.uint32

proc buildIndexData(
  primitive: Primitive,
  topology: var uint32,
  topologyKind: var DxTopology
): seq[uint32] =
  let src = primitive.primitiveSourceIndices()
  case primitive.mode.int
  of 0: # GL_POINTS
    topology = D3D_PRIMITIVE_TOPOLOGY_POINTLIST
    topologyKind = dtPoint
    result = src
  of 1: # GL_LINES
    topology = D3D_PRIMITIVE_TOPOLOGY_LINELIST
    topologyKind = dtLine
    result = src
  of 3: # GL_LINE_STRIP
    topology = D3D_PRIMITIVE_TOPOLOGY_LINESTRIP
    topologyKind = dtLine
    result = src
  of 2: # GL_LINE_LOOP
    topology = D3D_PRIMITIVE_TOPOLOGY_LINELIST
    topologyKind = dtLine
    if src.len >= 2:
      for i in 0 ..< src.len:
        result.add(src[i])
        result.add(src[(i + 1) mod src.len])
  of 5: # GL_TRIANGLE_STRIP
    topology = D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP
    topologyKind = dtTriangle
    result = src
  of 6: # GL_TRIANGLE_FAN
    topology = D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST
    topologyKind = dtTriangle
    if src.len >= 3:
      for i in 1 ..< src.len - 1:
        result.add(src[0])
        result.add(src[i])
        result.add(src[i + 1])
  else:
    topology = D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST
    topologyKind = dtTriangle
    result = src

proc ensurePrimitive(renderer: Renderer, primitive: Primitive): DxPrimitive =
  if primitive.normals.len == 0 and primitive.mode.int == 4:
    primitive.computeSmoothNormals()

  if primitive.data == nil:
    primitive.data = DxPrimitive()
  result = primitive.data

  if primitive.points.len > result.vertexCapacity:
    if result.vertexBuffer != nil:
      if result.vertexBufferPtr != nil:
        result.vertexBuffer.unmap(0, nil)
      result.vertexBuffer.release()
    result.vertexCapacity = max(primitive.points.len, 1)
    result.vertexBuffer = renderer.createUploadResource(
      uint64(result.vertexCapacity * sizeof(DxVertex)),
      result.vertexBufferPtr
    )
    result.vertexBufferView = D3D12_VERTEX_BUFFER_VIEW(
      BufferLocation: result.vertexBuffer.getGPUVirtualAddress(),
      SizeInBytes: UINT(result.vertexCapacity * sizeof(DxVertex)),
      StrideInBytes: UINT(sizeof(DxVertex))
    )

  var vertices = newSeq[DxVertex](primitive.points.len)
  for i in 0 ..< primitive.points.len:
    vertices[i] = primitive.vertexAt(i)
  if vertices.len > 0:
    copyMem(
      result.vertexBufferPtr,
      unsafeAddr vertices[0],
      vertices.len * sizeof(DxVertex)
    )

  var topology: uint32
  var topologyKind: DxTopology
  let indices = primitive.buildIndexData(topology, topologyKind)
  result.topology = topology
  result.topologyKind = topologyKind
  result.indexCount = indices.len
  if indices.len > result.indexCapacity:
    if result.indexBuffer != nil:
      if result.indexBufferPtr != nil:
        result.indexBuffer.unmap(0, nil)
      result.indexBuffer.release()
    result.indexCapacity = max(indices.len, 1)
    result.indexBuffer = renderer.createUploadResource(
      uint64(result.indexCapacity * sizeof(uint32)),
      result.indexBufferPtr
    )
    result.indexBufferView = D3D12_INDEX_BUFFER_VIEW(
      BufferLocation: result.indexBuffer.getGPUVirtualAddress(),
      SizeInBytes: UINT(result.indexCapacity * sizeof(uint32)),
      Format: DXGI_FORMAT_R32_UINT
    )
  if indices.len > 0:
    copyMem(
      result.indexBufferPtr,
      unsafeAddr indices[0],
      indices.len * sizeof(uint32)
    )
  result.geometryVersion = primitive.geometryVersion

proc ensureMaterial(renderer: Renderer, material: Material): DxMaterial =
  if material == nil:
    return nil
  if material.data != nil and material.data.materialVersion == material.materialVersion:
    return material.data
  if material.data != nil:
    material.data.releaseMaterial()

  result = DxMaterial()
  material.data = result

  var heapDesc = D3D12_DESCRIPTOR_HEAP_DESC(
    typ: D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,
    NumDescriptors: TextureDescriptorCount,
    Flags: D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE,
    NodeMask: 0
  )
  result.heap = renderer.ctx.device.createDescriptorHeap(addr heapDesc)
  let baseHandle = result.heap.getCPUDescriptorHandleForHeapStart()
  result.handleGpu = result.heap.getGPUDescriptorHandleForHeapStart()

  let
    baseColor =
      if material != nil and material.baseColor != nil:
        renderer.uploadImage(material.baseColor)
      else:
        renderer.uploadSolidImage(rgbx(255, 255, 255, 255))
    metallicRoughness =
      if material != nil and material.metallicRoughness != nil:
        renderer.uploadImage(material.metallicRoughness)
      else:
        renderer.uploadSolidImage(rgbx(255, 255, 255, 255))
    occlusion =
      if material != nil and material.occlusion != nil:
        renderer.uploadImage(material.occlusion)
      else:
        renderer.uploadSolidImage(rgbx(255, 255, 255, 255))
    emissive =
      if material != nil and material.emissive != nil:
        renderer.uploadImage(material.emissive)
      else:
        renderer.uploadSolidImage(rgbx(255, 255, 255, 255))
    normal =
      if material != nil and material.normal != nil:
        renderer.uploadImage(material.normal)
      else:
        renderer.uploadSolidImage(rgbx(128, 128, 255, 255))
    shadow = renderer.uploadShadowPlaceholder()
    environment = renderer.uploadStudioCube()

  result.textures = @[
    baseColor,
    metallicRoughness,
    occlusion,
    emissive,
    normal,
    environment,
    shadow
  ]
  for i, texture in result.textures:
    renderer.createSrv(
      texture,
      offsetCpuHandle(baseHandle, renderer.srvDescriptorSize, i)
    )
  result.materialVersion = material.materialVersion

proc prepareNodeResources(renderer: Renderer, node: Node) =
  if node == nil:
    return
  if node.mesh != nil:
    for primitive in node.mesh.primitives:
      if primitive.hasGeometry():
        discard renderer.ensurePrimitive(primitive)
        discard renderer.ensureMaterial(primitive.material)
  for child in node.nodes:
    renderer.prepareNodeResources(child)

proc putTextureTransform(
  data: var openArray[uint32],
  texCoordIndex,
  offsetIndex,
  scaleIndex,
  rotationIndex: int,
  transform: TextureTransform
) =
  data[texCoordIndex] = transform.texCoord.uint32
  data.putVec2(offsetIndex, transform.offset)
  data.putVec2(scaleIndex, transform.scale)
  data.putFloat(rotationIndex, transform.rotation)

proc shadyVertexConstants(
  owner,
  root: Node,
  transform,
  view,
  proj: Mat4
): array[VertexConstantRegisters * 4, uint32] =
  let jointMatrices = root.skinMatrices(owner)
  result[0] = (jointMatrices.len > 0).ord.uint32
  for i in 0 ..< min(jointMatrices.len, 128):
    result.putMat4(1 + i * 4, jointMatrices[i])
  result.putMat4(513, transform)
  result.putMat4(517, mat4())
  result.putMat4(521, proj)
  result.putMat4(525, view)

proc shadyPixelConstants(
  primitive: Primitive,
  tint: Color,
  ambientLightColor: Color,
  sunLightDirection: Vec3,
  sunLightColor: Color,
  rimLightDirection: Vec3,
  rimLightColor: Color,
  cameraPosition: Vec3
): array[PixelConstantRegisters * 4, uint32] =
  let material = primitive.material
  if material != nil:
    result.putTextureTransform(0, 1, 4, 6, material.baseColorTransform)
    result.putTextureTransform(7, 8, 10, 12, material.metallicRoughnessTransform)
    result.putTextureTransform(13, 14, 16, 18, material.normalTransform)
    result.putTextureTransform(19, 20, 22, 24, material.occlusionTransform)
    result.putTextureTransform(25, 26, 28, 30, material.emissiveTransform)
    result.putColor(32, material.baseColorFactor)
    result.putFloat(
      36,
      if material.alphaMode == MaskAlphaMode: material.alphaCutoff else: -1.0'f32
    )
    result.putFloat(37, material.roughnessFactor)
    result.putFloat(38, material.metallicFactor)
    result.putFloat(39, material.transmissionFactor)
    result.putFloat(40, material.occlusionStrength)
    result.putVec3(41, vec3(
      material.emissiveFactor.r,
      material.emissiveFactor.g,
      material.emissiveFactor.b
    ))
    result.putFloat(44, material.normalScale)
    result[45] = (
      material.hasNormalTexture and
      primitive.normals.len > 0 and
      primitive.tangents.len > 0
    ).ord.uint32
  else:
    let identityTransform = TextureTransform(
      texCoord: 0,
      offset: vec2(0, 0),
      scale: vec2(1, 1),
      rotation: 0.0'f32
    )
    result.putTextureTransform(0, 1, 4, 6, identityTransform)
    result.putTextureTransform(7, 8, 10, 12, identityTransform)
    result.putTextureTransform(13, 14, 16, 18, identityTransform)
    result.putTextureTransform(19, 20, 22, 24, identityTransform)
    result.putTextureTransform(25, 26, 28, 30, identityTransform)
    result.putColor(32, color(1, 1, 1, 1))
    result.putFloat(36, -1.0'f32)
    result.putFloat(37, 1.0'f32)
    result.putFloat(38, 1.0'f32)
    result.putFloat(39, 0.0'f32)
    result.putFloat(40, 1.0'f32)
    result.putVec3(41, vec3(0, 0, 0))
    result.putFloat(44, 1.0'f32)
    result[45] = 0
  result.putVec3(48, sunLightDirection)
  result.putVec3(52, rimLightDirection)
  result.putVec3(56, cameraPosition)
  result.putColor(60, sunLightColor)
  result.putColor(64, rimLightColor)
  result.putFloat(68, 3.0'f32)
  result[69] = 0
  result.putFloat(70, 0.0005'f32)
  result.putVec2(72, vec2(1.0'f32 / 2048.0'f32, 1.0'f32 / 2048.0'f32))
  result[74] = 0
  result.putColor(76, tint)
  result.putColor(80, ambientLightColor)

proc drawPrimitive(
  renderer: Renderer,
  primitive: Primitive,
  owner,
  root: Node,
  transform,
  view,
  proj: Mat4,
  tint: Color,
  ambientLightColor: Color,
  sunLightDirection: Vec3,
  sunLightColor: Color,
  rimLightDirection: Vec3,
  rimLightColor: Color,
  cameraPosition: Vec3,
  blendedPass: bool
) =
  if primitive == nil or not primitive.hasGeometry():
    return

  let isBlend =
    primitive.material != nil and
    primitive.material.alphaMode == BlendAlphaMode
  if isBlend != blendedPass:
    return

  let dxPrimitive = renderer.ensurePrimitive(primitive)
  if dxPrimitive.indexCount == 0:
    return
  let dxMaterial = renderer.ensureMaterial(primitive.material)
  let key = PipelineKey(
    topology: dxPrimitive.topologyKind,
    doubleSided: primitive.material != nil and primitive.material.doubleSided,
    blended: isBlend
  )
  let pipeline = renderer.getPipeline(key)
  renderer.ctx.commandList.setPipelineState(pipeline)
  renderer.ctx.commandList.setGraphicsRootSignature(renderer.rootSignature)

  let
    vertexConstants = shadyVertexConstants(owner, root, transform, view, proj)
    pixelConstants = shadyPixelConstants(
      primitive,
      tint,
      ambientLightColor,
      sunLightDirection,
      sunLightColor,
      rimLightDirection,
      rimLightColor,
      cameraPosition
    )
    vertexConstantsGpu = renderer.createFrameConstantBuffer(vertexConstants)
    pixelConstantsGpu = renderer.createFrameConstantBuffer(pixelConstants)
  renderer.ctx.commandList.setGraphicsRootConstantBufferView(
    0,
    vertexConstantsGpu
  )
  renderer.ctx.commandList.setGraphicsRootConstantBufferView(
    1,
    pixelConstantsGpu
  )
  var heaps = [dxMaterial.heap]
  renderer.ctx.commandList.setDescriptorHeaps(1, addr heaps[0])
  renderer.ctx.commandList.setGraphicsRootDescriptorTable(
    2,
    dxMaterial.handleGpu
  )
  renderer.ctx.commandList.iaSetPrimitiveTopology(dxPrimitive.topology)
  renderer.ctx.commandList.iaSetVertexBuffers(
    0,
    1,
    unsafeAddr dxPrimitive.vertexBufferView
  )
  renderer.ctx.commandList.iaSetIndexBuffer(unsafeAddr dxPrimitive.indexBufferView)
  renderer.ctx.commandList.drawIndexedInstanced(
    UINT(dxPrimitive.indexCount),
    1,
    0,
    0,
    0
  )

proc collectOrDrawNode(
  renderer: Renderer,
  node,
  root: Node,
  transform,
  view,
  proj: Mat4,
  tint: Color,
  ambientLightColor: Color,
  sunLightDirection: Vec3,
  sunLightColor: Color,
  rimLightDirection: Vec3,
  rimLightColor: Color,
  cameraPosition: Vec3,
  blended: var seq[BlendEntry]
) =
  if node == nil or not node.visible:
    return
  node.mat = transform * node.trs
  if node.mesh != nil:
    for primitive in node.mesh.primitives:
      if primitive.material != nil and primitive.material.alphaMode == BlendAlphaMode:
        blended.add(BlendEntry(node: node, primitive: primitive, transform: node.mat))
      else:
        renderer.drawPrimitive(
          primitive,
          node,
          root,
          node.mat,
          view,
          proj,
          tint,
          ambientLightColor,
          sunLightDirection,
          sunLightColor,
          rimLightDirection,
          rimLightColor,
          cameraPosition,
          blendedPass = false
        )
  for child in node.nodes:
    renderer.collectOrDrawNode(
      child,
      root,
      node.mat,
      view,
      proj,
      tint,
      ambientLightColor,
      sunLightDirection,
      sunLightColor,
      rimLightDirection,
      rimLightColor,
      cameraPosition,
      blended
    )

proc drawPbrFrame*(
  renderer: Renderer,
  node: Node,
  size: IVec2,
  clearColor: Color,
  transform,
  view,
  proj: Mat4,
  tint: Color,
  ambientLightColor: Color,
  sunLightDirection: Vec3,
  sunLightColor: Color,
  rimLightDirection: Vec3,
  rimLightColor: Color,
  cameraPosition: Vec3,
  vsync = true
) =
  ## Draws a full glTF PBR frame through DirectX 12.
  renderer.resize(size)
  for resource in renderer.frameResources:
    if resource != nil:
      resource.release()
  renderer.frameResources.setLen(0)

  if node != nil:
    renderer.prepareNodeResources(node)

  renderer.ctx.commandAllocator.reset()
  renderer.ctx.commandList.reset(renderer.ctx.commandAllocator, nil)

  var barrier = D3D12_RESOURCE_BARRIER(
    typ: D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
    Flags: D3D12_RESOURCE_BARRIER_FLAG_NONE,
    data: D3D12_RESOURCE_BARRIER_union(Transition: D3D12_RESOURCE_TRANSITION_BARRIER(
      pResource: renderer.ctx.renderTargets[renderer.ctx.currentFrame],
      Subresource: D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
      StateBefore: D3D12_RESOURCE_STATE_PRESENT,
      StateAfter:
        if renderer.msaaEnabled:
          D3D12_RESOURCE_STATE_RESOLVE_DEST
        else:
          D3D12_RESOURCE_STATE_RENDER_TARGET
    ))
  )
  renderer.ctx.commandList.resourceBarrier(1, addr barrier)
  var rtvHandle =
    if renderer.msaaEnabled:
      renderer.msaaRtvHandle
    else:
      renderer.ctx.rtvHandles[renderer.ctx.currentFrame]
  renderer.ctx.commandList.rsSetViewports(1, addr renderer.ctx.viewport)
  renderer.ctx.commandList.rsSetScissorRects(1, addr renderer.ctx.scissor)
  renderer.ctx.commandList.omSetRenderTargets(
    1,
    addr rtvHandle,
    1,
    unsafeAddr renderer.dsvHandle
  )
  var clear = [
    clearColor.r.FLOAT,
    clearColor.g.FLOAT,
    clearColor.b.FLOAT,
    clearColor.a.FLOAT
  ]
  renderer.ctx.commandList.clearRenderTargetView(
    rtvHandle,
    unsafeAddr clear[0],
    0,
    nil
  )
  renderer.ctx.commandList.clearDepthStencilView(
    renderer.dsvHandle,
    D3D12_CLEAR_FLAG_DEPTH,
    1.0'f32,
    0,
    0,
    nil
  )

  if node != nil and node.visible:
    node.updateTransforms(transform, true)
    var blended: seq[BlendEntry]
    renderer.collectOrDrawNode(
      node,
      node,
      transform,
      view,
      proj,
      tint,
      ambientLightColor,
      sunLightDirection,
      sunLightColor,
      rimLightDirection,
      rimLightColor,
      cameraPosition,
      blended
    )
    if blended.len > 0:
      blended.sort(proc(a, b: BlendEntry): int =
        let
          pa = (a.transform * vec4(0, 0, 0, 1)).xyz
          pb = (b.transform * vec4(0, 0, 0, 1)).xyz
          da = (cameraPosition - pa).lengthSq
          db = (cameraPosition - pb).lengthSq
        if da > db: -1 elif da < db: 1 else: 0
      )
      for entry in blended:
        renderer.drawPrimitive(
          entry.primitive,
          entry.node,
          node,
          entry.transform,
          view,
          proj,
          tint,
          ambientLightColor,
          sunLightDirection,
          sunLightColor,
          rimLightDirection,
          rimLightColor,
          cameraPosition,
          blendedPass = true
        )

  if renderer.msaaEnabled:
    var resolveBarrier = D3D12_RESOURCE_BARRIER(
      typ: D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
      Flags: D3D12_RESOURCE_BARRIER_FLAG_NONE,
      data: D3D12_RESOURCE_BARRIER_union(
        Transition: D3D12_RESOURCE_TRANSITION_BARRIER(
          pResource: renderer.msaaColorBuffer,
          Subresource: D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
          StateBefore: D3D12_RESOURCE_STATE_RENDER_TARGET,
          StateAfter: D3D12_RESOURCE_STATE_RESOLVE_SOURCE
        )
      )
    )
    renderer.ctx.commandList.resourceBarrier(1, addr resolveBarrier)
    renderer.ctx.commandList.resolveSubresource(
      renderer.ctx.renderTargets[renderer.ctx.currentFrame],
      0,
      renderer.msaaColorBuffer,
      0,
      DXGI_FORMAT_R8G8B8A8_UNORM
    )
    resolveBarrier.data.Transition.StateBefore =
      D3D12_RESOURCE_STATE_RESOLVE_SOURCE
    resolveBarrier.data.Transition.StateAfter =
      D3D12_RESOURCE_STATE_RENDER_TARGET
    renderer.ctx.commandList.resourceBarrier(1, addr resolveBarrier)

    barrier.data.Transition.StateBefore = D3D12_RESOURCE_STATE_RESOLVE_DEST
    barrier.data.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE
    renderer.ctx.commandList.resourceBarrier(1, addr barrier)
  else:
    barrier.data.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET
    barrier.data.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE
    renderer.ctx.commandList.resourceBarrier(1, addr barrier)

  var dstLocation = D3D12_TEXTURE_COPY_LOCATION(
    pResource: renderer.readbackBuffer,
    typ: D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT,
    data: D3D12_TEXTURE_COPY_LOCATION_UNION(
      PlacedFootprint: renderer.readbackFootprint
    )
  )
  var srcLocation = D3D12_TEXTURE_COPY_LOCATION(
    pResource: renderer.ctx.renderTargets[renderer.ctx.currentFrame],
    typ: D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX,
    data: D3D12_TEXTURE_COPY_LOCATION_UNION(SubresourceIndex: 0)
  )
  renderer.ctx.commandList.copyTextureRegion(
    addr dstLocation,
    0,
    0,
    0,
    addr srcLocation,
    nil
  )

  barrier.data.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_SOURCE
  barrier.data.Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT
  renderer.ctx.commandList.resourceBarrier(1, addr barrier)
  renderer.ctx.commandList.close()

  renderer.ctx.executeFrame(vsync)
  renderer.ctx.waitForGpu()

proc captureScreenshot*(renderer: Renderer): Image =
  ## Reads the most recently rendered DirectX frame.
  let
    width = renderer.readbackSize.x.int
    height = renderer.readbackSize.y.int
    rowPitch = int(renderer.readbackFootprint.Footprint.RowPitch)
  result = newImage(width, height)
  var mapped: pointer
  renderer.readbackBuffer.map(0, nil, addr mapped)
  let base = cast[uint](mapped) + uint(renderer.readbackFootprint.Offset)
  for y in 0 ..< height:
    let srcRow = cast[ptr UncheckedArray[uint8]](base + uint(y * rowPitch))
    for x in 0 ..< width:
      let src = x * 4
      let alpha = srcRow[src + 3]
      result.data[result.dataIndex(x, y)] = rgbx(
        min(srcRow[src + 0], alpha),
        min(srcRow[src + 1], alpha),
        min(srcRow[src + 2], alpha),
        alpha
      )
  renderer.readbackBuffer.unmap(0, nil)

proc clearNode*(renderer: Renderer, node: Node) =
  ## Releases DirectX resources associated with a loaded node tree.
  if node == nil:
    return
  if node.mesh != nil:
    for primitive in node.mesh.primitives:
      if primitive.data != nil:
        primitive.data.releasePrimitive()
        primitive.data = nil
      if primitive.material != nil:
        if primitive.material.data != nil:
          primitive.material.data.releaseMaterial()
          primitive.material.data = nil
  for child in node.nodes:
    renderer.clearNode(child)

proc shutdown*(renderer: Renderer) =
  ## Releases all DirectX resources held by the renderer.
  if renderer == nil:
    return
  renderer.ctx.waitForGpu()
  for resource in renderer.frameResources:
    if resource != nil:
      resource.release()
  renderer.frameResources.setLen(0)
  if renderer.readbackBuffer != nil:
    renderer.readbackBuffer.release()
    renderer.readbackBuffer = nil
  if renderer.msaaColorBuffer != nil:
    renderer.msaaColorBuffer.release()
    renderer.msaaColorBuffer = nil
  if renderer.msaaRtvHeap != nil:
    renderer.msaaRtvHeap.release()
    renderer.msaaRtvHeap = nil
  if renderer.depthBuffer != nil:
    renderer.depthBuffer.release()
    renderer.depthBuffer = nil
  if renderer.dsvHeap != nil:
    renderer.dsvHeap.release()
    renderer.dsvHeap = nil
  for pso in renderer.pipelineStates.values:
    if pso != nil:
      pso.release()
  renderer.pipelineStates.clear()
  if renderer.rootSignature != nil:
    renderer.rootSignature.release()
    renderer.rootSignature = nil
  renderer.ctx.cleanup()

proc beginFrame*(renderer: Renderer; window: Window; size: IVec2) =
  discard renderer
  discard window
  discard size

proc clearScreen*(renderer: Renderer; color: ColorRGBX) =
  discard renderer
  discard color

proc clearScreen*(renderer: Renderer; color: Color) =
  discard renderer
  discard color

proc render*(renderer: Renderer; node: Node; params: RenderParams) =
  renderer.drawPbrFrame(
    node,
    params.size,
    params.clearColor,
    params.transform,
    params.view,
    params.proj,
    tint = params.tint,
    ambientLightColor = params.ambientLightColor,
    sunLightDirection = params.sunLightDirection,
    sunLightColor = params.sunLightColor,
    rimLightDirection = params.rimLightDirection,
    rimLightColor = params.rimLightColor,
    cameraPosition = params.cameraPosition,
    vsync = params.vsync
  )

proc render*(renderer: Renderer; file: GltfFile; params: RenderParams) =
  if file != nil:
    renderer.render(file.root, params)

proc endFrame*(renderer: Renderer) =
  discard renderer

proc release*(renderer: Renderer; node: Node) =
  renderer.clearNode(node)
