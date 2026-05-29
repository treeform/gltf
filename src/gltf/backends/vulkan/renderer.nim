## Vulkan backend shader sources and renderer.

when not defined(windows):
  {.error: "The glTF Vulkan backend requires Windows.".}

import
  std/[algorithm, math, tables],
  chroma, pixie, vmath, windy,
  ../../common, ../../models,
  ./common,
  ../shaders as shaderSources

import pkg/vk14 except Window

when not defined(shadyBinaryShaders):
  import std/os
  import shady

const
  VertexEntryPoint* = "main"
  FragmentEntryPoint* = "main"

  PbrVertexShader* = shaderSources.PbrVertVulkan
  PbrFragmentShader* = shaderSources.PbrFragVulkan
  SkyboxVertexShader* = shaderSources.SkyboxVertVulkan
  SkyboxFragmentShader* = shaderSources.SkyboxFragVulkan
  ShadowDepthVertexShader* = shaderSources.ShadowDepthVertVulkan
  ShadowDepthFragmentShader* = shaderSources.ShadowDepthFragVulkan

  TextureDescriptorCount = 7
  VertexUniformBinding = 0
  PixelUniformBinding = 1
  MaxFrameUniformSets = 8192
  StudioEnvSize = 8
  DepthFormat = VK_FORMAT_D32_SFLOAT
  PreferredMsaaSamples = 8'u32

when not defined(shadyBinaryShaders):
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

  FrameBuffer = object
    buffer: VkBuffer
    memory: VkDeviceMemory

  BlendEntry = object
    node: Node
    primitive: Primitive
    transform: Mat4

  Std140Writer = object
    data: seq[uint32]
    offset: int

  Renderer* = ref object
    window: Window
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
    frameDescriptorPool: VkDescriptorPool
    frameBuffers: seq[FrameBuffer]
    readbackBuffer: VkBuffer
    readbackMemory: VkDeviceMemory
    readbackSize: IVec2

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
  isCube = false
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
    totalBytes += VkDeviceSize(subresources[i].width * subresources[i].height * 4)

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
    copyMem(dst, unsafeAddr src.pixels[0], src.width * src.height * 4)
  vkUnmapMemory(renderer.ctx.device, stagingMemory)

  var image: VkImage
  var memory: VkDeviceMemory
  createImage(renderer.ctx, width, height, mipLevels, layers,
    VK_FORMAT_R8G8B8A8_UNORM,
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
    format: VK_FORMAT_R8G8B8A8_UNORM,
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
    format: VK_FORMAT_R8G8B8A8_UNORM,
    mipLevels: mipLevels,
    layers: layers,
    isCube: isCube
  )

proc uploadImage(renderer: Renderer, image: Image): VkTexture =
  let mips = image.buildImageMips()
  renderer.uploadRgbaSubresources(image.width, image.height, mips.len, 1, mips)

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
  var pipelineLayoutInfo = VkPipelineLayoutCreateInfo(
    sType: VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
    setLayoutCount: layouts.len.uint32,
    pSetLayouts: layouts[0].addr
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
  checkVk(vkCreateDescriptorPool(renderer.ctx.device, poolInfo.addr, nil,
    renderer.frameDescriptorPool.addr),
    "Creating Vulkan frame descriptor pool")

proc createPipeline(
  renderer: Renderer,
  key: PipelineKey
): VkPipeline =
  when defined(shadyBinaryShaders):
    const
      vertShaderCode = staticRead("../shaders/gltf_pbr.vert.spv")
      fragShaderCode = staticRead("../shaders/gltf_pbr.frag.spv")
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
  let
    vertModule = createShaderModule(renderer.ctx.device, vertShaderCode)
    fragModule = createShaderModule(renderer.ctx.device, fragShaderCode)
  try:
    var
      colorFormat = renderer.ctx.swapChainImageFormat
      renderingInfo = VkPipelineRenderingCreateInfo(
        sType: VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
        colorAttachmentCount: 1,
        pColorAttachmentFormats: colorFormat.addr,
        depthAttachmentFormat: DepthFormat
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
        stride: sizeof(VkVertex).uint32,
        inputRate: VK_VERTEX_INPUT_RATE_VERTEX
      )
      attributeDescs = [
        VkVertexInputAttributeDescription(
          location: 0, binding: 0, format: VK_FORMAT_R32G32B32_SFLOAT, offset: 0),
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
        vertexAttributeDescriptionCount: attributeDescs.len.uint32,
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
          if key.doubleSided:
            VkCullModeFlags(VK_CULL_MODE_NONE)
          else:
            VkCullModeFlags(VK_CULL_MODE_BACK_BIT),
        frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE,
        depthBiasEnable: VkBool32(VK_FALSE)
      )
      multisampling = VkPipelineMultisampleStateCreateInfo(
        sType: VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        sampleShadingEnable: VkBool32(VK_FALSE),
        rasterizationSamples: renderer.sampleCount
      )
      depthStencil = VkPipelineDepthStencilStateCreateInfo(
        sType: VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        depthTestEnable: VkBool32(VK_TRUE),
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
      colorBlending = VkPipelineColorBlendStateCreateInfo(
        sType: VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        logicOpEnable: VkBool32(VK_FALSE),
        logicOp: VK_LOGIC_OP_COPY,
        attachmentCount: 1,
        pAttachments: colorBlendAttachment.addr,
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
  for texture in material.textures:
    renderer.releaseTexture(texture)
  material.textures.setLen(0)
  if material.descriptorPool.int64 != 0:
    vkDestroyDescriptorPool(renderer.ctx.device, material.descriptorPool, nil)
    material.descriptorPool = VkDescriptorPool(0)

proc releasePrimitive(renderer: Renderer, primitive: VkPrimitive) =
  if primitive == nil:
    return
  if primitive.vertexPtr != nil:
    vkUnmapMemory(renderer.ctx.device, primitive.vertexMemory)
    primitive.vertexPtr = nil
  if primitive.vertexBuffer.int64 != 0:
    vkDestroyBuffer(renderer.ctx.device, primitive.vertexBuffer, nil)
    primitive.vertexBuffer = VkBuffer(0)
  if primitive.vertexMemory.int64 != 0:
    vkFreeMemory(renderer.ctx.device, primitive.vertexMemory, nil)
    primitive.vertexMemory = VkDeviceMemory(0)
  if primitive.indexPtr != nil:
    vkUnmapMemory(renderer.ctx.device, primitive.indexMemory)
    primitive.indexPtr = nil
  if primitive.indexBuffer.int64 != 0:
    vkDestroyBuffer(renderer.ctx.device, primitive.indexBuffer, nil)
    primitive.indexBuffer = VkBuffer(0)
  if primitive.indexMemory.int64 != 0:
    vkFreeMemory(renderer.ctx.device, primitive.indexMemory, nil)
    primitive.indexMemory = VkDeviceMemory(0)

proc releaseFrameBuffers(renderer: Renderer) =
  for frameBuffer in renderer.frameBuffers:
    if frameBuffer.buffer.int64 != 0:
      vkDestroyBuffer(renderer.ctx.device, frameBuffer.buffer, nil)
    if frameBuffer.memory.int64 != 0:
      vkFreeMemory(renderer.ctx.device, frameBuffer.memory, nil)
  renderer.frameBuffers.setLen(0)

proc resetFrameResources(renderer: Renderer) =
  renderer.releaseFrameBuffers()
  if renderer.frameDescriptorPool.int64 != 0:
    checkVk(vkResetDescriptorPool(renderer.ctx.device,
      renderer.frameDescriptorPool, VkDescriptorPoolResetFlags(0)),
      "Resetting Vulkan frame descriptor pool")

proc resize(renderer: Renderer, size: IVec2) =
  let safeSize = ivec2(max(1'i32, size.x), max(1'i32, size.y))
  if renderer.readbackSize == safeSize:
    return
  discard vkDeviceWaitIdle(renderer.ctx.device)
  renderer.destroySwapChainResources()
  recreateSwapChain(renderer.ctx, safeSize.x.int, safeSize.y.int)
  renderer.createSwapChainResources()

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

  if primitive.points.len > result.vertexCapacity:
    if result.vertexPtr != nil:
      vkUnmapMemory(renderer.ctx.device, result.vertexMemory)
      result.vertexPtr = nil
    if result.vertexBuffer.int64 != 0:
      vkDestroyBuffer(renderer.ctx.device, result.vertexBuffer, nil)
      vkFreeMemory(renderer.ctx.device, result.vertexMemory, nil)
    result.vertexCapacity = max(primitive.points.len, 1)
    createBuffer(renderer.ctx, VkDeviceSize(result.vertexCapacity * sizeof(VkVertex)),
      VK_BUFFER_USAGE_VERTEX_BUFFER_BIT.uint32,
      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.uint32 or
        VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.uint32,
      result.vertexBuffer,
      result.vertexMemory)
    checkVk(vkMapMemory(renderer.ctx.device, result.vertexMemory,
      VkDeviceSize(0), VkDeviceSize(result.vertexCapacity * sizeof(VkVertex)),
      VkMemoryMapFlags(0), result.vertexPtr.addr),
      "Mapping Vulkan vertex buffer")

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
    if result.indexPtr != nil:
      vkUnmapMemory(renderer.ctx.device, result.indexMemory)
      result.indexPtr = nil
    if result.indexBuffer.int64 != 0:
      vkDestroyBuffer(renderer.ctx.device, result.indexBuffer, nil)
      vkFreeMemory(renderer.ctx.device, result.indexMemory, nil)
    result.indexCapacity = max(indices.len, 1)
    createBuffer(renderer.ctx, VkDeviceSize(result.indexCapacity * sizeof(uint32)),
      VK_BUFFER_USAGE_INDEX_BUFFER_BIT.uint32,
      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.uint32 or
        VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.uint32,
      result.indexBuffer,
      result.indexMemory)
    checkVk(vkMapMemory(renderer.ctx.device, result.indexMemory,
      VkDeviceSize(0), VkDeviceSize(result.indexCapacity * sizeof(uint32)),
      VkMemoryMapFlags(0), result.indexPtr.addr),
      "Mapping Vulkan index buffer")
  if indices.len > 0:
    copyMem(result.indexPtr, unsafeAddr indices[0], indices.len * sizeof(uint32))
  result.geometryVersion = primitive.geometryVersion

proc ensureMaterial(renderer: Renderer, material: Material): VkMaterial =
  if material == nil:
    return nil
  if material.data != nil and material.data.materialVersion == material.materialVersion:
    return material.data
  if material.data != nil:
    renderer.releaseMaterial(material.data)

  result = VkMaterial()
  material.data = result

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
  for i, texture in result.textures:
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

proc shadyPixelConstants(
  primitive: Primitive,
  tint: Color,
  ambientLightColor: Color,
  sunLightDirection: Vec3,
  sunLightColor: Color,
  rimLightDirection: Vec3,
  rimLightColor: Color,
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
      if material.alphaMode == MaskAlphaMode: material.alphaCutoff else: -1.0'f32
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
      rotation: 0.0'f32
    )
    writer.putTextureTransform(identityTransform)
    writer.putTextureTransform(identityTransform)
    writer.putTextureTransform(identityTransform)
    writer.putTextureTransform(identityTransform)
    writer.putTextureTransform(identityTransform)
    writer.putColor(color(1, 1, 1, 1))
    writer.putFloat(-1.0'f32)
    writer.putFloat(1.0'f32)
    writer.putFloat(1.0'f32)
    writer.putFloat(0.0'f32)
    writer.putFloat(1.0'f32)
    writer.putVec3(vec3(0, 0, 0))
    writer.putFloat(1.0'f32)
    writer.putBool(false)

  writer.putVec3(sunLightDirection)
  writer.putVec3(rimLightDirection)
  writer.putVec3(cameraPosition)
  writer.putColor(sunLightColor)
  writer.putColor(rimLightColor)
  writer.putFloat(3.0'f32)
  writer.putBool(false)
  writer.putFloat(0.0005'f32)
  writer.putVec2(vec2(1.0'f32 / 2048.0'f32, 1.0'f32 / 2048.0'f32))
  writer.putInt(0)
  writer.putColor(tint)
  writer.putColor(ambientLightColor)
  writer.finish()

proc createFrameBufferWithData(
  renderer: Renderer,
  data: openArray[uint32]
): FrameBuffer =
  let byteSize = VkDeviceSize(max(4, data.len * sizeof(uint32)))
  createBuffer(renderer.ctx, byteSize,
    VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT.uint32,
    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.uint32 or
      VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.uint32,
    result.buffer,
    result.memory)
  var mapped: pointer
  checkVk(vkMapMemory(renderer.ctx.device, result.memory,
    VkDeviceSize(0), byteSize, VkMemoryMapFlags(0), mapped.addr),
    "Mapping Vulkan uniform buffer")
  if data.len > 0:
    copyMem(mapped, unsafeAddr data[0], data.len * sizeof(uint32))
  vkUnmapMemory(renderer.ctx.device, result.memory)
  renderer.frameBuffers.add(result)

proc createUniformDescriptorSet(
  renderer: Renderer,
  vertexConstants,
  pixelConstants: openArray[uint32]
): VkDescriptorSet =
  let
    vertexBuffer = renderer.createFrameBufferWithData(vertexConstants)
    pixelBuffer = renderer.createFrameBufferWithData(pixelConstants)
  var layout = renderer.uniformSetLayout
  var allocInfo = VkDescriptorSetAllocateInfo(
    sType: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool: renderer.frameDescriptorPool,
    descriptorSetCount: 1,
    pSetLayouts: layout.addr
  )
  checkVk(vkAllocateDescriptorSets(renderer.ctx.device, allocInfo.addr,
    result.addr),
    "Allocating Vulkan uniform descriptor set")

  var bufferInfos = [
    VkDescriptorBufferInfo(
      buffer: vertexBuffer.buffer,
      offset: VkDeviceSize(0),
      range: VkDeviceSize(vertexConstants.len * sizeof(uint32))
    ),
    VkDescriptorBufferInfo(
      buffer: pixelBuffer.buffer,
      offset: VkDeviceSize(0),
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
  dstAccess: VkAccessFlags2
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
      baseMipLevel: 0,
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

proc drawPrimitive(
  renderer: Renderer,
  commandBuffer: VkCommandBuffer,
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
    primitive.material != nil and primitive.material.alphaMode == BlendAlphaMode
  if isBlend != blendedPass:
    return

  let vkPrimitive = renderer.ensurePrimitive(primitive)
  if vkPrimitive.indexCount == 0:
    return
  let vkMaterial = renderer.ensureMaterial(primitive.material)
  let key = PipelineKey(
    topology: vkPrimitive.topology.uint32,
    doubleSided: primitive.material != nil and primitive.material.doubleSided,
    blended: isBlend
  )
  let pipeline = renderer.getPipeline(key)
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
    uniformSet = renderer.createUniformDescriptorSet(
      vertexConstants,
      pixelConstants
    )
  var descriptorSets = [vkMaterial.descriptorSet, uniformSet]
  var vertexBuffers = [vkPrimitive.vertexBuffer]
  var offsets = [VkDeviceSize(0)]

  vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline)
  vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
    renderer.pipelineLayout, 0, descriptorSets.len.uint32,
    descriptorSets[0].addr, 0, nil)
  vkCmdBindVertexBuffers(commandBuffer, 0, 1,
    vertexBuffers[0].addr, offsets[0].addr)
  vkCmdBindIndexBuffer(commandBuffer, vkPrimitive.indexBuffer,
    VkDeviceSize(0), VK_INDEX_TYPE_UINT32)
  vkCmdDrawIndexed(commandBuffer, vkPrimitive.indexCount.uint32, 1, 0, 0, 0)

proc collectOrDrawNode(
  renderer: Renderer,
  commandBuffer: VkCommandBuffer,
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
          commandBuffer,
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
      commandBuffer,
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
  cameraPosition: Vec3
) =
  discard vkResetCommandBuffer(commandBuffer, VkCommandBufferResetFlags(0))
  var beginInfo = VkCommandBufferBeginInfo(
    sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
  )
  checkVk(vkBeginCommandBuffer(commandBuffer, beginInfo.addr),
    "Beginning Vulkan draw command buffer")

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

  vkCmdBeginRendering(commandBuffer, renderingInfo.addr)
  vkCmdSetViewport(commandBuffer, 0, 1, viewport.addr)
  vkCmdSetScissor(commandBuffer, 0, 1, scissor.addr)

  if node != nil and node.visible:
    node.updateTransforms(transform, true)
    var blended: seq[BlendEntry]
    renderer.collectOrDrawNode(
      commandBuffer,
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
          commandBuffer,
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

  vkCmdEndRendering(commandBuffer)

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
  ## Draws a full glTF PBR frame through Vulkan.
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
    cameraPosition
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
  renderer.releaseFrameBuffers()
  renderer.destroySwapChainResources()
  if renderer.readbackBuffer.int64 != 0:
    vkDestroyBuffer(renderer.ctx.device, renderer.readbackBuffer, nil)
    renderer.readbackBuffer = VkBuffer(0)
  if renderer.readbackMemory.int64 != 0:
    vkFreeMemory(renderer.ctx.device, renderer.readbackMemory, nil)
    renderer.readbackMemory = VkDeviceMemory(0)
  if renderer.frameDescriptorPool.int64 != 0:
    vkDestroyDescriptorPool(renderer.ctx.device, renderer.frameDescriptorPool, nil)
    renderer.frameDescriptorPool = VkDescriptorPool(0)
  if renderer.pipelineLayout.int64 != 0:
    vkDestroyPipelineLayout(renderer.ctx.device, renderer.pipelineLayout, nil)
    renderer.pipelineLayout = VkPipelineLayout(0)
  if renderer.uniformSetLayout.int64 != 0:
    vkDestroyDescriptorSetLayout(renderer.ctx.device, renderer.uniformSetLayout, nil)
    renderer.uniformSetLayout = VkDescriptorSetLayout(0)
  if renderer.materialSetLayout.int64 != 0:
    vkDestroyDescriptorSetLayout(renderer.ctx.device, renderer.materialSetLayout, nil)
    renderer.materialSetLayout = VkDescriptorSetLayout(0)
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
