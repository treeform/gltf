## DirectX backend shader sources and renderer.

when not defined(windows):
  {.error: "The glTF DirectX backend requires Windows.".}

import
  std/[math, tables],
  chroma, pixie, vmath, windy,
  pkg/dx12, pkg/dx12/context, shady/backends/dx12,
  ../../common, ../../models,
  ./common, ../shader_layout, ../pbr_uniforms, ../ibl_data, ../texture_mips,
  ../shaders as shaderSources

export ibl_data

const
  VertexEntryPoint* = "VSMain"
  FragmentEntryPoint* = "PSMain"

  PbrVertexShader* = shaderSources.PbrVertHlsl
  PbrFragmentShader* = shaderSources.PbrFragHlsl
  SkyboxVertexShader* = shaderSources.SkyboxVertHlsl
  SkyboxFragmentShader* = shaderSources.SkyboxFragHlsl
  ShadowDepthVertexShader* = shaderSources.ShadowDepthVertHlsl
  ShadowDepthFragmentShader* = shaderSources.ShadowDepthFragHlsl

  VertexLayout = shaderLayout(shaderSources.PbrVertHlsl, hlslPacking)
  PixelLayout = shaderLayout(shaderSources.PbrFragHlsl, hlslPacking)
  IblLayout = shaderLayout(shaderSources.IblFragHlsl, hlslPacking)
  PostLayout = shaderLayout(shaderSources.HdrPostFragHlsl, hlslPacking)
  MipLayout = shaderLayout(shaderSources.MipDownsampleFragHlsl, hlslPacking)
  TextureDescriptorCount = 28
  RootTextureDescriptorCount = 28
  VertexConstantRegisters = 532
  PixelConstantRegisters = 25
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
    floatBytes: string

  Renderer* = ref object
    window: Window
    frame: PbrFrameUniforms
    environment: Table[string, DxTexture]
    environmentVersion: uint64
    materialBindings: Table[string, DxMaterial]
    defaultWhite, defaultNormal: DxTexture
    geometryBlocks, uniformBlocks: seq[DxBufferBlock]
    hdrColor, hdrFlags: DxTexture
    hdrRtvHeap, hdrSrvHeap, postSamplerHeap: ID3D12DescriptorHeap
    hdrSize: IVec2
    fullscreenBuffer: ID3D12Resource
    fullscreenView: D3D12_VERTEX_BUFFER_VIEW
    transmission: DxTexture
    transmissionMsaa, transmissionDepth: ID3D12Resource
    transmissionRtv, transmissionDsv: ID3D12DescriptorHeap
    transmissionMipHeaps: seq[ID3D12DescriptorHeap]
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

  PbrContext* = ref object of PbrFrameUniforms
    renderer: Renderer
    iblEnvironment*: IblEnvironment

proc newPbrContext*(renderer: Renderer): PbrContext =
  ## Creates reusable state for PBR rendering.
  new(result)
  result.renderer = renderer
  result.size = ivec2(0, 0)
  result.clearColor = color(0, 0, 0, 1)
  result.transform = mat4()
  result.view = mat4()
  result.proj = mat4()
  result.tint = color(1, 1, 1, 1)
  result.useTrs = true
  result.ambientLightColor = color(0.1, 0.1, 0.1, 1)
  result.sunLightDirection = vec3(1, 4, 2)
  result.sunLightColor = color(1, 1, 1, 1)
  result.rimLightDirection = vec3(-1, 1, -1)
  result.rimLightColor = color(0, 0, 0, 0)
  result.debugView = dvLit
  result.cameraPosition = vec3(0, 0, 10)
  result.fogColor = color(0, 0, 0, 1)
  result.fogStart = 0.0'f
  result.fogEnd = 1.0'f
  result.fogDensity = 0.0'f
  result.fogStrength = 0.0'f
  result.environmentMapStrength = 1.0'f
  result.environmentMipCount = 3
  result.environmentRotation = 90
  result.exposure = 1
  result.useShadows = false
  result.drawSkybox = false
  result.skyboxLod = 0
  result.vsync = true

proc destroy*(ctx: PbrContext) =
  ## Releases resources owned by a PBR context.
  discard ctx

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

proc allocateUpload(renderer: Renderer, blocks: var seq[DxBufferBlock],
    size, alignment: int): tuple[storage: DxBufferBlock, offset: int] =
  for storage in blocks:
    if storage.users == 0: storage.used = 0
    let offset = (storage.used + alignment - 1) div alignment * alignment
    if offset + size <= storage.capacity:
      storage.used = offset + size
      inc storage.users
      return (storage, offset)
  let storage = DxBufferBlock(capacity: max(8 * 1024 * 1024, size), used: size, users: 1)
  storage.resource = renderer.createUploadResource(storage.capacity.uint64, storage.mapped)
  blocks.add(storage)
  (storage, 0)

proc destroyBlocks(blocks: var seq[DxBufferBlock]) =
  for storage in blocks:
    storage.resource.unmap(0, nil)
    storage.resource.release()
  blocks.setLen(0)

proc alignConstantBufferSize(size: int): int =
  ((max(1, size) + 255) div 256) * 256

proc createFrameConstantBuffer(
  renderer: Renderer,
  data: openArray[uint32]
): uint64 =
  let
    dataBytes = data.len * sizeof(uint32)
    byteSize = alignConstantBufferSize(dataBytes)
  let allocation = renderer.allocateUpload(renderer.uniformBlocks, byteSize, 256)
  let mapped = cast[pointer](cast[uint](allocation.storage.mapped) + allocation.offset.uint)
  if dataBytes > 0:
    copyMem(mapped, unsafeAddr data[0], dataBytes)
  if byteSize > dataBytes:
    zeroMem(cast[pointer](cast[uint](mapped) + uint(dataBytes)), byteSize - dataBytes)
  allocation.storage.resource.getGPUVirtualAddress() + allocation.offset.uint64

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

proc downsample(src: RgbaSubresource, srgb = false): RgbaSubresource =
  let mip = downsampleTexture(TextureMip(width: src.width, height: src.height,
    pixels: src.pixels), srgb)
  RgbaSubresource(width: mip.width, height: mip.height, pixels: mip.pixels)

proc buildMipChain(base: RgbaSubresource, srgb = false): seq[RgbaSubresource] =
  result.add(base)
  while result[^1].width > 1 or result[^1].height > 1:
    result.add(result[^1].downsample(srgb))

proc buildImageMips(image: Image, srgb = false): seq[RgbaSubresource] =
  buildMipChain(RgbaSubresource(width: image.width, height: image.height,
    pixels: image.data), srgb)

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
      srcRowSize = source.width * (if source.floatBytes.len > 0: 16 else: 4)
      rowPitch = int(footprints[subresource].Footprint.RowPitch)
    var dst = cast[ptr uint8](uploadBase + uint(footprints[subresource].Offset))
    for y in 0 ..< source.height:
      let src = cast[pointer](
        (if source.floatBytes.len > 0: cast[uint](unsafeAddr source.floatBytes[0]) else: cast[uint](unsafeAddr source.pixels[0])) + uint(y * srcRowSize)
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

proc uploadImage(renderer: Renderer, image: Image, srgb = false): DxTexture =
  let mips = image.buildImageMips(srgb)
  var desc = textureDesc2D(
    image.width,
    image.height,
    (if srgb: DXGI_FORMAT_R8G8B8A8_UNORM_SRGB else: DXGI_FORMAT_R8G8B8A8_UNORM),
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
  handle: D3D12_CPU_DESCRIPTOR_HANDLE,
  firstMip = 0, levels = 0
) =
  var srvDesc: D3D12_SHADER_RESOURCE_VIEW_DESC
  srvDesc.Format = texture.format
  srvDesc.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING
  if texture.isCube:
    srvDesc.ViewDimension = D3D12_SRV_DIMENSION_TEXTURECUBE
    srvDesc.data = D3D12_SHADER_RESOURCE_VIEW_DESC_UNION(
      TextureCube: D3D12_TEXCUBE_SRV(
        MostDetailedMip: UINT(firstMip),
        MipLevels: UINT(if levels > 0: levels else: texture.mipLevels),
        ResourceMinLODClamp: 0.0
      )
    )
  else:
    srvDesc.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D
    srvDesc.data = D3D12_SHADER_RESOURCE_VIEW_DESC_UNION(
      Texture2D: D3D12_TEX2D_SRV(
        MostDetailedMip: UINT(firstMip),
        MipLevels: UINT(if levels > 0: levels else: texture.mipLevels),
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
    psBlob = compileShader(if key.ibl: shareHlslSamplers(psCode, key.samplerSlots) else: psCode, FragmentEntryPoint, "ps_5_0")

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
  blendDesc.IndependentBlendEnable = 1
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

  blendDesc.RenderTarget[1] = blendDesc.RenderTarget[0]
  blendDesc.RenderTarget[1].BlendEnable = 0

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
      CullMode: if key.doubleSided or key.post: D3D12_CULL_MODE_NONE else: D3D12_CULL_MODE_BACK,
      FrontCounterClockwise: if key.mirrored: 0 else: 1,
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
      DepthEnable: if key.post: 0 else: 1,
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
  if key.ibl:
    psoDesc.NumRenderTargets = 2
    psoDesc.RTVFormats[0] = DXGI_FORMAT_R16G16B16A16_FLOAT
    psoDesc.RTVFormats[1] = DXGI_FORMAT_R8_UINT
    psoDesc.SampleDesc.Count = 1
    if key.background:
      psoDesc.NumRenderTargets = 1
      psoDesc.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM
      psoDesc.RTVFormats[1] = DXGI_FORMAT_UNKNOWN
      psoDesc.SampleDesc.Count = 4
  if key.post:
    inputElements[0].Format = DXGI_FORMAT_R32G32_FLOAT
    psoDesc.InputLayout.NumElements = 1
    psoDesc.DSVFormat = DXGI_FORMAT_UNKNOWN
    psoDesc.SampleDesc.Count = 1
  result = renderer.ctx.device.createGraphicsPipelineState(addr psoDesc)
  release(vsBlob)
  release(psBlob)

proc getPipeline(renderer: Renderer, key: PipelineKey): ID3D12PipelineState =
  if key notin renderer.pipelineStates:
    renderer.pipelineStates[key] = renderer.createPipeline(
      key,
      (if key.post: shaderSources.HdrPostVertHlsl else: PbrVertexShader),
      (if key.downsample: shaderSources.MipDownsampleFragHlsl elif key.post: shaderSources.HdrPostFragHlsl elif key.ibl: shaderSources.IblFragHlsl else: PbrFragmentShader)
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
  var samplerRange = D3D12_DESCRIPTOR_RANGE(RangeType: D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER,
    NumDescriptors: 16, BaseShaderRegister: 0, RegisterSpace: 0,
    OffsetInDescriptorsFromTableStart: D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND)
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
    ),
    D3D12_ROOT_PARAMETER(ParameterType: D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE,
      data: D3D12_ROOT_PARAMETER_UNION(DescriptorTable: D3D12_ROOT_DESCRIPTOR_TABLE(
        NumDescriptorRanges: 1, pDescriptorRanges: addr samplerRange)),
      ShaderVisibility: D3D12_SHADER_VISIBILITY_PIXEL)
  ]

  var rootDesc = D3D12_ROOT_SIGNATURE_DESC(
    NumParameters: uint32(rootParams.len),
    pParameters: addr rootParams[0],
    NumStaticSamplers: 0,
    pStaticSamplers: nil,
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
  if material.binding != nil:
    let shared = material.binding
    material.binding = nil
    dec shared.references
    if shared.references == 0:
      shared.releaseMaterial()
    return
  for texture in material.textures:
    texture.releaseTexture()
  material.textures.setLen(0)
  if material.samplerHeap != nil:
    material.samplerHeap.release()
    material.samplerHeap = nil
  if material.heap != nil:
    material.heap.release()
    material.heap = nil

proc releasePrimitive(primitive: DxPrimitive) =
  if primitive == nil: return
  for storage in [primitive.vertexBlock, primitive.indexBlock]:
    if storage != nil: dec storage.users
  primitive.vertexBlock = nil
  primitive.indexBlock = nil
  primitive.vertexBuffer = nil
  primitive.indexBuffer = nil
  primitive.vertexBufferPtr = nil
  primitive.indexBufferPtr = nil
  primitive.vertexCapacity = 0
  primitive.indexCapacity = 0

include ibl

proc resize(renderer: Renderer, size: IVec2) =
  let safeSize = ivec2(max(1'i32, size.x), max(1'i32, size.y))
  if renderer.readbackSize == safeSize:
    return
  renderer.ctx.resize(safeSize.x.int, safeSize.y.int)
  renderer.createColorBuffer(safeSize)
  renderer.createDepthBuffer(safeSize)
  renderer.createReadbackBuffer(safeSize)
  if renderer.frame.useIbl: renderer.createHdr(safeSize)

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
  if result.vertexCapacity > 0 and result.geometryVersion == primitive.geometryVersion: return


  if primitive.points.len > result.vertexCapacity:
    if result.vertexBlock != nil: dec result.vertexBlock.users
    result.vertexCapacity = max(primitive.points.len, 1)
    let allocation = renderer.allocateUpload(renderer.geometryBlocks, result.vertexCapacity * sizeof(DxVertex), 16)
    result.vertexBlock = allocation.storage
    result.vertexBuffer = allocation.storage.resource
    result.vertexBufferPtr = cast[pointer](cast[uint](allocation.storage.mapped) + allocation.offset.uint)
    result.vertexBufferView = D3D12_VERTEX_BUFFER_VIEW(
      BufferLocation: result.vertexBuffer.getGPUVirtualAddress() + allocation.offset.uint64,
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
    if result.indexBlock != nil: dec result.indexBlock.users
    result.indexCapacity = max(indices.len, 1)
    let allocation = renderer.allocateUpload(renderer.geometryBlocks, result.indexCapacity * sizeof(uint32), 16)
    result.indexBlock = allocation.storage
    result.indexBuffer = allocation.storage.resource
    result.indexBufferPtr = cast[pointer](cast[uint](allocation.storage.mapped) + allocation.offset.uint)
    result.indexBufferView = D3D12_INDEX_BUFFER_VIEW(
      BufferLocation: result.indexBuffer.getGPUVirtualAddress() + allocation.offset.uint64,
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
  if material.data != nil and material.data.materialVersion == material.materialVersion and
      material.data.ibl == renderer.frame.useIbl and material.data.environmentVersion == renderer.environmentVersion:
    return material.data
  if material.data != nil:
    material.data.releaseMaterial()

  let inputs = material.textureInputs()
  let bindingKey = materialBindingKey(inputs, renderer.frame.useIbl, renderer.environmentVersion, material.materialVersion)
  var cached = renderer.materialBindings.getOrDefault(bindingKey)
  if cached != nil and cached.heap != nil:
    inc cached.references
    result = DxMaterial(materialVersion: material.materialVersion, ibl: renderer.frame.useIbl,
      environmentVersion: renderer.environmentVersion, binding: cached)
    material.data = result
    return
  result = DxMaterial(ibl: renderer.frame.useIbl, environmentVersion: renderer.environmentVersion)
  if renderer.defaultWhite == nil:
    renderer.defaultWhite = renderer.uploadSolidImage(rgbx(255, 255, 255, 255))
    renderer.defaultNormal = renderer.uploadSolidImage(rgbx(128, 128, 255, 255))
  var heapDesc = D3D12_DESCRIPTOR_HEAP_DESC(
    typ: D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,
    NumDescriptors: TextureDescriptorCount,
    Flags: D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE,
    NodeMask: 0
  )
  result.heap = renderer.ctx.device.createDescriptorHeap(addr heapDesc)
  let baseHandle = result.heap.getCPUDescriptorHandleForHeapStart()
  result.handleGpu = result.heap.getGPUDescriptorHandleForHeapStart()

  let layout = if renderer.frame.useIbl: IblLayout else: PixelLayout
  var states: seq[D3D12_SAMPLER_DESC]
  var bound: seq[DxTexture]
  for i, name in layout.textures:
    var texture: DxTexture
    var state = dxSampler(TextureSampler(), environment = true)
    for input in inputs:
      if name == input.name & "Texture":
        if input.image != nil:
          if input.image.width == 1 and input.image.height == 1 and input.image.data[0] == rgbx(255, 255, 255, 255):
            texture = renderer.defaultWhite
          elif not input.srgb and input.image.width == 1 and input.image.height == 1 and input.image.data[0] == rgbx(128, 128, 255, 255):
            texture = renderer.defaultNormal
          else:
            texture = renderer.uploadImage(input.image, renderer.frame.useIbl and input.srgb)
        else:
          texture = if input.name == "normal": renderer.defaultNormal else: renderer.defaultWhite
        if texture != renderer.defaultWhite and texture != renderer.defaultNormal: result.textures.add(texture)
        state = dxSampler(input.sampler, anisotropic = renderer.frame.useIbl)
        break
    if texture == nil:
      if renderer.frame.useIbl:
        let asset = case name
          of "diffuseEnvironment": "diffuse"
          of "environmentMap": "specular"
          of "ggxLut": "ggx-lut"
          of "charlieEnvironment": "charlie"
          of "charlieLut": "charlie-lut"
          of "sheenEnergyLut": "sheen-energy-lut"
          of "transmissionBuffer": ""
          else: raise newException(ValueError, "Unbound IBL texture: " & name)
        if asset.len > 0: texture = renderer.environment[asset]
        else:
          texture = renderer.transmission
          state.Filter = D3D12_FILTER_MIN_LINEAR_MAG_POINT_MIP_LINEAR
      else:
        if name == "environmentMap": texture = renderer.uploadStudioCube()
        elif name == "shadowMap":
          texture = renderer.uploadShadowPlaceholder()
          state = dxSampler(TextureSampler(), environment = true, comparison = true)
        else: raise newException(ValueError, "Unbound shader texture: " & name)
        result.textures.add(texture)
    bound.add(texture)
    var slot = -1
    if renderer.frame.useIbl:
      for j, existing in states:
        if existing == state: slot = j; break
    if slot < 0:
      slot = states.len
      states.add(state)
    if slot >= 16: raise newException(ValueError, "Material exceeds DirectX's 16 distinct sampler states")
    result.samplerSlots[i] = slot
  result.samplerHeap = renderer.samplerHeap(states)
  for i in 0 ..< TextureDescriptorCount:
    renderer.createSrv(bound[min(i, bound.high)], offsetCpuHandle(baseHandle, renderer.srvDescriptorSize, i))
  result.references = 1
  renderer.materialBindings[bindingKey] = result
  result = DxMaterial(materialVersion: material.materialVersion, ibl: renderer.frame.useIbl,
    environmentVersion: renderer.environmentVersion, binding: result)
  material.data = result

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

proc drawPrimitive(renderer: Renderer, entry: SceneDraw, root: Node) =
  let primitive = entry.primitive
  let owner = entry.owner
  let transform = entry.transform
  let view = renderer.frame.view
  let proj = renderer.frame.proj
  if primitive == nil or not primitive.hasGeometry():
    return

  let isBlend = entry.blended

  let dxPrimitive = renderer.ensurePrimitive(primitive)
  if dxPrimitive.indexCount == 0:
    return
  let dxMaterial = renderer.ensureMaterial(primitive.material).binding
  let key = PipelineKey(
    topology: dxPrimitive.topologyKind,
    doubleSided: primitive.material != nil and primitive.material.doubleSided,
    blended: isBlend, ibl: renderer.frame.useIbl, background: renderer.frame.transmissionBackground, mirrored: determinant(transform) < 0,
    samplerSlots: dxMaterial.samplerSlots
  )
  let pipeline = renderer.getPipeline(key)
  renderer.ctx.commandList.setPipelineState(pipeline)
  renderer.ctx.commandList.setGraphicsRootSignature(renderer.rootSignature)

  let
    vertexConstants = vertexUniforms(VertexLayout, owner, root, transform, view, proj)
    pixelConstants = pixelUniforms(if renderer.frame.useIbl: IblLayout else: PixelLayout, primitive, renderer.frame, transform)
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
  var heaps = [dxMaterial.heap, dxMaterial.samplerHeap]
  renderer.ctx.commandList.setDescriptorHeaps(2, addr heaps[0])
  renderer.ctx.commandList.setGraphicsRootDescriptorTable(3, dxMaterial.samplerHeap.getGPUDescriptorHandleForHeapStart())
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

proc drawPbrFrame(
  renderer: Renderer,
  node: Node,
  ctx: PbrContext
) =
  ## Draws a full glTF PBR frame through DirectX 12.
  renderer.frame = PbrFrameUniforms(ctx[])
  let
    size = ctx.size
    clearColor = ctx.clearColor
    transform = ctx.transform
    view = ctx.view
    proj = ctx.proj
    tint = ctx.tint
    ambientLightColor = ctx.ambientLightColor
    sunLightDirection = ctx.sunLightDirection
    sunLightColor = ctx.sunLightColor
    rimLightDirection = ctx.rimLightDirection
    rimLightColor = ctx.rimLightColor
    cameraPosition = ctx.cameraPosition
    fogColor = ctx.fogColor
    fogStart = ctx.fogStart
    fogEnd = ctx.fogEnd
    fogDensity = ctx.fogDensity
    fogStrength = ctx.fogStrength
    environmentMapStrength = ctx.environmentMapStrength
    vsync = ctx.vsync
  if node != nil: node.updateTransforms(transform, true)
  renderer.frame.updateLights(node)
  let draws = renderer.frame.sceneDraws(node)
  renderer.resize(size)
  for storage in renderer.uniformBlocks:
    storage.used = 0
    storage.users = 0

  if node != nil:
    renderer.prepareNodeResources(node)

  renderer.ctx.commandAllocator.reset()
  renderer.ctx.commandList.reset(renderer.ctx.commandAllocator, nil)

  if renderer.frame.useIbl and draws.transmitted.len > 0:
    renderer.beginTransmission(clearColor)
    renderer.frame.transmissionBackground = true
    for entry in draws.opaque: renderer.drawPrimitive(entry, node)
    for entry in draws.blended: renderer.drawPrimitive(entry, node)
    renderer.resolveTransmission()
    renderer.frame.transmissionBackground = false

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

  if renderer.frame.useIbl: renderer.beginHdr(clearColor)

  for entry in draws.opaque: renderer.drawPrimitive(entry, node)
  for entry in draws.transmitted: renderer.drawPrimitive(entry, node)
  for entry in draws.blended: renderer.drawPrimitive(entry, node)

  if renderer.frame.useIbl: renderer.endHdr()

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
  destroyBlocks(renderer.uniformBlocks)
  destroyBlocks(renderer.geometryBlocks)
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
  renderer.destroyIbl()
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

proc draw*(ctx: PbrContext; node: Node) =
  ## Draws a node tree using PBR context state.
  doAssert ctx != nil, "PBR context must not be nil."
  doAssert ctx.renderer != nil, "PBR context renderer must not be nil."
  ctx.renderer.drawPbrFrame(
    node,
    ctx
  )

proc draw*(ctx: PbrContext; file: GltfFile) =
  ## Draws a glTF file using PBR context state.
  if file != nil:
    ctx.draw(file.root)

proc endFrame*(renderer: Renderer) =
  discard renderer

proc release*(renderer: Renderer; node: Node) =
  renderer.clearNode(node)
