## Vulkan backend shader sources and renderer.

when not defined(windows):
  {.error: "The glTF Vulkan backend requires Windows.".}

import
  std/[math, tables],
  chroma, pixie, vmath, windy,
  ../../common, ../../models,
  ./common, ../shader_layout, ../pbr_uniforms, ../ibl_data,
  ../shaders as shaderSources

export ibl_data

import pkg/vk14 except Window

import std/os, shady

const
  VertexEntryPoint* = "main"
  FragmentEntryPoint* = "main"

  PbrVertexShader* = shaderSources.PbrVertVulkan
  PbrFragmentShader* = shaderSources.PbrFragVulkan
  SkyboxVertexShader* = shaderSources.SkyboxVertVulkan
  SkyboxFragmentShader* = shaderSources.SkyboxFragVulkan
  ShadowDepthVertexShader* = shaderSources.ShadowDepthVertVulkan
  ShadowDepthFragmentShader* = shaderSources.ShadowDepthFragVulkan

  VertexLayout = shaderLayout(shaderSources.PbrVertVulkan, std140Packing)
  PixelLayout = shaderLayout(shaderSources.PbrFragVulkan, std140Packing)
  IblLayout = shaderLayout(shaderSources.IblFragVulkan, std140Packing)
  PostLayout = shaderLayout(shaderSources.HdrPostFragVulkan, std140Packing)
  TextureDescriptorCount = 28
  VertexUniformBinding = 0
  PixelUniformBinding = 1
  MaxFrameUniformSets = 8192
  StudioEnvSize = 8
  DepthFormat = VK_FORMAT_D32_SFLOAT
  PreferredMsaaSamples = 8'u32

const
  ShaderCacheDir = getTempDir() / "gltf-shady-vulkan"
  PbrVertexGlslPath = ShaderCacheDir / "gltf_pbr.vert"
  PbrFragmentGlslPath = ShaderCacheDir / "gltf_pbr.frag"
  PbrVertexSpvPath = ShaderCacheDir / "gltf_pbr.vert.spv"
  PbrFragmentSpvPath = ShaderCacheDir / "gltf_pbr.frag.spv"

type
  VkVertex {.packed.} = object
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

  FrameBuffer = object
    buffer: VkBuffer
    memory: VkDeviceMemory
    offset: VkDeviceSize

  Renderer* = ref object
    window: Window
    frame: PbrFrameUniforms
    environment: Table[string, VkTexture]
    environmentVersion: uint64
    materialBindings: Table[string, VkMaterial]
    defaultWhite, defaultNormal: VkTexture
    geometryBlocks, uniformBlocks: seq[VkBufferBlock]
    hdrColor, hdrFlags: VkTexture
    hdrSize: IVec2
    postMaterial: VkMaterial
    fullscreen: FrameBuffer
    transmission, transmissionMsaa, transmissionDepth: VkTexture
    ctx: VulkanContext
    materialSetLayout: VkDescriptorSetLayout
    uniformSetLayout: VkDescriptorSetLayout
    pipelineLayout: VkPipelineLayout
    pipelineStates: Table[PipelineKey, VkPipeline]
    sampleCount: VkSampleCountFlagBits
    imageViews: seq[VkImageView]
    imageLayouts: seq[VkImageLayout]
    colorImages: seq[VkImage]
    colorMemories: seq[VkDeviceMemory]
    colorViews: seq[VkImageView]
    depthImages: seq[VkImage]
    depthMemories: seq[VkDeviceMemory]
    depthViews: seq[VkImageView]
    commandBuffers: seq[VkCommandBuffer]
    frameDescriptorPools: seq[VkDescriptorPool]
    frameUniformSets, uniformAlignment: int
    readbackBuffer: VkBuffer
    readbackMemory: VkDeviceMemory
    readbackSize: IVec2

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

proc perspectiveVkRh*(fovY, aspect, nearPlane, farPlane: float32): Mat4 =
  ## Vulkan right-handed projection matrix for vmath camera transforms.
  let
    h = 1.0'f32 / tan(degToRad(fovY) * 0.5'f32)
    w = h / aspect
    depth = nearPlane - farPlane
  result[0, 0] = w
  result[1, 1] = h
  result[2, 2] = farPlane / depth
  result[2, 3] = -1.0'f32
  result[3, 2] = (nearPlane * farPlane) / depth

proc requiresSwapChainRecreate(vkResult: VkResult): bool =
  let code = vkResult.int32
  code == VK_SUBOPTIMAL_KHR.int32 or
    code == VK_ERROR_OUT_OF_DATE_KHR.int32

proc createShaderModule(device: VkDevice, code: string): VkShaderModule =
  var createInfo = VkShaderModuleCreateInfo(
    sType: VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
    codeSize: code.len.uint32,
    pCode: cast[ptr uint32](code[0].unsafeAddr)
  )
  checkVk(vkCreateShaderModule(device, createInfo.addr, nil, result.addr),
    "Creating Vulkan shader module")

proc findMemoryType(
  ctx: VulkanContext, typeFilter: uint32, properties: uint32
): uint32 =
  var memProperties: VkPhysicalDeviceMemoryProperties
  vkGetPhysicalDeviceMemoryProperties(ctx.physicalDevice, memProperties.addr)
  for i in 0'u32 ..< memProperties.memoryTypeCount:
    let flags = memProperties.memoryTypes[i].propertyFlags.uint32
    if ((typeFilter shr i) and 1'u32) == 1'u32 and
       (flags and properties) == properties:
      return i
  raise newException(GltfError, "Failed to find suitable Vulkan memory type.")

proc chooseMsaaSampleCount(ctx: VulkanContext): VkSampleCountFlagBits =
  var props: VkPhysicalDeviceProperties
  vkGetPhysicalDeviceProperties(ctx.physicalDevice, props.addr)
  let counts = props.limits.framebufferColorSampleCounts.uint32 and
    props.limits.framebufferDepthSampleCounts.uint32
  if PreferredMsaaSamples >= 8 and
    (counts and VK_SAMPLE_COUNT_8_BIT.uint32) != 0:
    return VK_SAMPLE_COUNT_8_BIT
  if PreferredMsaaSamples >= 4 and
    (counts and VK_SAMPLE_COUNT_4_BIT.uint32) != 0:
    return VK_SAMPLE_COUNT_4_BIT
  if (counts and VK_SAMPLE_COUNT_2_BIT.uint32) != 0:
    return VK_SAMPLE_COUNT_2_BIT
  VK_SAMPLE_COUNT_1_BIT

proc msaaEnabled(renderer: Renderer): bool =
  renderer.sampleCount != VK_SAMPLE_COUNT_1_BIT

proc createBuffer(
  ctx: VulkanContext,
  size: VkDeviceSize,
  usage, properties: uint32,
  buffer: var VkBuffer,
  memory: var VkDeviceMemory
) =
  var bufferInfo = VkBufferCreateInfo(
    sType: VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
    size: max(VkDeviceSize(1), size),
    usage: VkBufferUsageFlags(usage),
    sharingMode: VK_SHARING_MODE_EXCLUSIVE
  )
  checkVk(vkCreateBuffer(ctx.device, bufferInfo.addr, nil, buffer.addr),
    "Creating Vulkan buffer")

  var memRequirements: VkMemoryRequirements
  vkGetBufferMemoryRequirements(ctx.device, buffer, memRequirements.addr)

  var allocInfo = VkMemoryAllocateInfo(
    sType: VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
    allocationSize: memRequirements.size,
    memoryTypeIndex: findMemoryType(ctx, memRequirements.memoryTypeBits, properties)
  )
  checkVk(vkAllocateMemory(ctx.device, allocInfo.addr, nil, memory.addr),
    "Allocating Vulkan buffer memory")
  checkVk(vkBindBufferMemory(ctx.device, buffer, memory, VkDeviceSize(0)),
    "Binding Vulkan buffer memory")

proc allocateBuffer(renderer: Renderer, blocks: var seq[VkBufferBlock],
    size, alignment: int): tuple[storage: VkBufferBlock, offset: int] =
  for storage in blocks:
    if storage.users == 0: storage.used = 0
    let offset = (storage.used + alignment - 1) div alignment * alignment
    if offset + size <= storage.capacity:
      storage.used = offset + size
      inc storage.users
      return (storage, offset)
  let storage = VkBufferBlock(capacity: max(8 * 1024 * 1024, size), used: size, users: 1)
  createBuffer(renderer.ctx, VkDeviceSize(storage.capacity),
    VK_BUFFER_USAGE_VERTEX_BUFFER_BIT.uint32 or VK_BUFFER_USAGE_INDEX_BUFFER_BIT.uint32 or VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT.uint32,
    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.uint32 or VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.uint32,
    storage.buffer, storage.memory)
  checkVk(vkMapMemory(renderer.ctx.device, storage.memory, VkDeviceSize(0),
    VkDeviceSize(storage.capacity), VkMemoryMapFlags(0), addr storage.mapped), "Mapping buffer arena")
  blocks.add(storage)
  (storage, 0)

proc destroyBlocks(renderer: Renderer, blocks: var seq[VkBufferBlock]) =
  for storage in blocks:
    vkUnmapMemory(renderer.ctx.device, storage.memory)
    vkDestroyBuffer(renderer.ctx.device, storage.buffer, nil)
    vkFreeMemory(renderer.ctx.device, storage.memory, nil)
  blocks.setLen(0)

proc createImage(
  ctx: VulkanContext,
  width, height, mipLevels, layers: int,
  format: VkFormat,
  usage: uint32,
  imageFlags: uint32,
  samples: VkSampleCountFlagBits,
  image: var VkImage,
  memory: var VkDeviceMemory
) =
  var imageInfo = VkImageCreateInfo(
    sType: VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
    flags: VkImageCreateFlags(imageFlags),
    imageType: VK_IMAGE_TYPE_2D,
    format: format,
    extent: VkExtent3D(width: width.uint32, height: height.uint32, depth: 1),
    mipLevels: mipLevels.uint32,
    arrayLayers: layers.uint32,
    samples: samples,
    tiling: VK_IMAGE_TILING_OPTIMAL,
    usage: VkImageUsageFlags(usage),
    sharingMode: VK_SHARING_MODE_EXCLUSIVE,
    initialLayout: VK_IMAGE_LAYOUT_UNDEFINED
  )
  checkVk(vkCreateImage(ctx.device, imageInfo.addr, nil, image.addr),
    "Creating Vulkan image")

  var memRequirements: VkMemoryRequirements
  vkGetImageMemoryRequirements(ctx.device, image, memRequirements.addr)
  var allocInfo = VkMemoryAllocateInfo(
    sType: VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
    allocationSize: memRequirements.size,
    memoryTypeIndex: findMemoryType(ctx,
      memRequirements.memoryTypeBits,
      VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.uint32)
  )
  checkVk(vkAllocateMemory(ctx.device, allocInfo.addr, nil, memory.addr),
    "Allocating Vulkan image memory")
  checkVk(vkBindImageMemory(ctx.device, image, memory, VkDeviceSize(0)),
    "Binding Vulkan image memory")

proc beginSingleTimeCommands(ctx: VulkanContext): VkCommandBuffer =
  var allocInfo = VkCommandBufferAllocateInfo(
    sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
    commandPool: ctx.commandPool,
    level: VK_COMMAND_BUFFER_LEVEL_PRIMARY,
    commandBufferCount: 1
  )
  checkVk(vkAllocateCommandBuffers(ctx.device, allocInfo.addr, result.addr),
    "Allocating Vulkan upload command buffer")
  var beginInfo = VkCommandBufferBeginInfo(
    sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
    flags: VkCommandBufferUsageFlags(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT)
  )
  checkVk(vkBeginCommandBuffer(result, beginInfo.addr),
    "Beginning Vulkan upload command buffer")

proc endSingleTimeCommands(ctx: VulkanContext, commandBuffer: VkCommandBuffer) =
  checkVk(vkEndCommandBuffer(commandBuffer),
    "Ending Vulkan upload command buffer")
  var submitInfo = VkSubmitInfo(
    sType: VK_STRUCTURE_TYPE_SUBMIT_INFO,
    commandBufferCount: 1,
    pCommandBuffers: unsafeAddr commandBuffer
  )
  checkVk(vkQueueSubmit(ctx.graphicsQueue, 1, submitInfo.addr, VkFence(0)),
    "Submitting Vulkan upload command buffer")
  checkVk(vkQueueWaitIdle(ctx.graphicsQueue), "Waiting for Vulkan upload")
  vkFreeCommandBuffers(ctx.device, ctx.commandPool, 1, unsafeAddr commandBuffer)

proc transitionImageLayout(
  ctx: VulkanContext,
  image: VkImage,
  aspect: VkImageAspectFlags,
  mipLevels, layers: int,
  oldLayout, newLayout: VkImageLayout
) =
  let commandBuffer = beginSingleTimeCommands(ctx)
  var barrier = VkImageMemoryBarrier(
    sType: VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
    oldLayout: oldLayout,
    newLayout: newLayout,
    srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
    image: image,
    subresourceRange: VkImageSubresourceRange(
      aspectMask: aspect,
      baseMipLevel: 0,
      levelCount: mipLevels.uint32,
      baseArrayLayer: 0,
      layerCount: layers.uint32
    )
  )

  var sourceStage, destinationStage: VkPipelineStageFlags
  if oldLayout == VK_IMAGE_LAYOUT_UNDEFINED and
     newLayout == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL:
    barrier.srcAccessMask = VkAccessFlags(0)
    barrier.dstAccessMask = VkAccessFlags(VK_ACCESS_TRANSFER_WRITE_BIT)
    sourceStage = VkPipelineStageFlags(VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT)
    destinationStage = VkPipelineStageFlags(VK_PIPELINE_STAGE_TRANSFER_BIT)
  elif oldLayout == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL and
       newLayout == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL:
    barrier.srcAccessMask = VkAccessFlags(VK_ACCESS_TRANSFER_WRITE_BIT)
    barrier.dstAccessMask = VkAccessFlags(VK_ACCESS_SHADER_READ_BIT)
    sourceStage = VkPipelineStageFlags(VK_PIPELINE_STAGE_TRANSFER_BIT)
    destinationStage = VkPipelineStageFlags(VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT)
  else:
    raise newException(GltfError, "Unsupported Vulkan image layout transition.")

  vkCmdPipelineBarrier(commandBuffer, sourceStage, destinationStage,
    VkDependencyFlags(0), 0, nil, 0, nil, 1, barrier.addr)
  endSingleTimeCommands(ctx, commandBuffer)

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

proc buildImageMips(image: Image): seq[RgbaSubresource] =
  buildMipChain(RgbaSubresource(
    width: image.width,
    height: image.height,
    pixels: image.data
  ))

proc studioFaceDirection(face, x, y, size: int): Vec3 =
  let
    u = ((x.float32 + 0.5'f32) / size.float32) * 2.0'f32 - 1.0'f32
    v = ((y.float32 + 0.5'f32) / size.float32) * 2.0'f32 - 1.0'f32
  case face
  of 0: normalize(vec3(1.0'f32, -v, -u))
  of 1: normalize(vec3(-1.0'f32, -v, u))
  of 2: normalize(vec3(u, 1.0'f32, v))
  of 3: normalize(vec3(u, -1.0'f32, -v))
  of 4: normalize(vec3(u, -v, 1.0'f32))
  of 5: normalize(vec3(-u, -v, -1.0'f32))
  else: vec3(0, 1, 0)

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

proc createSampler(
  renderer: Renderer,
  mipLevels: int,
  clampToEdge = false,
  compare = false
): VkSampler =
  let addressMode =
    if clampToEdge: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    else: VK_SAMPLER_ADDRESS_MODE_REPEAT
  var samplerInfo = VkSamplerCreateInfo(
    sType: VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
    magFilter: VK_FILTER_LINEAR,
    minFilter: VK_FILTER_LINEAR,
    mipmapMode: VK_SAMPLER_MIPMAP_MODE_LINEAR,
    addressModeU: addressMode,
    addressModeV: addressMode,
    addressModeW: addressMode,
    anisotropyEnable: VkBool32(VK_FALSE),
    maxAnisotropy: 1.0,
    compareEnable: VkBool32(if compare: VK_TRUE else: VK_FALSE),
    compareOp: if compare: VK_COMPARE_OP_LESS_OR_EQUAL else: VK_COMPARE_OP_ALWAYS,
    minLod: 0.0,
    maxLod: max(0, mipLevels - 1).float32,
    borderColor: VK_BORDER_COLOR_INT_OPAQUE_WHITE,
    unnormalizedCoordinates: VkBool32(VK_FALSE)
  )
  checkVk(vkCreateSampler(renderer.ctx.device, samplerInfo.addr, nil, result.addr),
    "Creating Vulkan sampler")

proc uploadRgbaSubresources(
  renderer: Renderer,
  width, height, mipLevels, layers: int,
  subresources: openArray[RgbaSubresource],
  isCube = false,
  format = VK_FORMAT_R8G8B8A8_UNORM
): VkTexture =
  let
    subresourceCount = mipLevels * layers
    imageFlags =
      if isCube: VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT.uint32
      else: 0'u32
  var offsets = newSeq[VkDeviceSize](subresourceCount)
  var totalBytes = VkDeviceSize(0)
  for i in 0 ..< subresourceCount:
    offsets[i] = totalBytes
    totalBytes += VkDeviceSize(subresources[i].width * subresources[i].height * (if subresources[i].floatBytes.len > 0: 16 else: 4))

  var stagingBuffer: VkBuffer
  var stagingMemory: VkDeviceMemory
  createBuffer(renderer.ctx, totalBytes,
    VK_BUFFER_USAGE_TRANSFER_SRC_BIT.uint32,
    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.uint32 or
      VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.uint32,
    stagingBuffer, stagingMemory)

  var mapped: pointer
  checkVk(vkMapMemory(renderer.ctx.device, stagingMemory,
    VkDeviceSize(0), totalBytes, VkMemoryMapFlags(0), mapped.addr),
    "Mapping Vulkan texture staging memory")
  let base = cast[uint](mapped)
  for i in 0 ..< subresourceCount:
    let src = subresources[i]
    let dst = cast[pointer](base + uint(offsets[i]))
    if src.floatBytes.len > 0: copyMem(dst, unsafeAddr src.floatBytes[0], src.floatBytes.len)
    else: copyMem(dst, unsafeAddr src.pixels[0], src.width * src.height * 4)
  vkUnmapMemory(renderer.ctx.device, stagingMemory)

  var image: VkImage
  var memory: VkDeviceMemory
  createImage(renderer.ctx, width, height, mipLevels, layers,
    format,
    VK_IMAGE_USAGE_TRANSFER_DST_BIT.uint32 or VK_IMAGE_USAGE_SAMPLED_BIT.uint32,
    imageFlags, VK_SAMPLE_COUNT_1_BIT, image, memory)

  transitionImageLayout(renderer.ctx, image,
    VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
    mipLevels, layers,
    VK_IMAGE_LAYOUT_UNDEFINED,
    VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)

  var regions = newSeq[VkBufferImageCopy](subresourceCount)
  for i in 0 ..< subresourceCount:
    let
      face = i div mipLevels
      mip = i mod mipLevels
      src = subresources[i]
    regions[i] = VkBufferImageCopy(
      bufferOffset: offsets[i],
      imageSubresource: VkImageSubresourceLayers(
        aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
        mipLevel: mip.uint32,
        baseArrayLayer: face.uint32,
        layerCount: 1
      ),
      imageExtent: VkExtent3D(
        width: src.width.uint32,
        height: src.height.uint32,
        depth: 1
      )
    )
  let commandBuffer = beginSingleTimeCommands(renderer.ctx)
  vkCmdCopyBufferToImage(commandBuffer, stagingBuffer, image,
    VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    regions.len.uint32, regions[0].addr)
  endSingleTimeCommands(renderer.ctx, commandBuffer)

  transitionImageLayout(renderer.ctx, image,
    VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
    mipLevels, layers,
    VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)

  vkDestroyBuffer(renderer.ctx.device, stagingBuffer, nil)
  vkFreeMemory(renderer.ctx.device, stagingMemory, nil)

  var view: VkImageView
  var viewInfo = VkImageViewCreateInfo(
    sType: VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
    image: image,
    viewType: if isCube: VK_IMAGE_VIEW_TYPE_CUBE else: VK_IMAGE_VIEW_TYPE_2D,
    format: format,
    components: VkComponentMapping(
      r: VK_COMPONENT_SWIZZLE_IDENTITY,
      g: VK_COMPONENT_SWIZZLE_IDENTITY,
      b: VK_COMPONENT_SWIZZLE_IDENTITY,
      a: VK_COMPONENT_SWIZZLE_IDENTITY
    ),
    subresourceRange: VkImageSubresourceRange(
      aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
      baseMipLevel: 0,
      levelCount: mipLevels.uint32,
      baseArrayLayer: 0,
      layerCount: layers.uint32
    )
  )
  checkVk(vkCreateImageView(renderer.ctx.device, viewInfo.addr, nil, view.addr),
    "Creating Vulkan texture view")

  VkTexture(
    image: image,
    memory: memory,
    view: view,
    sampler: renderer.createSampler(mipLevels, clampToEdge = isCube),
    format: format,
    mipLevels: mipLevels,
    layers: layers,
    isCube: isCube
  )

proc uploadImage(renderer: Renderer, image: Image, srgb = false): VkTexture =
  let mips = image.buildImageMips()
  renderer.uploadRgbaSubresources(image.width, image.height, mips.len, 1, mips,
    format = (if srgb: VK_FORMAT_R8G8B8A8_SRGB else: VK_FORMAT_R8G8B8A8_UNORM))

proc uploadSolidImage(renderer: Renderer, color: ColorRGBX): VkTexture =
  var image = newImage(1, 1)
  image.fill(color)
  renderer.uploadImage(image)

proc uploadStudioCube(renderer: Renderer): VkTexture =
  let mips = buildStudioCubeMips()
  renderer.uploadRgbaSubresources(
    StudioEnvSize,
    StudioEnvSize,
    mips.len div 6,
    6,
    mips,
    isCube = true
  )

proc uploadShadowPlaceholder(renderer: Renderer): VkTexture =
  var pixel = 1.0'f32
  var stagingBuffer: VkBuffer
  var stagingMemory: VkDeviceMemory
  createBuffer(renderer.ctx, VkDeviceSize(sizeof(float32)),
    VK_BUFFER_USAGE_TRANSFER_SRC_BIT.uint32,
    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.uint32 or
      VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.uint32,
    stagingBuffer, stagingMemory)
  var mapped: pointer
  checkVk(vkMapMemory(renderer.ctx.device, stagingMemory,
    VkDeviceSize(0), VkDeviceSize(sizeof(float32)),
    VkMemoryMapFlags(0), mapped.addr),
    "Mapping Vulkan shadow placeholder staging memory")
  copyMem(mapped, pixel.addr, sizeof(float32))
  vkUnmapMemory(renderer.ctx.device, stagingMemory)

  var image: VkImage
  var memory: VkDeviceMemory
  createImage(renderer.ctx, 1, 1, 1, 1, DepthFormat,
    VK_IMAGE_USAGE_TRANSFER_DST_BIT.uint32 or VK_IMAGE_USAGE_SAMPLED_BIT.uint32,
    0, VK_SAMPLE_COUNT_1_BIT, image, memory)
  transitionImageLayout(renderer.ctx, image,
    VkImageAspectFlags(VK_IMAGE_ASPECT_DEPTH_BIT), 1, 1,
    VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)

  var region = VkBufferImageCopy(
    bufferOffset: VkDeviceSize(0),
    imageSubresource: VkImageSubresourceLayers(
      aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_DEPTH_BIT),
      mipLevel: 0,
      baseArrayLayer: 0,
      layerCount: 1
    ),
    imageExtent: VkExtent3D(width: 1, height: 1, depth: 1)
  )
  let commandBuffer = beginSingleTimeCommands(renderer.ctx)
  vkCmdCopyBufferToImage(commandBuffer, stagingBuffer, image,
    VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, region.addr)
  endSingleTimeCommands(renderer.ctx, commandBuffer)

  transitionImageLayout(renderer.ctx, image,
    VkImageAspectFlags(VK_IMAGE_ASPECT_DEPTH_BIT), 1, 1,
    VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)

  vkDestroyBuffer(renderer.ctx.device, stagingBuffer, nil)
  vkFreeMemory(renderer.ctx.device, stagingMemory, nil)

  var view: VkImageView
  var viewInfo = VkImageViewCreateInfo(
    sType: VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
    image: image,
    viewType: VK_IMAGE_VIEW_TYPE_2D,
    format: DepthFormat,
    components: VkComponentMapping(
      r: VK_COMPONENT_SWIZZLE_IDENTITY,
      g: VK_COMPONENT_SWIZZLE_IDENTITY,
      b: VK_COMPONENT_SWIZZLE_IDENTITY,
      a: VK_COMPONENT_SWIZZLE_IDENTITY
    ),
    subresourceRange: VkImageSubresourceRange(
      aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_DEPTH_BIT),
      baseMipLevel: 0,
      levelCount: 1,
      baseArrayLayer: 0,
      layerCount: 1
    )
  )
  checkVk(vkCreateImageView(renderer.ctx.device, viewInfo.addr, nil, view.addr),
    "Creating Vulkan shadow placeholder view")

  VkTexture(
    image: image,
    memory: memory,
    view: view,
    sampler: renderer.createSampler(1, clampToEdge = true, compare = true),
    format: DepthFormat,
    mipLevels: 1,
    layers: 1
  )

proc createSwapChainImageViews(renderer: Renderer) =
  renderer.imageViews.setLen(renderer.ctx.swapChainImages.len)
  renderer.imageLayouts.setLen(renderer.ctx.swapChainImages.len)
  for i, image in renderer.ctx.swapChainImages:
    renderer.imageLayouts[i] = VK_IMAGE_LAYOUT_UNDEFINED
    var createInfo = VkImageViewCreateInfo(
      sType: VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
      image: image,
      viewType: VK_IMAGE_VIEW_TYPE_2D,
      format: renderer.ctx.swapChainImageFormat,
      components: VkComponentMapping(
        r: VK_COMPONENT_SWIZZLE_IDENTITY,
        g: VK_COMPONENT_SWIZZLE_IDENTITY,
        b: VK_COMPONENT_SWIZZLE_IDENTITY,
        a: VK_COMPONENT_SWIZZLE_IDENTITY
      ),
      subresourceRange: VkImageSubresourceRange(
        aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
        baseMipLevel: 0,
        levelCount: 1,
        baseArrayLayer: 0,
        layerCount: 1
      )
    )
    checkVk(vkCreateImageView(renderer.ctx.device, createInfo.addr, nil,
      renderer.imageViews[i].addr),
      "Creating Vulkan swapchain image view")

proc createColorResources(renderer: Renderer) =
  renderer.colorImages.setLen(0)
  renderer.colorMemories.setLen(0)
  renderer.colorViews.setLen(0)
  if not renderer.msaaEnabled:
    return

  let count = renderer.ctx.swapChainImages.len
  renderer.colorImages.setLen(count)
  renderer.colorMemories.setLen(count)
  renderer.colorViews.setLen(count)
  for i in 0 ..< count:
    createImage(renderer.ctx,
      renderer.ctx.swapChainExtent.width.int,
      renderer.ctx.swapChainExtent.height.int,
      1, 1, renderer.ctx.swapChainImageFormat,
      VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT.uint32 or
        VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.uint32,
      0,
      renderer.sampleCount,
      renderer.colorImages[i],
      renderer.colorMemories[i])
    var imageViewInfo = VkImageViewCreateInfo(
      sType: VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
      image: renderer.colorImages[i],
      viewType: VK_IMAGE_VIEW_TYPE_2D,
      format: renderer.ctx.swapChainImageFormat,
      components: VkComponentMapping(
        r: VK_COMPONENT_SWIZZLE_IDENTITY,
        g: VK_COMPONENT_SWIZZLE_IDENTITY,
        b: VK_COMPONENT_SWIZZLE_IDENTITY,
        a: VK_COMPONENT_SWIZZLE_IDENTITY
      ),
      subresourceRange: VkImageSubresourceRange(
        aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
        baseMipLevel: 0,
        levelCount: 1,
        baseArrayLayer: 0,
        layerCount: 1
      )
    )
    checkVk(vkCreateImageView(renderer.ctx.device, imageViewInfo.addr, nil,
      renderer.colorViews[i].addr),
      "Creating Vulkan multisample color image view")

proc createDepthResources(renderer: Renderer) =
  let count = renderer.ctx.swapChainImages.len
  renderer.depthImages.setLen(count)
  renderer.depthMemories.setLen(count)
  renderer.depthViews.setLen(count)
  for i in 0 ..< count:
    createImage(renderer.ctx,
      renderer.ctx.swapChainExtent.width.int,
      renderer.ctx.swapChainExtent.height.int,
      1, 1, DepthFormat,
      VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT.uint32,
      0,
      renderer.sampleCount,
      renderer.depthImages[i],
      renderer.depthMemories[i])
    var imageViewInfo = VkImageViewCreateInfo(
      sType: VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
      image: renderer.depthImages[i],
      viewType: VK_IMAGE_VIEW_TYPE_2D,
      format: DepthFormat,
      components: VkComponentMapping(
        r: VK_COMPONENT_SWIZZLE_IDENTITY,
        g: VK_COMPONENT_SWIZZLE_IDENTITY,
        b: VK_COMPONENT_SWIZZLE_IDENTITY,
        a: VK_COMPONENT_SWIZZLE_IDENTITY
      ),
      subresourceRange: VkImageSubresourceRange(
        aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_DEPTH_BIT),
        baseMipLevel: 0,
        levelCount: 1,
        baseArrayLayer: 0,
        layerCount: 1
      )
    )
    checkVk(vkCreateImageView(renderer.ctx.device, imageViewInfo.addr, nil,
      renderer.depthViews[i].addr),
      "Creating Vulkan depth image view")

proc createReadbackBuffer(renderer: Renderer, size: IVec2) =
  if renderer.readbackBuffer.int64 != 0:
    vkDestroyBuffer(renderer.ctx.device, renderer.readbackBuffer, nil)
    vkFreeMemory(renderer.ctx.device, renderer.readbackMemory, nil)
    renderer.readbackBuffer = VkBuffer(0)
    renderer.readbackMemory = VkDeviceMemory(0)

  createBuffer(renderer.ctx, VkDeviceSize(size.x.int * size.y.int * 4),
    VK_BUFFER_USAGE_TRANSFER_DST_BIT.uint32,
    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.uint32 or
      VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.uint32,
    renderer.readbackBuffer,
    renderer.readbackMemory)
  renderer.readbackSize = size

proc allocateCommandBuffers(renderer: Renderer) =
  renderer.commandBuffers.setLen(renderer.ctx.swapChainImages.len)
  var allocInfo = VkCommandBufferAllocateInfo(
    sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
    commandPool: renderer.ctx.commandPool,
    level: VK_COMMAND_BUFFER_LEVEL_PRIMARY,
    commandBufferCount: renderer.commandBuffers.len.uint32
  )
  checkVk(vkAllocateCommandBuffers(renderer.ctx.device, allocInfo.addr,
    renderer.commandBuffers[0].addr),
    "Allocating Vulkan draw command buffers")

proc destroySwapChainResources(renderer: Renderer) =
  if renderer.commandBuffers.len > 0:
    vkFreeCommandBuffers(renderer.ctx.device, renderer.ctx.commandPool,
      renderer.commandBuffers.len.uint32, renderer.commandBuffers[0].addr)
    renderer.commandBuffers.setLen(0)
  for view in renderer.imageViews:
    vkDestroyImageView(renderer.ctx.device, view, nil)
  renderer.imageViews.setLen(0)
  renderer.imageLayouts.setLen(0)
  for view in renderer.colorViews:
    vkDestroyImageView(renderer.ctx.device, view, nil)
  renderer.colorViews.setLen(0)
  for image in renderer.colorImages:
    vkDestroyImage(renderer.ctx.device, image, nil)
  renderer.colorImages.setLen(0)
  for memory in renderer.colorMemories:
    vkFreeMemory(renderer.ctx.device, memory, nil)
  renderer.colorMemories.setLen(0)
  for view in renderer.depthViews:
    vkDestroyImageView(renderer.ctx.device, view, nil)
  renderer.depthViews.setLen(0)
  for image in renderer.depthImages:
    vkDestroyImage(renderer.ctx.device, image, nil)
  renderer.depthImages.setLen(0)
  for memory in renderer.depthMemories:
    vkFreeMemory(renderer.ctx.device, memory, nil)
  renderer.depthMemories.setLen(0)
  for pipeline in renderer.pipelineStates.values:
    vkDestroyPipeline(renderer.ctx.device, pipeline, nil)
  renderer.pipelineStates.clear()

proc createSwapChainResources(renderer: Renderer) =
  renderer.createSwapChainImageViews()
  renderer.createColorResources()
  renderer.createDepthResources()
  renderer.allocateCommandBuffers()
  renderer.createReadbackBuffer(ivec2(
    renderer.ctx.swapChainExtent.width.int32,
    renderer.ctx.swapChainExtent.height.int32
  ))

proc createDescriptorSetLayouts(renderer: Renderer) =
  var materialBindings: array[TextureDescriptorCount, VkDescriptorSetLayoutBinding]
  for i in 0 ..< TextureDescriptorCount:
    materialBindings[i] = VkDescriptorSetLayoutBinding(
      binding: i.uint32,
      descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
      descriptorCount: 1,
      stageFlags: VkShaderStageFlags(VK_SHADER_STAGE_FRAGMENT_BIT)
    )
  var materialLayoutInfo = VkDescriptorSetLayoutCreateInfo(
    sType: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    bindingCount: materialBindings.len.uint32,
    pBindings: materialBindings[0].addr
  )
  checkVk(vkCreateDescriptorSetLayout(renderer.ctx.device,
    materialLayoutInfo.addr, nil, renderer.materialSetLayout.addr),
    "Creating Vulkan material descriptor set layout")

  var uniformBindings = [
    VkDescriptorSetLayoutBinding(
      binding: VertexUniformBinding.uint32,
      descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
      descriptorCount: 1,
      stageFlags: VkShaderStageFlags(VK_SHADER_STAGE_VERTEX_BIT)
    ),
    VkDescriptorSetLayoutBinding(
      binding: PixelUniformBinding.uint32,
      descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
      descriptorCount: 1,
      stageFlags: VkShaderStageFlags(VK_SHADER_STAGE_FRAGMENT_BIT)
    )
  ]
  var uniformLayoutInfo = VkDescriptorSetLayoutCreateInfo(
    sType: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    bindingCount: uniformBindings.len.uint32,
    pBindings: uniformBindings[0].addr
  )
  checkVk(vkCreateDescriptorSetLayout(renderer.ctx.device,
    uniformLayoutInfo.addr, nil, renderer.uniformSetLayout.addr),
    "Creating Vulkan uniform descriptor set layout")

proc createPipelineLayout(renderer: Renderer) =
  var layouts = [renderer.materialSetLayout, renderer.uniformSetLayout]
  var push = VkPushConstantRange(stageFlags: VkShaderStageFlags(VK_SHADER_STAGE_FRAGMENT_BIT), offset: 0, size: 128)
  var pipelineLayoutInfo = VkPipelineLayoutCreateInfo(
    sType: VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
    setLayoutCount: layouts.len.uint32,
    pSetLayouts: layouts[0].addr,
    pushConstantRangeCount: 1, pPushConstantRanges: push.addr
  )
  checkVk(vkCreatePipelineLayout(renderer.ctx.device,
    pipelineLayoutInfo.addr, nil, renderer.pipelineLayout.addr),
    "Creating Vulkan pipeline layout")

proc createFrameDescriptorPool(renderer: Renderer) =
  var poolSize = VkDescriptorPoolSize(
    `type`: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
    descriptorCount: (MaxFrameUniformSets * 2).uint32
  )
  var poolInfo = VkDescriptorPoolCreateInfo(
    sType: VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
    maxSets: MaxFrameUniformSets.uint32,
    poolSizeCount: 1,
    pPoolSizes: poolSize.addr
  )
  var pool: VkDescriptorPool
  checkVk(vkCreateDescriptorPool(renderer.ctx.device, poolInfo.addr, nil,
    pool.addr),
    "Creating Vulkan frame descriptor pool")
  renderer.frameDescriptorPools.add(pool)

proc createPipeline(
  renderer: Renderer,
  key: PipelineKey
): VkPipeline =
  when defined(shadyBinaryShaders):
    const
      vertShaderCode = staticRead("../shaders/gltf_pbr.vert.spv")
      fragShaderCode = staticRead("../shaders/gltf_pbr.frag.spv")
      iblCode = staticRead("../shaders/gltf_ibl.frag.spv")
      postVertCode = staticRead("../shaders/gltf_post.vert.spv")
      postFragCode = staticRead("../shaders/gltf_post.frag.spv")
  else:
    const
      vertShaderCode = compileSpirvShader(
        PbrVertexShader,
        PbrVertexGlslPath,
        PbrVertexSpvPath,
        binaryVertex
      )
      fragShaderCode = compileSpirvShader(
        PbrFragmentShader,
        PbrFragmentGlslPath,
        PbrFragmentSpvPath,
        binaryFragment
      )
      iblCode = compileSpirvShader(shaderSources.IblFragVulkan, ShaderCacheDir / "gltf_ibl.frag", ShaderCacheDir / "gltf_ibl.frag.spv", binaryFragment)
      postVertCode = compileSpirvShader(shaderSources.HdrPostVertVulkan, ShaderCacheDir / "gltf_post.vert", ShaderCacheDir / "gltf_post.vert.spv", binaryVertex)
      postFragCode = compileSpirvShader(shaderSources.HdrPostFragVulkan, ShaderCacheDir / "gltf_post.frag", ShaderCacheDir / "gltf_post.frag.spv", binaryFragment)
  let
    vertModule = createShaderModule(renderer.ctx.device, if key.post: postVertCode else: vertShaderCode)
    fragModule = createShaderModule(renderer.ctx.device, if key.post: postFragCode elif key.ibl: iblCode else: fragShaderCode)
  try:
    var
      colorFormats = [(if key.background: VK_FORMAT_R8G8B8A8_UNORM elif key.ibl: VK_FORMAT_R16G16B16A16_SFLOAT else: renderer.ctx.swapChainImageFormat), VK_FORMAT_R8_UINT]
      renderingInfo = VkPipelineRenderingCreateInfo(
        sType: VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
        colorAttachmentCount: (if key.ibl and not key.background: 2 else: 1),
        pColorAttachmentFormats: colorFormats[0].addr,
        depthAttachmentFormat: (if key.post: VK_FORMAT_UNDEFINED else: DepthFormat)
      )
      dynamicStates = [
        VkDynamicState(VK_DYNAMIC_STATE_VIEWPORT),
        VkDynamicState(VK_DYNAMIC_STATE_SCISSOR)
      ]
      dynamicState = VkPipelineDynamicStateCreateInfo(
        sType: VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        dynamicStateCount: dynamicStates.len.uint32,
        pDynamicStates: dynamicStates[0].addr
      )
      vertStage = VkPipelineShaderStageCreateInfo(
        sType: VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage: VK_SHADER_STAGE_VERTEX_BIT,
        module: vertModule,
        pName: "main"
      )
      fragStage = VkPipelineShaderStageCreateInfo(
        sType: VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage: VK_SHADER_STAGE_FRAGMENT_BIT,
        module: fragModule,
        pName: "main"
      )
      shaderStages = [vertStage, fragStage]
      bindingDesc = VkVertexInputBindingDescription(
        binding: 0,
        stride: (if key.post: 8 else: sizeof(VkVertex)).uint32,
        inputRate: VK_VERTEX_INPUT_RATE_VERTEX
      )
      attributeDescs = [
        VkVertexInputAttributeDescription(
          location: 0, binding: 0, format: (if key.post: VK_FORMAT_R32G32_SFLOAT else: VK_FORMAT_R32G32B32_SFLOAT), offset: 0),
        VkVertexInputAttributeDescription(
          location: 1, binding: 0, format: VK_FORMAT_R32G32B32A32_SFLOAT, offset: 12),
        VkVertexInputAttributeDescription(
          location: 2, binding: 0, format: VK_FORMAT_R32G32B32_SFLOAT, offset: 28),
        VkVertexInputAttributeDescription(
          location: 3, binding: 0, format: VK_FORMAT_R32G32_SFLOAT, offset: 40),
        VkVertexInputAttributeDescription(
          location: 4, binding: 0, format: VK_FORMAT_R32G32B32A32_SFLOAT, offset: 48),
        VkVertexInputAttributeDescription(
          location: 5, binding: 0, format: VK_FORMAT_R16G16B16A16_UINT, offset: 64),
        VkVertexInputAttributeDescription(
          location: 6, binding: 0, format: VK_FORMAT_R32G32B32A32_SFLOAT, offset: 72),
        VkVertexInputAttributeDescription(
          location: 7, binding: 0, format: VK_FORMAT_R32G32_SFLOAT, offset: 88)
      ]
      vertexInputInfo = VkPipelineVertexInputStateCreateInfo(
        sType: VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        vertexBindingDescriptionCount: 1,
        pVertexBindingDescriptions: bindingDesc.addr,
        vertexAttributeDescriptionCount: (if key.post: 1 else: attributeDescs.len).uint32,
        pVertexAttributeDescriptions: attributeDescs[0].addr
      )
      inputAssembly = VkPipelineInputAssemblyStateCreateInfo(
        sType: VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        topology: key.topology,
        primitiveRestartEnable: VkBool32(VK_FALSE)
      )
      viewportState = VkPipelineViewportStateCreateInfo(
        sType: VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        viewportCount: 1,
        scissorCount: 1
      )
      rasterizer = VkPipelineRasterizationStateCreateInfo(
        sType: VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        depthClampEnable: VkBool32(VK_FALSE),
        rasterizerDiscardEnable: VkBool32(VK_FALSE),
        polygonMode: VK_POLYGON_MODE_FILL,
        lineWidth: 1.0,
        cullMode:
          if key.doubleSided or key.post:
            VkCullModeFlags(VK_CULL_MODE_NONE)
          else:
            VkCullModeFlags(VK_CULL_MODE_BACK_BIT),
        frontFace: (if key.mirrored: VK_FRONT_FACE_CLOCKWISE else: VK_FRONT_FACE_COUNTER_CLOCKWISE),
        depthBiasEnable: VkBool32(VK_FALSE)
      )
      multisampling = VkPipelineMultisampleStateCreateInfo(
        sType: VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        sampleShadingEnable: VkBool32(VK_FALSE),
        rasterizationSamples: (if key.background: VK_SAMPLE_COUNT_4_BIT elif key.ibl or key.post: VK_SAMPLE_COUNT_1_BIT else: renderer.sampleCount)
      )
      depthStencil = VkPipelineDepthStencilStateCreateInfo(
        sType: VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        depthTestEnable: VkBool32(if key.post: VK_FALSE else: VK_TRUE),
        depthWriteEnable: VkBool32(if key.blended: VK_FALSE else: VK_TRUE),
        depthCompareOp: VK_COMPARE_OP_LESS,
        depthBoundsTestEnable: VkBool32(VK_FALSE),
        stencilTestEnable: VkBool32(VK_FALSE),
        minDepthBounds: 0,
        maxDepthBounds: 1
      )
      colorBlendAttachment = VkPipelineColorBlendAttachmentState(
        colorWriteMask: VkColorComponentFlags(0x0000000F),
        blendEnable: VkBool32(if key.blended: VK_TRUE else: VK_FALSE),
        srcColorBlendFactor: if key.blended: VK_BLEND_FACTOR_SRC_ALPHA else: VK_BLEND_FACTOR_ONE,
        dstColorBlendFactor: if key.blended: VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA else: VK_BLEND_FACTOR_ZERO,
        colorBlendOp: VK_BLEND_OP_ADD,
        srcAlphaBlendFactor: VK_BLEND_FACTOR_ONE,
        dstAlphaBlendFactor: if key.blended: VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA else: VK_BLEND_FACTOR_ZERO,
        alphaBlendOp: VK_BLEND_OP_ADD
      )
      colorAttachments = [colorBlendAttachment, VkPipelineColorBlendAttachmentState(colorWriteMask: VkColorComponentFlags(0xF))]
      colorBlending = VkPipelineColorBlendStateCreateInfo(
        sType: VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        logicOpEnable: VkBool32(VK_FALSE),
        logicOp: VK_LOGIC_OP_COPY,
        attachmentCount: (if key.ibl and not key.background: 2 else: 1),
        pAttachments: colorAttachments[0].addr,
        blendConstants: [0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32]
      )
      pipelineInfo = VkGraphicsPipelineCreateInfo(
        sType: VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        pNext: renderingInfo.addr,
        stageCount: shaderStages.len.uint32,
        pStages: shaderStages[0].addr,
        pVertexInputState: vertexInputInfo.addr,
        pInputAssemblyState: inputAssembly.addr,
        pViewportState: viewportState.addr,
        pRasterizationState: rasterizer.addr,
        pMultisampleState: multisampling.addr,
        pDepthStencilState: depthStencil.addr,
        pColorBlendState: colorBlending.addr,
        pDynamicState: dynamicState.addr,
        layout: renderer.pipelineLayout
      )
    checkVk(vkCreateGraphicsPipelines(renderer.ctx.device, VkPipelineCache(0),
      1, pipelineInfo.addr, nil, result.addr),
      "Creating Vulkan graphics pipeline")
  finally:
    vkDestroyShaderModule(renderer.ctx.device, vertModule, nil)
    vkDestroyShaderModule(renderer.ctx.device, fragModule, nil)

proc getPipeline(renderer: Renderer, key: PipelineKey): VkPipeline =
  if key notin renderer.pipelineStates:
    renderer.pipelineStates[key] = renderer.createPipeline(key)
  renderer.pipelineStates[key]

proc newRenderer*(window: Window): Renderer =
  ## Creates a Vulkan renderer bound to a Windy window.
  let safeSize = ivec2(max(1'i32, window.size.x), max(1'i32, window.size.y))
  result = Renderer(window: window)
  let hwnd = window.getHWND()
  if hwnd == 0:
    raise newException(GltfError, "Failed to acquire HWND for Vulkan renderer.")
  result.ctx.initDevice(hwnd, safeSize.x.int, safeSize.y.int, window.vsync)
  result.sampleCount = chooseMsaaSampleCount(result.ctx)
  result.createDescriptorSetLayouts()
  result.createPipelineLayout()
  var properties: VkPhysicalDeviceProperties
  vkGetPhysicalDeviceProperties(result.ctx.physicalDevice, addr properties)
  result.uniformAlignment = max(16, properties.limits.minUniformBufferOffsetAlignment.int)
  result.createFrameDescriptorPool()
  result.createSwapChainResources()

proc releaseTexture(renderer: Renderer, texture: VkTexture) =
  if texture == nil:
    return
  if texture.sampler.int64 != 0:
    vkDestroySampler(renderer.ctx.device, texture.sampler, nil)
    texture.sampler = VkSampler(0)
  if texture.view.int64 != 0:
    vkDestroyImageView(renderer.ctx.device, texture.view, nil)
    texture.view = VkImageView(0)
  if texture.image.int64 != 0:
    vkDestroyImage(renderer.ctx.device, texture.image, nil)
    texture.image = VkImage(0)
  if texture.memory.int64 != 0:
    vkFreeMemory(renderer.ctx.device, texture.memory, nil)
    texture.memory = VkDeviceMemory(0)

proc releaseMaterial(renderer: Renderer, material: VkMaterial) =
  if material == nil:
    return
  if material.binding != nil:
    let shared = material.binding
    material.binding = nil
    dec shared.references
    if shared.references == 0:
      renderer.releaseMaterial(shared)
    return
  for texture in material.textures:
    renderer.releaseTexture(texture)
  material.textures.setLen(0)
  if material.descriptorPool.int64 != 0:
    vkDestroyDescriptorPool(renderer.ctx.device, material.descriptorPool, nil)
    material.descriptorPool = VkDescriptorPool(0)

proc releasePrimitive(renderer: Renderer, primitive: VkPrimitive) =
  if primitive == nil: return
  for storage in [primitive.vertexBlock, primitive.indexBlock]:
    if storage != nil: dec storage.users
  primitive.vertexBlock = nil
  primitive.indexBlock = nil
  primitive.vertexBuffer = VkBuffer(0)
  primitive.indexBuffer = VkBuffer(0)
  primitive.vertexMemory = VkDeviceMemory(0)
  primitive.indexMemory = VkDeviceMemory(0)
  primitive.vertexPtr = nil
  primitive.indexPtr = nil
  primitive.vertexCapacity = 0
  primitive.indexCapacity = 0

proc resetFrameResources(renderer: Renderer) =
  for storage in renderer.uniformBlocks:
    storage.used = 0
    storage.users = 0
  for pool in renderer.frameDescriptorPools:
    checkVk(vkResetDescriptorPool(renderer.ctx.device, pool, VkDescriptorPoolResetFlags(0)),
      "Resetting Vulkan frame descriptors")
  renderer.frameUniformSets = 0

proc bindTextures(renderer: Renderer, result: VkMaterial, textures: openArray[VkTexture]) =
  var poolSize = VkDescriptorPoolSize(
    `type`: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
    descriptorCount: TextureDescriptorCount.uint32
  )
  var poolInfo = VkDescriptorPoolCreateInfo(
    sType: VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
    maxSets: 1,
    poolSizeCount: 1,
    pPoolSizes: poolSize.addr
  )
  checkVk(vkCreateDescriptorPool(renderer.ctx.device, poolInfo.addr, nil,
    result.descriptorPool.addr),
    "Creating Vulkan material descriptor pool")
  var layout = renderer.materialSetLayout
  var allocInfo = VkDescriptorSetAllocateInfo(
    sType: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool: result.descriptorPool,
    descriptorSetCount: 1,
    pSetLayouts: layout.addr
  )
  checkVk(vkAllocateDescriptorSets(renderer.ctx.device, allocInfo.addr,
    result.descriptorSet.addr),
    "Allocating Vulkan material descriptor set")

  var imageInfos: array[TextureDescriptorCount, VkDescriptorImageInfo]
  var writes: array[TextureDescriptorCount, VkWriteDescriptorSet]
  for i in 0 ..< TextureDescriptorCount:
    let texture = textures[min(i, textures.high)]
    imageInfos[i] = VkDescriptorImageInfo(
      sampler: texture.sampler,
      imageView: texture.view,
      imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    )
    writes[i] = VkWriteDescriptorSet(
      sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
      dstSet: result.descriptorSet,
      dstBinding: i.uint32,
      dstArrayElement: 0,
      descriptorCount: 1,
      descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
      pImageInfo: imageInfos[i].addr
    )
  vkUpdateDescriptorSets(renderer.ctx.device, writes.len.uint32,
    writes[0].addr, 0, nil)

include ibl

proc resize(renderer: Renderer, size: IVec2) =
  let safeSize = ivec2(max(1'i32, size.x), max(1'i32, size.y))
  if renderer.readbackSize == safeSize:
    return
  discard vkDeviceWaitIdle(renderer.ctx.device)
  renderer.destroySwapChainResources()
  recreateSwapChain(renderer.ctx, safeSize.x.int, safeSize.y.int)
  renderer.createSwapChainResources()
  if renderer.frame.useIbl: renderer.createHdr(renderer.readbackSize)

proc vertexAt(primitive: Primitive, index: int): VkVertex =
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
  result.color = [colorValue.r, colorValue.g, colorValue.b, colorValue.a]
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
  result.joints =
    if index < primitive.jointIds.len:
      primitive.jointIds[index]
    else:
      [0'u16, 0'u16, 0'u16, 0'u16]
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
  topology: var VkPrimitiveTopology
): seq[uint32] =
  let src = primitive.primitiveSourceIndices()
  case primitive.mode.int
  of 0: # GL_POINTS
    topology = VK_PRIMITIVE_TOPOLOGY_POINT_LIST
    result = src
  of 1: # GL_LINES
    topology = VK_PRIMITIVE_TOPOLOGY_LINE_LIST
    result = src
  of 3: # GL_LINE_STRIP
    topology = VK_PRIMITIVE_TOPOLOGY_LINE_STRIP
    result = src
  of 2: # GL_LINE_LOOP
    topology = VK_PRIMITIVE_TOPOLOGY_LINE_LIST
    if src.len >= 2:
      for i in 0 ..< src.len:
        result.add(src[i])
        result.add(src[(i + 1) mod src.len])
  of 5: # GL_TRIANGLE_STRIP
    topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP
    result = src
  of 6: # GL_TRIANGLE_FAN
    topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
    if src.len >= 3:
      for i in 1 ..< src.len - 1:
        result.add(src[0])
        result.add(src[i])
        result.add(src[i + 1])
  else:
    topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
    result = src

proc ensurePrimitive(renderer: Renderer, primitive: Primitive): VkPrimitive =
  if primitive.normals.len == 0 and primitive.mode.int == 4:
    primitive.computeSmoothNormals()

  if primitive.data == nil:
    primitive.data = VkPrimitive()
  result = primitive.data
  if result.vertexCapacity > 0 and result.geometryVersion == primitive.geometryVersion: return


  if primitive.points.len > result.vertexCapacity:
    if result.vertexBlock != nil: dec result.vertexBlock.users
    result.vertexCapacity = max(primitive.points.len, 1)
    let allocation = renderer.allocateBuffer(renderer.geometryBlocks, result.vertexCapacity * sizeof(VkVertex), 16)
    result.vertexBlock = allocation.storage
    result.vertexBuffer = allocation.storage.buffer
    result.vertexOffset = VkDeviceSize(allocation.offset)
    result.vertexPtr = cast[pointer](cast[uint](allocation.storage.mapped) + allocation.offset.uint)

  var vertices = newSeq[VkVertex](primitive.points.len)
  for i in 0 ..< primitive.points.len:
    vertices[i] = primitive.vertexAt(i)
  if vertices.len > 0:
    copyMem(result.vertexPtr, unsafeAddr vertices[0], vertices.len * sizeof(VkVertex))

  var topology: VkPrimitiveTopology
  let indices = primitive.buildIndexData(topology)
  result.topology = topology
  result.indexCount = indices.len
  if indices.len > result.indexCapacity:
    if result.indexBlock != nil: dec result.indexBlock.users
    result.indexCapacity = max(indices.len, 1)
    let allocation = renderer.allocateBuffer(renderer.geometryBlocks, result.indexCapacity * sizeof(uint32), 16)
    result.indexBlock = allocation.storage
    result.indexBuffer = allocation.storage.buffer
    result.indexOffset = VkDeviceSize(allocation.offset)
    result.indexPtr = cast[pointer](cast[uint](allocation.storage.mapped) + allocation.offset.uint)

  if indices.len > 0:
    copyMem(result.indexPtr, unsafeAddr indices[0], indices.len * sizeof(uint32))
  result.geometryVersion = primitive.geometryVersion

proc ensureMaterial(renderer: Renderer, material: Material): VkMaterial =
  if material == nil:
    return nil
  if material.data != nil and material.data.materialVersion == material.materialVersion and
      material.data.ibl == renderer.frame.useIbl and material.data.environmentVersion == renderer.environmentVersion:
    return material.data
  if material.data != nil:
    renderer.releaseMaterial(material.data)

  let inputs = material.textureInputs()
  let bindingKey = materialBindingKey(inputs, renderer.frame.useIbl, renderer.environmentVersion, material.materialVersion)
  var cached = renderer.materialBindings.getOrDefault(bindingKey)
  if cached != nil and cached.descriptorPool.int64 != 0:
    inc cached.references
    result = VkMaterial(materialVersion: material.materialVersion, ibl: renderer.frame.useIbl,
      environmentVersion: renderer.environmentVersion, binding: cached)
    material.data = result
    return
  result = VkMaterial(ibl: renderer.frame.useIbl, environmentVersion: renderer.environmentVersion)
  if renderer.defaultWhite == nil:
    renderer.defaultWhite = renderer.uploadSolidImage(rgbx(255, 255, 255, 255))
    renderer.defaultNormal = renderer.uploadSolidImage(rgbx(128, 128, 255, 255))
  let layout = if renderer.frame.useIbl: IblLayout else: PixelLayout
  var bound: seq[VkTexture]
  for i, name in layout.textures:
    var texture: VkTexture
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
        if texture != renderer.defaultWhite and texture != renderer.defaultNormal:
          vkDestroySampler(renderer.ctx.device, texture.sampler, nil)
          texture.sampler = renderer.materialSampler(input.sampler, texture.mipLevels)
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
      else:
        if name == "environmentMap": texture = renderer.uploadStudioCube()
        elif name == "shadowMap":
          texture = renderer.uploadShadowPlaceholder()
        else: raise newException(ValueError, "Unbound shader texture: " & name)
        result.textures.add(texture)
    bound.add(texture)
  renderer.bindTextures(result, bound)
  result.references = 1
  renderer.materialBindings[bindingKey] = result
  result = VkMaterial(materialVersion: material.materialVersion, ibl: renderer.frame.useIbl,
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

proc createFrameBufferWithData(
  renderer: Renderer,
  data: openArray[uint32]
): FrameBuffer =
  let allocation = renderer.allocateBuffer(renderer.uniformBlocks, max(4, data.len * 4), renderer.uniformAlignment)
  let mapped = cast[pointer](cast[uint](allocation.storage.mapped) + allocation.offset.uint)
  if data.len > 0: copyMem(mapped, unsafeAddr data[0], data.len * 4)
  FrameBuffer(buffer: allocation.storage.buffer, offset: VkDeviceSize(allocation.offset))

proc createUniformDescriptorSet(
  renderer: Renderer,
  vertexConstants,
  pixelConstants: openArray[uint32]
): VkDescriptorSet =
  let
    vertexBuffer = renderer.createFrameBufferWithData(vertexConstants)
    pixelBuffer = renderer.createFrameBufferWithData(pixelConstants)
  let poolIndex = renderer.frameUniformSets div MaxFrameUniformSets
  if poolIndex >= renderer.frameDescriptorPools.len: renderer.createFrameDescriptorPool()
  inc renderer.frameUniformSets
  var layout = renderer.uniformSetLayout
  var allocInfo = VkDescriptorSetAllocateInfo(
    sType: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool: renderer.frameDescriptorPools[poolIndex],
    descriptorSetCount: 1,
    pSetLayouts: layout.addr
  )
  checkVk(vkAllocateDescriptorSets(renderer.ctx.device, allocInfo.addr,
    result.addr),
    "Allocating Vulkan uniform descriptor set")

  var bufferInfos = [
    VkDescriptorBufferInfo(
      buffer: vertexBuffer.buffer,
      offset: vertexBuffer.offset,
      range: VkDeviceSize(vertexConstants.len * sizeof(uint32))
    ),
    VkDescriptorBufferInfo(
      buffer: pixelBuffer.buffer,
      offset: pixelBuffer.offset,
      range: VkDeviceSize(pixelConstants.len * sizeof(uint32))
    )
  ]
  var writes = [
    VkWriteDescriptorSet(
      sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
      dstSet: result,
      dstBinding: VertexUniformBinding.uint32,
      dstArrayElement: 0,
      descriptorCount: 1,
      descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
      pBufferInfo: bufferInfos[0].addr
    ),
    VkWriteDescriptorSet(
      sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
      dstSet: result,
      dstBinding: PixelUniformBinding.uint32,
      dstArrayElement: 0,
      descriptorCount: 1,
      descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
      pBufferInfo: bufferInfos[1].addr
    )
  ]
  vkUpdateDescriptorSets(renderer.ctx.device, writes.len.uint32,
    writes[0].addr, 0, nil)

proc cmdImageBarrier(
  commandBuffer: VkCommandBuffer,
  image: VkImage,
  aspect: VkImageAspectFlags,
  oldLayout,
  newLayout: VkImageLayout,
  srcStage,
  dstStage: VkPipelineStageFlags2,
  srcAccess,
  dstAccess: VkAccessFlags2,
  mipLevel = 0
) =
  var barrier = VkImageMemoryBarrier2(
    sType: VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
    srcStageMask: srcStage,
    srcAccessMask: srcAccess,
    dstStageMask: dstStage,
    dstAccessMask: dstAccess,
    oldLayout: oldLayout,
    newLayout: newLayout,
    srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
    image: image,
    subresourceRange: VkImageSubresourceRange(
      aspectMask: aspect,
      baseMipLevel: mipLevel.uint32,
      levelCount: 1,
      baseArrayLayer: 0,
      layerCount: 1
    )
  )
  var dependencyInfo = VkDependencyInfo(
    sType: VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
    imageMemoryBarrierCount: 1,
    pImageMemoryBarriers: barrier.addr
  )
  vkCmdPipelineBarrier2(commandBuffer, dependencyInfo.addr)

proc drawPrimitive(renderer: Renderer, commandBuffer: VkCommandBuffer, entry: SceneDraw, root: Node) =
  let primitive = entry.primitive
  let owner = entry.owner
  let transform = entry.transform
  let view = renderer.frame.view
  let proj = renderer.frame.proj
  if primitive == nil or not primitive.hasGeometry():
    return

  let isBlend = entry.blended

  let vkPrimitive = renderer.ensurePrimitive(primitive)
  if vkPrimitive.indexCount == 0:
    return
  let vkMaterial = renderer.ensureMaterial(primitive.material).binding
  let key = PipelineKey(
    topology: vkPrimitive.topology.uint32,
    doubleSided: primitive.material != nil and primitive.material.doubleSided,
    blended: isBlend, ibl: renderer.frame.useIbl, background: renderer.frame.transmissionBackground, mirrored: determinant(transform) < 0
  )
  let pipeline = renderer.getPipeline(key)
  let
    vertexConstants = vertexUniforms(VertexLayout, owner, root, transform, view, proj)
    pixelConstants = pixelUniforms(if renderer.frame.useIbl: IblLayout else: PixelLayout, primitive, renderer.frame, transform)
    uniformSet = renderer.createUniformDescriptorSet(
      vertexConstants,
      pixelConstants
    )
  var descriptorSets = [vkMaterial.descriptorSet, uniformSet]
  var vertexBuffers = [vkPrimitive.vertexBuffer]
  var offsets = [vkPrimitive.vertexOffset]

  vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline)
  vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
    renderer.pipelineLayout, 0, descriptorSets.len.uint32,
    descriptorSets[0].addr, 0, nil)
  vkCmdBindVertexBuffers(commandBuffer, 0, 1,
    vertexBuffers[0].addr, offsets[0].addr)
  vkCmdBindIndexBuffer(commandBuffer, vkPrimitive.indexBuffer,
    vkPrimitive.indexOffset, VK_INDEX_TYPE_UINT32)
  vkCmdDrawIndexed(commandBuffer, vkPrimitive.indexCount.uint32, 1, 0, 0, 0)

proc recordFrame(
  renderer: Renderer,
  commandBuffer: VkCommandBuffer,
  imageIndex: uint32,
  clearColor: Color,
  node: Node,
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
  fogColor: Color,
  fogStart,
  fogEnd,
  fogDensity,
  fogStrength,
  environmentMapStrength: float32
) =
  discard vkResetCommandBuffer(commandBuffer, VkCommandBufferResetFlags(0))
  var beginInfo = VkCommandBufferBeginInfo(
    sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
  )
  checkVk(vkBeginCommandBuffer(commandBuffer, beginInfo.addr),
    "Beginning Vulkan draw command buffer")

  if node != nil: node.updateTransforms(transform, true)
  renderer.frame.updateLights(node)
  let draws = renderer.frame.sceneDraws(node)
  if renderer.frame.useIbl and draws.transmitted.len > 0:
    renderer.beginTransmission(commandBuffer, clearColor)
    renderer.frame.transmissionBackground = true
    for entry in draws.opaque: renderer.drawPrimitive(commandBuffer, entry, node)
    for entry in draws.blended: renderer.drawPrimitive(commandBuffer, entry, node)
    vkCmdEndRendering(commandBuffer)
    renderer.resolveTransmission(commandBuffer)
    renderer.frame.transmissionBackground = false

  commandBuffer.cmdImageBarrier(
    renderer.ctx.swapChainImages[imageIndex],
    VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
    renderer.imageLayouts[imageIndex],
    VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_NONE),
    VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT),
    VkAccessFlags2(VK_ACCESS_2_NONE),
    VkAccessFlags2(VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT)
  )
  if renderer.msaaEnabled:
    commandBuffer.cmdImageBarrier(
      renderer.colorImages[imageIndex],
      VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
      VK_IMAGE_LAYOUT_UNDEFINED,
      VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
      VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_NONE),
      VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT),
      VkAccessFlags2(VK_ACCESS_2_NONE),
      VkAccessFlags2(VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT)
    )
  commandBuffer.cmdImageBarrier(
    renderer.depthImages[imageIndex],
    VkImageAspectFlags(VK_IMAGE_ASPECT_DEPTH_BIT),
    VK_IMAGE_LAYOUT_UNDEFINED,
    VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_NONE),
    VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT),
    VkAccessFlags2(VK_ACCESS_2_NONE),
    VkAccessFlags2(VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT)
  )

  var
    colorClear = VkClearValue(color: VkClearColorValue(
      float32: [clearColor.r, clearColor.g, clearColor.b, clearColor.a]))
    depthClear = VkClearValue(
      depthStencil: VkClearDepthStencilValue(depth: 1.0'f32, stencil: 0))
    colorAttachment = VkRenderingAttachmentInfo(
      sType: VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
      imageView:
        if renderer.msaaEnabled:
          renderer.colorViews[imageIndex]
        else:
          renderer.imageViews[imageIndex],
      imageLayout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
      resolveMode:
        if renderer.msaaEnabled:
          VK_RESOLVE_MODE_AVERAGE_BIT
        else:
          VK_RESOLVE_MODE_NONE,
      resolveImageView:
        if renderer.msaaEnabled:
          renderer.imageViews[imageIndex]
        else:
          VkImageView(0),
      resolveImageLayout:
        if renderer.msaaEnabled:
          VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
        else:
          VK_IMAGE_LAYOUT_UNDEFINED,
      loadOp: VK_ATTACHMENT_LOAD_OP_CLEAR,
      storeOp:
        if renderer.msaaEnabled:
          VK_ATTACHMENT_STORE_OP_DONT_CARE
        else:
          VK_ATTACHMENT_STORE_OP_STORE,
      clearValue: colorClear
    )
    depthAttachment = VkRenderingAttachmentInfo(
      sType: VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
      imageView: renderer.depthViews[imageIndex],
      imageLayout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
      loadOp: VK_ATTACHMENT_LOAD_OP_CLEAR,
      storeOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
      clearValue: depthClear
    )
    renderingInfo = VkRenderingInfo(
      sType: VK_STRUCTURE_TYPE_RENDERING_INFO,
      renderArea: VkRect2D(
        offset: VkOffset2D(x: 0, y: 0),
        extent: renderer.ctx.swapChainExtent),
      layerCount: 1,
      colorAttachmentCount: 1,
      pColorAttachments: colorAttachment.addr,
      pDepthAttachment: depthAttachment.addr
    )
    viewport = VkViewport(
      x: 0,
      y: 0,
      width: renderer.ctx.swapChainExtent.width.float32,
      height: renderer.ctx.swapChainExtent.height.float32,
      minDepth: 0,
      maxDepth: 1
    )
    scissor = VkRect2D(
      offset: VkOffset2D(x: 0, y: 0),
      extent: renderer.ctx.swapChainExtent
    )

  var hdrAttachments: array[2, VkRenderingAttachmentInfo]
  if renderer.frame.useIbl:
    hdrAttachments = renderer.prepareHdr(commandBuffer, clearColor)
    renderingInfo.colorAttachmentCount = 2
    renderingInfo.pColorAttachments = addr hdrAttachments[0]
  vkCmdBeginRendering(commandBuffer, renderingInfo.addr)
  vkCmdSetViewport(commandBuffer, 0, 1, viewport.addr)
  vkCmdSetScissor(commandBuffer, 0, 1, scissor.addr)

  for entry in draws.opaque: renderer.drawPrimitive(commandBuffer, entry, node)
  for entry in draws.transmitted: renderer.drawPrimitive(commandBuffer, entry, node)
  for entry in draws.blended: renderer.drawPrimitive(commandBuffer, entry, node)

  vkCmdEndRendering(commandBuffer)
  if renderer.frame.useIbl:
    renderer.presentHdr(commandBuffer, renderer.imageViews[imageIndex])

  commandBuffer.cmdImageBarrier(
    renderer.ctx.swapChainImages[imageIndex],
    VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
    VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
    VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT),
    VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_TRANSFER_BIT),
    VkAccessFlags2(VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT),
    VkAccessFlags2(VK_ACCESS_2_TRANSFER_READ_BIT)
  )
  var copyRegion = VkBufferImageCopy(
    bufferOffset: VkDeviceSize(0),
    imageSubresource: VkImageSubresourceLayers(
      aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
      mipLevel: 0,
      baseArrayLayer: 0,
      layerCount: 1
    ),
    imageExtent: VkExtent3D(
      width: renderer.ctx.swapChainExtent.width,
      height: renderer.ctx.swapChainExtent.height,
      depth: 1
    )
  )
  vkCmdCopyImageToBuffer(commandBuffer,
    renderer.ctx.swapChainImages[imageIndex],
    VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
    renderer.readbackBuffer,
    1,
    copyRegion.addr)
  commandBuffer.cmdImageBarrier(
    renderer.ctx.swapChainImages[imageIndex],
    VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT),
    VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
    VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_TRANSFER_BIT),
    VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_NONE),
    VkAccessFlags2(VK_ACCESS_2_TRANSFER_READ_BIT),
    VkAccessFlags2(VK_ACCESS_2_NONE)
  )
  renderer.imageLayouts[imageIndex] = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
  checkVk(vkEndCommandBuffer(commandBuffer), "Ending Vulkan draw command buffer")

proc drawPbrFrame(
  renderer: Renderer,
  node: Node,
  ctx: PbrContext
) =
  ## Draws a full glTF PBR frame through Vulkan.
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
  discard vsync
  renderer.resize(size)
  renderer.resetFrameResources()

  if node != nil:
    renderer.prepareNodeResources(node)

  let frame = renderer.ctx.currentFrame
  let fence = renderer.ctx.inFlightFences[frame]
  discard vkWaitForFences(renderer.ctx.device, 1, unsafeAddr fence,
    VkBool32(VK_TRUE), uint64.high)
  discard vkResetFences(renderer.ctx.device, 1, unsafeAddr fence)

  var imageIndex: uint32
  let acquireResult = vkAcquireNextImageKHR(
    renderer.ctx.device,
    renderer.ctx.swapChain,
    uint64.high,
    renderer.ctx.imageAvailableSemaphores[frame],
    VkFence(0),
    imageIndex.addr
  )
  if requiresSwapChainRecreate(acquireResult):
    renderer.resize(size)
    return
  checkVk(acquireResult, "Acquiring Vulkan swapchain image")

  let commandBuffer = renderer.commandBuffers[imageIndex]
  renderer.recordFrame(
    commandBuffer,
    imageIndex,
    clearColor,
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
    fogColor,
    fogStart,
    fogEnd,
    fogDensity,
    fogStrength,
    environmentMapStrength
  )

  var
    waitInfo = VkSemaphoreSubmitInfo(
      sType: VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
      semaphore: renderer.ctx.imageAvailableSemaphores[frame],
      stageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT),
      value: 0,
      deviceIndex: 0
    )
    commandBufferInfo = VkCommandBufferSubmitInfo(
      sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
      commandBuffer: commandBuffer,
      deviceMask: 0
    )
    signalInfo = VkSemaphoreSubmitInfo(
      sType: VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
      semaphore: renderer.ctx.renderFinishedSemaphores[frame],
      stageMask: VkPipelineStageFlags2(VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT),
      value: 0,
      deviceIndex: 0
    )
    submitInfo = VkSubmitInfo2(
      sType: VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
      waitSemaphoreInfoCount: 1,
      pWaitSemaphoreInfos: waitInfo.addr,
      commandBufferInfoCount: 1,
      pCommandBufferInfos: commandBufferInfo.addr,
      signalSemaphoreInfoCount: 1,
      pSignalSemaphoreInfos: signalInfo.addr
    )
  checkVk(vkQueueSubmit2(renderer.ctx.graphicsQueue, 1,
    submitInfo.addr, fence),
    "Submitting Vulkan draw command buffer")
  discard vkWaitForFences(renderer.ctx.device, 1, unsafeAddr fence,
    VkBool32(VK_TRUE), uint64.high)

  var
    swapChains = [renderer.ctx.swapChain]
    presentInfo = VkPresentInfoKHR(
      sType: VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
      waitSemaphoreCount: 1,
      pWaitSemaphores: signalInfo.semaphore.addr,
      swapchainCount: 1,
      pSwapchains: swapChains[0].addr,
      pImageIndices: imageIndex.addr
    )
  let presentResult = vkQueuePresentKHR(renderer.ctx.presentQueue,
    presentInfo.addr)
  if requiresSwapChainRecreate(presentResult):
    renderer.resize(size)
  else:
    checkVk(presentResult, "Presenting Vulkan frame")
  renderer.ctx.currentFrame = (renderer.ctx.currentFrame + 1) mod FRAME_COUNT

proc captureScreenshot*(renderer: Renderer): Image =
  ## Reads the most recently rendered Vulkan frame.
  let
    width = renderer.readbackSize.x.int
    height = renderer.readbackSize.y.int
    swapBgra =
      renderer.ctx.swapChainImageFormat == VK_FORMAT_B8G8R8A8_UNORM or
      renderer.ctx.swapChainImageFormat == VK_FORMAT_B8G8R8A8_SRGB
  result = newImage(width, height)
  var mapped: pointer
  checkVk(vkMapMemory(renderer.ctx.device, renderer.readbackMemory,
    VkDeviceSize(0), VkDeviceSize(width * height * 4),
    VkMemoryMapFlags(0), mapped.addr),
    "Mapping Vulkan readback buffer")
  let pixels = cast[ptr UncheckedArray[uint8]](mapped)
  for y in 0 ..< height:
    for x in 0 ..< width:
      let src = (y * width + x) * 4
      let alpha = pixels[src + 3]
      let
        red = if swapBgra: pixels[src + 2] else: pixels[src + 0]
        green = pixels[src + 1]
        blue = if swapBgra: pixels[src + 0] else: pixels[src + 2]
      result.data[result.dataIndex(x, y)] = rgbx(
        min(red, alpha),
        min(green, alpha),
        min(blue, alpha),
        alpha
      )
  vkUnmapMemory(renderer.ctx.device, renderer.readbackMemory)

proc clearNode*(renderer: Renderer, node: Node) =
  ## Releases Vulkan resources associated with a loaded node tree.
  if node == nil:
    return
  discard vkDeviceWaitIdle(renderer.ctx.device)
  if node.mesh != nil:
    for primitive in node.mesh.primitives:
      if primitive.data != nil:
        renderer.releasePrimitive(primitive.data)
        primitive.data = nil
      if primitive.material != nil:
        if primitive.material.data != nil:
          renderer.releaseMaterial(primitive.material.data)
          primitive.material.data = nil
  for child in node.nodes:
    renderer.clearNode(child)

proc shutdown*(renderer: Renderer) =
  ## Releases all Vulkan resources owned by the renderer.
  if renderer == nil:
    return
  discard vkDeviceWaitIdle(renderer.ctx.device)
  renderer.destroyBlocks(renderer.uniformBlocks)
  renderer.destroyBlocks(renderer.geometryBlocks)
  renderer.destroySwapChainResources()
  if renderer.readbackBuffer.int64 != 0:
    vkDestroyBuffer(renderer.ctx.device, renderer.readbackBuffer, nil)
    renderer.readbackBuffer = VkBuffer(0)
  if renderer.readbackMemory.int64 != 0:
    vkFreeMemory(renderer.ctx.device, renderer.readbackMemory, nil)
    renderer.readbackMemory = VkDeviceMemory(0)
  for pool in renderer.frameDescriptorPools:
    vkDestroyDescriptorPool(renderer.ctx.device, pool, nil)
  renderer.frameDescriptorPools.setLen(0)
  if renderer.pipelineLayout.int64 != 0:
    vkDestroyPipelineLayout(renderer.ctx.device, renderer.pipelineLayout, nil)
    renderer.pipelineLayout = VkPipelineLayout(0)
  if renderer.uniformSetLayout.int64 != 0:
    vkDestroyDescriptorSetLayout(renderer.ctx.device, renderer.uniformSetLayout, nil)
    renderer.uniformSetLayout = VkDescriptorSetLayout(0)
  if renderer.materialSetLayout.int64 != 0:
    vkDestroyDescriptorSetLayout(renderer.ctx.device, renderer.materialSetLayout, nil)
    renderer.materialSetLayout = VkDescriptorSetLayout(0)
  renderer.destroyIbl()
  cleanup(renderer.ctx)

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
