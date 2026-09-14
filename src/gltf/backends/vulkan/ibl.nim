## Vulkan resources for the shared Shady IBL and HDR presentation shaders.
## Included by renderer.nim.

proc cmdImageBarrier(commandBuffer: VkCommandBuffer, image: VkImage,
  aspect: VkImageAspectFlags, oldLayout, newLayout: VkImageLayout,
  srcStage, dstStage: VkPipelineStageFlags2, srcAccess, dstAccess: VkAccessFlags2,
  mipLevel = 0)

proc materialSampler(renderer: Renderer, sampler: TextureSampler, levels: int,
    anisotropic = false): VkSampler =
  proc wrap(value: TextureWrap): VkSamplerAddressMode =
    case value
    of ClampToEdgeWrap: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    of MirroredRepeatWrap: VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT
    else: VK_SAMPLER_ADDRESS_MODE_REPEAT
  var desc = VkSamplerCreateInfo(sType: VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
    magFilter: (if sampler.magFilter == NearestMagFilter: VK_FILTER_NEAREST else: VK_FILTER_LINEAR),
    minFilter: (if sampler.minFilter in {NearestMinFilter, NearestMipmapNearestMinFilter, NearestMipmapLinearMinFilter}: VK_FILTER_NEAREST else: VK_FILTER_LINEAR),
    mipmapMode: (if sampler.minFilter in {NearestMipmapLinearMinFilter, LinearMipmapLinearMinFilter}: VK_SAMPLER_MIPMAP_MODE_LINEAR else: VK_SAMPLER_MIPMAP_MODE_NEAREST),
    addressModeU: wrap(sampler.wrapS), addressModeV: wrap(sampler.wrapT), addressModeW: wrap(sampler.wrapS),
    maxLod: (if sampler.minFilter in {NearestMinFilter, LinearMinFilter}: 0'f else: (levels - 1).float32),
    maxAnisotropy: 1)
  if anisotropic and renderer.ctx.maxSamplerAnisotropy > 1 and
      sampler.magFilter != NearestMagFilter and sampler.minFilter in
        {NearestMipmapLinearMinFilter, LinearMipmapLinearMinFilter}:
    desc.anisotropyEnable = VkBool32(VK_TRUE)
    desc.maxAnisotropy = min(16.0'f, renderer.ctx.maxSamplerAnisotropy)
  checkVk(vkCreateSampler(renderer.ctx.device, addr desc, nil, addr result), "Creating material sampler")

proc createHdr(renderer: Renderer, size: IVec2) =
  if renderer.hdrSize == size: return
  renderer.releaseTexture(renderer.hdrColor)
  renderer.releaseTexture(renderer.hdrFlags)
  renderer.releaseMaterial(renderer.postMaterial)
  var textures: array[2, VkTexture]
  for i, format in [VK_FORMAT_R16G16B16A16_SFLOAT, VK_FORMAT_R8_UINT]:
    let texture = VkTexture(format: format, mipLevels: 1, layers: 1)
    createImage(renderer.ctx, size.x.int, size.y.int, 1, 1, format,
      VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.uint32 or VK_IMAGE_USAGE_SAMPLED_BIT.uint32,
      0, VK_SAMPLE_COUNT_1_BIT, texture.image, texture.memory)
    var viewInfo = VkImageViewCreateInfo(sType: VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
      image: texture.image, viewType: VK_IMAGE_VIEW_TYPE_2D, format: format,
      subresourceRange: VkImageSubresourceRange(aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT), levelCount: 1, layerCount: 1))
    checkVk(vkCreateImageView(renderer.ctx.device, addr viewInfo, nil, addr texture.view), "Creating HDR attachment view")
    texture.sampler = renderer.materialSampler(TextureSampler(magFilter: NearestMagFilter,
      minFilter: NearestMinFilter, wrapS: ClampToEdgeWrap, wrapT: ClampToEdgeWrap), 1)
    textures[i] = texture
  renderer.hdrColor = textures[0]
  renderer.hdrFlags = textures[1]
  var bound: seq[VkTexture]
  for name in PostLayout.textures:
    bound.add(if name == "toneFlags": renderer.hdrFlags else: renderer.hdrColor)
  renderer.postMaterial = VkMaterial()
  renderer.bindTextures(renderer.postMaterial, bound)
  if renderer.fullscreen.buffer.int64 == 0:
    var vertices = [-1'f, -1'f, 3'f, -1'f, -1'f, 3'f]
    createBuffer(renderer.ctx, VkDeviceSize(sizeof(vertices)), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT.uint32,
      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.uint32 or VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.uint32,
      renderer.fullscreen.buffer, renderer.fullscreen.memory)
    var mapped: pointer
    checkVk(vkMapMemory(renderer.ctx.device, renderer.fullscreen.memory, VkDeviceSize(0), VkDeviceSize(sizeof(vertices)), VkMemoryMapFlags(0), addr mapped), "Mapping fullscreen vertices")
    copyMem(mapped, addr vertices[0], sizeof(vertices))
    vkUnmapMemory(renderer.ctx.device, renderer.fullscreen.memory)
  renderer.hdrSize = size

proc createTransmission(renderer: Renderer) =
  if renderer.transmission != nil: return
  var textures: array[3, VkTexture]
  for i in 0 .. 2:
    let format = if i == 2: DepthFormat else: VK_FORMAT_R8G8B8A8_UNORM
    let levels = if i == 0: 11 else: 1
    let samples = if i == 0: VK_SAMPLE_COUNT_1_BIT else: VK_SAMPLE_COUNT_4_BIT
    let texture = VkTexture(format: format, mipLevels: levels, layers: 1)
    let usage = if i == 0: VK_IMAGE_USAGE_TRANSFER_SRC_BIT.uint32 or VK_IMAGE_USAGE_TRANSFER_DST_BIT.uint32 or VK_IMAGE_USAGE_SAMPLED_BIT.uint32
      elif i == 1: VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.uint32 or VK_IMAGE_USAGE_TRANSFER_SRC_BIT.uint32
      else: VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT.uint32
    createImage(renderer.ctx, 1024, 1024, levels, 1, format, usage, 0, samples, texture.image, texture.memory)
    var viewInfo = VkImageViewCreateInfo(sType: VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
      image: texture.image, viewType: VK_IMAGE_VIEW_TYPE_2D, format: format,
      subresourceRange: VkImageSubresourceRange(aspectMask: VkImageAspectFlags(if i == 2: VK_IMAGE_ASPECT_DEPTH_BIT else: VK_IMAGE_ASPECT_COLOR_BIT), levelCount: levels.uint32, layerCount: 1))
    checkVk(vkCreateImageView(renderer.ctx.device, addr viewInfo, nil, addr texture.view), "Creating transmission attachment view")
    if i == 0:
      texture.sampler = renderer.materialSampler(TextureSampler(magFilter: NearestMagFilter,
        minFilter: LinearMipmapLinearMinFilter, wrapS: ClampToEdgeWrap, wrapT: ClampToEdgeWrap), levels)
      transitionImageLayout(renderer.ctx, texture.image, VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT), levels, 1,
        VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)
      transitionImageLayout(renderer.ctx, texture.image, VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT), levels, 1,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
    textures[i] = texture
  renderer.transmission = textures[0]
  renderer.transmissionMsaa = textures[1]
  renderer.transmissionDepth = textures[2]

proc beginTransmission(renderer: Renderer, commandBuffer: VkCommandBuffer, clearColor: Color) =
  commandBuffer.cmdImageBarrier(renderer.transmissionMsaa.image, VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
    VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_NONE), VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT),
    VkAccessFlags2(VK_ACCESS_2_NONE), VkAccessFlags2(VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT))
  commandBuffer.cmdImageBarrier(renderer.transmissionDepth.image, VkImageAspectFlags(VK_IMAGE_ASPECT_DEPTH_BIT),
    VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_NONE), VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT),
    VkAccessFlags2(VK_ACCESS_2_NONE), VkAccessFlags2(VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT))
  var colorAttachment = VkRenderingAttachmentInfo(sType: VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
    imageView: renderer.transmissionMsaa.view, imageLayout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    loadOp: VK_ATTACHMENT_LOAD_OP_CLEAR, storeOp: VK_ATTACHMENT_STORE_OP_STORE,
    clearValue: VkClearValue(color: VkClearColorValue(float32:
      [pow(clearColor.r, 2.2'f), pow(clearColor.g, 2.2'f), pow(clearColor.b, 2.2'f), pow(clearColor.a, 2.2'f)])))
  var depthAttachment = VkRenderingAttachmentInfo(sType: VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
    imageView: renderer.transmissionDepth.view, imageLayout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp: VK_ATTACHMENT_LOAD_OP_CLEAR, storeOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
    clearValue: VkClearValue(depthStencil: VkClearDepthStencilValue(depth: 1)))
  var rendering = VkRenderingInfo(sType: VK_STRUCTURE_TYPE_RENDERING_INFO,
    renderArea: VkRect2D(extent: VkExtent2D(width: 1024, height: 1024)), layerCount: 1,
    colorAttachmentCount: 1, pColorAttachments: addr colorAttachment, pDepthAttachment: addr depthAttachment)
  vkCmdBeginRendering(commandBuffer, addr rendering)
  var viewport = VkViewport(width: 1024, height: 1024, minDepth: 0, maxDepth: 1)
  var scissor = rendering.renderArea
  vkCmdSetViewport(commandBuffer, 0, 1, addr viewport)
  vkCmdSetScissor(commandBuffer, 0, 1, addr scissor)

proc resolveTransmission(renderer: Renderer, commandBuffer: VkCommandBuffer) =
  let texture = renderer.transmission
  let colorAspect = VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT)
  let transfer = VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_TRANSFER_BIT)
  let read = VkAccessFlags2(VK_ACCESS_2_TRANSFER_READ_BIT)
  let write = VkAccessFlags2(VK_ACCESS_2_TRANSFER_WRITE_BIT)
  commandBuffer.cmdImageBarrier(renderer.transmissionMsaa.image, colorAspect,
    VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
    VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT), transfer,
    VkAccessFlags2(VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT), read)
  for level in 0 .. 10:
    commandBuffer.cmdImageBarrier(texture.image, colorAspect, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
      VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT), transfer,
      VkAccessFlags2(VK_ACCESS_2_SHADER_SAMPLED_READ_BIT), write, level)
  var region = VkImageResolve(srcSubresource: VkImageSubresourceLayers(aspectMask: colorAspect, layerCount: 1),
    dstSubresource: VkImageSubresourceLayers(aspectMask: colorAspect, layerCount: 1),
    extent: VkExtent3D(width: 1024, height: 1024, depth: 1))
  vkCmdResolveImage(commandBuffer, renderer.transmissionMsaa.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
    texture.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, addr region)
  for level in 0 .. 10:
    commandBuffer.cmdImageBarrier(texture.image, colorAspect, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
      VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, transfer, transfer, write, read, level)
    if level < 10:
      let sourceSize = 1024 shr level
      var blit = VkImageBlit(srcSubresource: VkImageSubresourceLayers(aspectMask: colorAspect, mipLevel: level.uint32, layerCount: 1),
        srcOffsets: [VkOffset3D(), VkOffset3D(x: sourceSize.int32, y: sourceSize.int32, z: 1)],
        dstSubresource: VkImageSubresourceLayers(aspectMask: colorAspect, mipLevel: (level + 1).uint32, layerCount: 1),
        dstOffsets: [VkOffset3D(), VkOffset3D(x: (sourceSize div 2).int32, y: (sourceSize div 2).int32, z: 1)])
      vkCmdBlitImage(commandBuffer, texture.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        texture.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, addr blit, VK_FILTER_LINEAR)
    commandBuffer.cmdImageBarrier(texture.image, colorAspect, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
      VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, transfer, VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT),
      read, VkAccessFlags2(VK_ACCESS_2_SHADER_SAMPLED_READ_BIT), level)

proc attachIblEnvironment*(ctx: PbrContext, environment: IblEnvironment) =
  let renderer = ctx.renderer
  discard vkDeviceWaitIdle(renderer.ctx.device)
  inc renderer.environmentVersion
  for texture in renderer.environment.values: renderer.releaseTexture(texture)
  renderer.environment.clear()
  for name, texture in environment.textures:
    var parts: seq[RgbaSubresource]
    for level in texture.subresources:
      parts.add(RgbaSubresource(width: level.width, height: level.width, floatBytes: level.bytes))
    renderer.environment[name] = renderer.uploadRgbaSubresources(parts[0].width, parts[0].height,
      texture.levels, (if texture.cube: 6 else: 1), parts, texture.cube, VK_FORMAT_R32G32B32A32_SFLOAT)
    if not texture.cube:
      let asset = renderer.environment[name]
      vkDestroySampler(renderer.ctx.device, asset.sampler, nil)
      asset.sampler = renderer.createSampler(texture.levels, clampToEdge = true)
  ctx.iblEnvironment = environment
  ctx.useIbl = true
  ctx.environmentMipCount = environment.mipCount
  ctx.environmentMapStrength = environment.intensityScale
  renderer.sampleCount = VK_SAMPLE_COUNT_1_BIT
  renderer.destroySwapChainResources()
  renderer.createSwapChainResources()
  renderer.createHdr(renderer.readbackSize)
  renderer.createTransmission()

proc beginIblFrame*(ctx: PbrContext) =
  doAssert ctx.useIbl, "Attach an IBL environment first"

proc endIblFrame*(ctx: PbrContext) =
  ## draw submits the complete Vulkan frame, including presentation.
  discard ctx

proc prepareHdr(renderer: Renderer, commandBuffer: VkCommandBuffer,
    clearColor: Color): array[2, VkRenderingAttachmentInfo] =
  for i, texture in [renderer.hdrColor, renderer.hdrFlags]:
    commandBuffer.cmdImageBarrier(texture.image, VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
      VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
      VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_NONE), VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT),
      VkAccessFlags2(VK_ACCESS_2_NONE), VkAccessFlags2(VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT))
    result[i] = VkRenderingAttachmentInfo(sType: VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
      imageView: texture.view, imageLayout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
      loadOp: VK_ATTACHMENT_LOAD_OP_CLEAR, storeOp: VK_ATTACHMENT_STORE_OP_STORE)
  result[0].clearValue = VkClearValue(color: VkClearColorValue(float32:
    [pow(clearColor.r, 2.2'f), pow(clearColor.g, 2.2'f), pow(clearColor.b, 2.2'f), clearColor.a]))
  result[1].clearValue = VkClearValue(color: VkClearColorValue(uint32: [1'u32, 0, 0, 0]))

proc presentHdr(renderer: Renderer, commandBuffer: VkCommandBuffer, target: VkImageView) =
  for texture in [renderer.hdrColor, renderer.hdrFlags]:
    commandBuffer.cmdImageBarrier(texture.image, VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
      VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
      VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT), VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT),
      VkAccessFlags2(VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT), VkAccessFlags2(VK_ACCESS_2_SHADER_SAMPLED_READ_BIT))
  var attachment = VkRenderingAttachmentInfo(sType: VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
    imageView: target, imageLayout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    loadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE, storeOp: VK_ATTACHMENT_STORE_OP_STORE)
  var rendering = VkRenderingInfo(sType: VK_STRUCTURE_TYPE_RENDERING_INFO,
    renderArea: VkRect2D(extent: renderer.ctx.swapChainExtent), layerCount: 1,
    colorAttachmentCount: 1, pColorAttachments: addr attachment)
  vkCmdBeginRendering(commandBuffer, addr rendering)
  vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
    renderer.getPipeline(PipelineKey(topology: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST.uint32, post: true)))
  var data = newUniformData(PostLayout)
  data.put("exposure", renderer.frame.exposure)
  data.put("framebufferYDown", true)
  vkCmdPushConstants(commandBuffer, renderer.pipelineLayout, VkShaderStageFlags(VK_SHADER_STAGE_FRAGMENT_BIT), 0,
    (data.words.len * 4).uint32, addr data.words[0])
  vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, renderer.pipelineLayout,
    0, 1, addr renderer.postMaterial.descriptorSet, 0, nil)
  var offset = VkDeviceSize(0)
  vkCmdBindVertexBuffers(commandBuffer, 0, 1, addr renderer.fullscreen.buffer, addr offset)
  vkCmdDraw(commandBuffer, 3, 1, 0, 0)
  vkCmdEndRendering(commandBuffer)

proc destroyIbl(renderer: Renderer) =
  for binding in renderer.materialBindings.values: renderer.releaseMaterial(binding)
  renderer.materialBindings.clear()
  renderer.releaseTexture(renderer.defaultWhite)
  renderer.releaseTexture(renderer.defaultNormal)
  for texture in renderer.environment.values: renderer.releaseTexture(texture)
  renderer.environment.clear()
  renderer.releaseTexture(renderer.hdrColor)
  renderer.releaseTexture(renderer.hdrFlags)
  renderer.releaseMaterial(renderer.postMaterial)
  for texture in [renderer.transmission, renderer.transmissionMsaa, renderer.transmissionDepth]:
    renderer.releaseTexture(texture)
  if renderer.fullscreen.buffer.int64 != 0:
    vkDestroyBuffer(renderer.ctx.device, renderer.fullscreen.buffer, nil)
    vkFreeMemory(renderer.ctx.device, renderer.fullscreen.memory, nil)
