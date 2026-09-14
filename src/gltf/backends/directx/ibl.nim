## DirectX resources and pass orchestration for the shared Shady IBL shaders.
## Included by renderer.nim; no shading algorithms live in this backend.

proc transition(renderer: Renderer, resource: ID3D12Resource, before, after: uint32,
    subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES) =
  var barrier = D3D12_RESOURCE_BARRIER(typ: D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
    data: D3D12_RESOURCE_BARRIER_union(Transition: D3D12_RESOURCE_TRANSITION_BARRIER(
      pResource: resource, Subresource: subresource,
      StateBefore: before, StateAfter: after)))
  renderer.ctx.commandList.resourceBarrier(1, addr barrier)

proc samplerHeap(renderer: Renderer, states: openArray[D3D12_SAMPLER_DESC]): ID3D12DescriptorHeap =
  var desc = D3D12_DESCRIPTOR_HEAP_DESC(typ: D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER,
    NumDescriptors: 16, Flags: D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE)
  result = renderer.ctx.device.createDescriptorHeap(addr desc)
  let base = result.getCPUDescriptorHandleForHeapStart()
  let step = renderer.ctx.device.getDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER)
  for i in 0 ..< 16:
    var state = states[min(i, states.high)]
    renderer.ctx.device.createSampler(addr state, offsetCpuHandle(base, step, i))

proc dxSampler(sampler: TextureSampler, environment = false, comparison = false): D3D12_SAMPLER_DESC =
  proc wrap(value: TextureWrap): uint32 =
    case value
    of ClampToEdgeWrap: D3D12_TEXTURE_ADDRESS_MODE_CLAMP
    of MirroredRepeatWrap: D3D12_TEXTURE_ADDRESS_MODE_MIRROR
    else: D3D12_TEXTURE_ADDRESS_MODE_WRAP
  let minLinear = sampler.minFilter in {LinearMinFilter, LinearMipmapNearestMinFilter, LinearMipmapLinearMinFilter}
  let mipLinear = sampler.minFilter in {NearestMipmapLinearMinFilter, LinearMipmapLinearMinFilter}
  result.Filter = (if minLinear: 0x10'u32 else: 0) or
    (if sampler.magFilter == LinearMagFilter: 0x4'u32 else: 0) or (if mipLinear: 1'u32 else: 0)
  result.AddressU = wrap(sampler.wrapS)
  result.AddressV = wrap(sampler.wrapT)
  result.AddressW = result.AddressU
  result.MaxLOD = if sampler.minFilter in {NearestMinFilter, LinearMinFilter}: 0 else: 1000
  result.MaxAnisotropy = 1
  result.ComparisonFunc = D3D12_COMPARISON_FUNC_ALWAYS
  if environment:
    result.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR
    result.AddressU = D3D12_TEXTURE_ADDRESS_MODE_CLAMP
    result.AddressV = D3D12_TEXTURE_ADDRESS_MODE_CLAMP
    result.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP
    result.MaxLOD = 1000
  if comparison:
    result.Filter = D3D12_FILTER_COMPARISON_MIN_MAG_LINEAR_MIP_POINT
    result.ComparisonFunc = D3D12_COMPARISON_FUNC_LESS_EQUAL

proc createHdr(renderer: Renderer, size: IVec2) =
  if renderer.hdrSize == size: return
  renderer.hdrColor.releaseTexture()
  renderer.hdrFlags.releaseTexture()
  if renderer.hdrRtvHeap != nil: renderer.hdrRtvHeap.release()
  if renderer.hdrSrvHeap != nil: renderer.hdrSrvHeap.release()
  var heap = defaultHeap()
  var rtvDesc = D3D12_DESCRIPTOR_HEAP_DESC(typ: D3D12_DESCRIPTOR_HEAP_TYPE_RTV, NumDescriptors: 2)
  renderer.hdrRtvHeap = renderer.ctx.device.createDescriptorHeap(addr rtvDesc)
  let rtv = renderer.hdrRtvHeap.getCPUDescriptorHandleForHeapStart()
  let step = renderer.ctx.device.getDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV)
  var textures: array[2, DxTexture]
  for i, format in [DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_FORMAT_R8_UINT]:
    var desc = textureDesc2D(size.x.int, size.y.int, format, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET)
    let resource = renderer.ctx.device.createCommittedResource(addr heap, D3D12_HEAP_FLAG_NONE,
      addr desc, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, nil)
    textures[i] = DxTexture(resource: resource, format: format, mipLevels: 1)
    renderer.ctx.device.createRenderTargetView(resource, nil, offsetCpuHandle(rtv, step, i))
  renderer.hdrColor = textures[0]
  renderer.hdrFlags = textures[1]
  var srvDesc = D3D12_DESCRIPTOR_HEAP_DESC(typ: D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,
    NumDescriptors: RootTextureDescriptorCount, Flags: D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE)
  renderer.hdrSrvHeap = renderer.ctx.device.createDescriptorHeap(addr srvDesc)
  let srv = renderer.hdrSrvHeap.getCPUDescriptorHandleForHeapStart()
  for i in 0 ..< RootTextureDescriptorCount:
    let texture = if i < PostLayout.textures.len and PostLayout.textures[i] == "toneFlags": renderer.hdrFlags else: renderer.hdrColor
    renderer.createSrv(texture, offsetCpuHandle(srv, renderer.srvDescriptorSize, i))
  if renderer.postSamplerHeap == nil:
    renderer.postSamplerHeap = renderer.samplerHeap([dxSampler(TextureSampler(), environment = true)])
  if renderer.fullscreenBuffer == nil:
    var mapped: pointer
    var vertices = [-1'f, -1'f, 3'f, -1'f, -1'f, 3'f]
    renderer.fullscreenBuffer = renderer.createUploadResource(sizeof(vertices).uint64, mapped)
    copyMem(mapped, addr vertices[0], sizeof(vertices))
    renderer.fullscreenBuffer.unmap(0, nil)
    renderer.fullscreenView = D3D12_VERTEX_BUFFER_VIEW(
      BufferLocation: renderer.fullscreenBuffer.getGPUVirtualAddress(),
      SizeInBytes: sizeof(vertices).uint32, StrideInBytes: (2 * sizeof(float32)).uint32)
  renderer.hdrSize = size

proc createTransmission(renderer: Renderer) =
  if renderer.transmission != nil: return
  var heap = defaultHeap()
  var desc = textureDesc2D(1024, 1024, DXGI_FORMAT_R8G8B8A8_UNORM,
    D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, mipLevels = 11)
  renderer.transmission = DxTexture(format: desc.Format, mipLevels: 11,
    resource: renderer.ctx.device.createCommittedResource(addr heap, D3D12_HEAP_FLAG_NONE,
      addr desc, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, nil))
  desc.MipLevels = 1
  desc.SampleDesc.Count = 4
  renderer.transmissionMsaa = renderer.ctx.device.createCommittedResource(addr heap, D3D12_HEAP_FLAG_NONE,
    addr desc, D3D12_RESOURCE_STATE_RENDER_TARGET, nil)
  desc.Format = DXGI_FORMAT_D32_FLOAT
  desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL
  renderer.transmissionDepth = renderer.ctx.device.createCommittedResource(addr heap, D3D12_HEAP_FLAG_NONE,
    addr desc, D3D12_RESOURCE_STATE_DEPTH_WRITE, nil)
  var rtvDesc = D3D12_DESCRIPTOR_HEAP_DESC(typ: D3D12_DESCRIPTOR_HEAP_TYPE_RTV, NumDescriptors: 12)
  renderer.transmissionRtv = renderer.ctx.device.createDescriptorHeap(addr rtvDesc)
  let base = renderer.transmissionRtv.getCPUDescriptorHandleForHeapStart()
  let step = renderer.ctx.device.getDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV)
  renderer.ctx.device.createRenderTargetView(renderer.transmissionMsaa, nil, base)
  for level in 0 .. 10:
    var view = D3D12_RENDER_TARGET_VIEW_DESC(Format: DXGI_FORMAT_R8G8B8A8_UNORM,
      ViewDimension: D3D12_RTV_DIMENSION_TEXTURE2D,
      data: D3D12_RENDER_TARGET_VIEW_DESC_union(Texture2D: D3D12_TEX2D_RTV(MipSlice: level.uint32)))
    renderer.ctx.device.createRenderTargetView(renderer.transmission.resource, addr view, offsetCpuHandle(base, step, level + 1))
    if level > 0:
      var srvDesc = D3D12_DESCRIPTOR_HEAP_DESC(typ: D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,
        NumDescriptors: RootTextureDescriptorCount, Flags: D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE)
      let srv = renderer.ctx.device.createDescriptorHeap(addr srvDesc)
      for i in 0 ..< RootTextureDescriptorCount:
        renderer.createSrv(renderer.transmission, offsetCpuHandle(srv.getCPUDescriptorHandleForHeapStart(), renderer.srvDescriptorSize, i), firstMip = level - 1, levels = 1)
      renderer.transmissionMipHeaps.add(srv)
  var dsvDesc = D3D12_DESCRIPTOR_HEAP_DESC(typ: D3D12_DESCRIPTOR_HEAP_TYPE_DSV, NumDescriptors: 1)
  renderer.transmissionDsv = renderer.ctx.device.createDescriptorHeap(addr dsvDesc)
  renderer.ctx.device.createDepthStencilView(renderer.transmissionDepth, nil, renderer.transmissionDsv.getCPUDescriptorHandleForHeapStart())

proc beginTransmission(renderer: Renderer, clearColor: Color) =
  var viewport = D3D12_VIEWPORT(Width: 1024, Height: 1024, MinDepth: 0, MaxDepth: 1)
  var scissor = D3D12_RECT(left: 0, top: 0, right: 1024, bottom: 1024)
  renderer.ctx.commandList.rsSetViewports(1, addr viewport)
  renderer.ctx.commandList.rsSetScissorRects(1, addr scissor)
  var rtv = renderer.transmissionRtv.getCPUDescriptorHandleForHeapStart()
  var dsv = renderer.transmissionDsv.getCPUDescriptorHandleForHeapStart()
  renderer.ctx.commandList.omSetRenderTargets(1, addr rtv, 1, addr dsv)
  var clear = [pow(clearColor.r, 2.2'f), pow(clearColor.g, 2.2'f), pow(clearColor.b, 2.2'f), pow(clearColor.a, 2.2'f)]
  renderer.ctx.commandList.clearRenderTargetView(rtv, addr clear[0], 0, nil)
  renderer.ctx.commandList.clearDepthStencilView(dsv, D3D12_CLEAR_FLAG_DEPTH, 1, 0, 0, nil)

proc resolveTransmission(renderer: Renderer) =
  renderer.transition(renderer.transmissionMsaa, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_RESOLVE_SOURCE)
  renderer.transition(renderer.transmission.resource, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_RESOLVE_DEST, 0)
  renderer.ctx.commandList.resolveSubresource(renderer.transmission.resource, 0, renderer.transmissionMsaa, 0, DXGI_FORMAT_R8G8B8A8_UNORM)
  renderer.transition(renderer.transmissionMsaa, D3D12_RESOURCE_STATE_RESOLVE_SOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET)
  renderer.transition(renderer.transmission.resource, D3D12_RESOURCE_STATE_RESOLVE_DEST, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, 0)
  let rtvBase = renderer.transmissionRtv.getCPUDescriptorHandleForHeapStart()
  let step = renderer.ctx.device.getDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV)
  var data = newUniformData(MipLayout)
  data.put("framebufferYDown", true)
  renderer.ctx.commandList.setPipelineState(renderer.getPipeline(PipelineKey(topology: dtTriangle, post: true, downsample: true)))
  renderer.ctx.commandList.setGraphicsRootSignature(renderer.rootSignature)
  renderer.ctx.commandList.setGraphicsRootConstantBufferView(1, renderer.createFrameConstantBuffer(data.words))
  renderer.ctx.commandList.iaSetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST)
  renderer.ctx.commandList.iaSetVertexBuffers(0, 1, addr renderer.fullscreenView)
  for level in 1 .. 10:
    renderer.transition(renderer.transmission.resource, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET, level.uint32)
    var target = offsetCpuHandle(rtvBase, step, level + 1)
    renderer.ctx.commandList.omSetRenderTargets(1, addr target, 1, nil)
    let size = 1024 shr level
    var viewport = D3D12_VIEWPORT(Width: size.float32, Height: size.float32, MinDepth: 0, MaxDepth: 1)
    var scissor = D3D12_RECT(left: 0, top: 0, right: size.int32, bottom: size.int32)
    renderer.ctx.commandList.rsSetViewports(1, addr viewport)
    renderer.ctx.commandList.rsSetScissorRects(1, addr scissor)
    var heaps = [renderer.transmissionMipHeaps[level - 1], renderer.postSamplerHeap]
    renderer.ctx.commandList.setDescriptorHeaps(2, addr heaps[0])
    renderer.ctx.commandList.setGraphicsRootDescriptorTable(2, heaps[0].getGPUDescriptorHandleForHeapStart())
    renderer.ctx.commandList.setGraphicsRootDescriptorTable(3, heaps[1].getGPUDescriptorHandleForHeapStart())
    renderer.ctx.commandList.drawInstanced(3, 1, 0, 0)
    renderer.transition(renderer.transmission.resource, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, level.uint32)

proc attachIblEnvironment*(ctx: PbrContext, environment: IblEnvironment) =
  let renderer = ctx.renderer
  renderer.ctx.waitForGpu()
  inc renderer.environmentVersion
  for texture in renderer.environment.values: texture.releaseTexture()
  renderer.environment.clear()
  for name, texture in environment.textures:
    var parts: seq[RgbaSubresource]
    for level in texture.subresources:
      parts.add(RgbaSubresource(width: level.width, height: level.width, floatBytes: level.bytes))
    var desc = textureDesc2D(parts[0].width, parts[0].height, DXGI_FORMAT_R32G32B32A32_FLOAT,
      mipLevels = texture.levels)
    if texture.cube: desc.DepthOrArraySize = 6
    renderer.environment[name] = renderer.uploadRgbaSubresources(desc, parts, texture.cube)
  ctx.iblEnvironment = environment
  ctx.useIbl = true
  ctx.environmentMipCount = environment.mipCount
  ctx.environmentMapStrength = environment.intensityScale
  renderer.sampleCount = 1
  renderer.createColorBuffer(renderer.readbackSize)
  renderer.createDepthBuffer(renderer.readbackSize)
  renderer.createHdr(renderer.readbackSize)
  renderer.createTransmission()

proc beginIblFrame*(ctx: PbrContext) =
  doAssert ctx.useIbl, "Attach an IBL environment first"

proc endIblFrame*(ctx: PbrContext) =
  ## The complete DirectX frame, including presentation, is submitted by draw.
  discard ctx

proc beginHdr(renderer: Renderer, clearColor: Color) =
  renderer.transition(renderer.hdrColor.resource, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET)
  renderer.transition(renderer.hdrFlags.resource, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET)
  var handle = renderer.hdrRtvHeap.getCPUDescriptorHandleForHeapStart()
  let step = renderer.ctx.device.getDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV)
  var clear = [pow(clearColor.r, 2.2'f), pow(clearColor.g, 2.2'f), pow(clearColor.b, 2.2'f), clearColor.a]
  var flag = [1'f, 0'f, 0'f, 0'f]
  renderer.ctx.commandList.clearRenderTargetView(handle, addr clear[0], 0, nil)
  renderer.ctx.commandList.clearRenderTargetView(offsetCpuHandle(handle, step, 1), addr flag[0], 0, nil)
  renderer.ctx.commandList.omSetRenderTargets(2, addr handle, 1, addr renderer.dsvHandle)

proc endHdr(renderer: Renderer) =
  renderer.transition(renderer.hdrColor.resource, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)
  renderer.transition(renderer.hdrFlags.resource, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)
  var rtv = renderer.ctx.rtvHandles[renderer.ctx.currentFrame]
  renderer.ctx.commandList.omSetRenderTargets(1, addr rtv, 1, nil)
  renderer.ctx.commandList.setPipelineState(renderer.getPipeline(PipelineKey(topology: dtTriangle, post: true)))
  renderer.ctx.commandList.setGraphicsRootSignature(renderer.rootSignature)
  var data = newUniformData(PostLayout)
  data.put("exposure", renderer.frame.exposure)
  data.put("framebufferYDown", true)
  renderer.ctx.commandList.setGraphicsRootConstantBufferView(1, renderer.createFrameConstantBuffer(data.words))
  var heaps = [renderer.hdrSrvHeap, renderer.postSamplerHeap]
  renderer.ctx.commandList.setDescriptorHeaps(2, addr heaps[0])
  renderer.ctx.commandList.setGraphicsRootDescriptorTable(2, renderer.hdrSrvHeap.getGPUDescriptorHandleForHeapStart())
  renderer.ctx.commandList.setGraphicsRootDescriptorTable(3, renderer.postSamplerHeap.getGPUDescriptorHandleForHeapStart())
  renderer.ctx.commandList.iaSetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST)
  renderer.ctx.commandList.iaSetVertexBuffers(0, 1, addr renderer.fullscreenView)
  renderer.ctx.commandList.drawInstanced(3, 1, 0, 0)

proc destroyIbl(renderer: Renderer) =
  for binding in renderer.materialBindings.values: binding.releaseMaterial()
  renderer.materialBindings.clear()
  renderer.defaultWhite.releaseTexture()
  renderer.defaultNormal.releaseTexture()
  for texture in renderer.environment.values: texture.releaseTexture()
  renderer.environment.clear()
  renderer.hdrColor.releaseTexture()
  renderer.hdrFlags.releaseTexture()
  for heap in [renderer.hdrRtvHeap, renderer.hdrSrvHeap, renderer.postSamplerHeap]:
    if heap != nil: heap.release()
  if renderer.fullscreenBuffer != nil: renderer.fullscreenBuffer.release()
  renderer.transmission.releaseTexture()
  for resource in [renderer.transmissionMsaa, renderer.transmissionDepth]:
    if resource != nil: resource.release()
  for heap in renderer.transmissionMipHeaps & @[renderer.transmissionRtv, renderer.transmissionDsv]:
    if heap != nil: heap.release()
