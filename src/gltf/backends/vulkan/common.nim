when not defined(windows):
  {.error: "The glTF Vulkan backend currently requires Windows.".}

import pkg/vk14 except Window

type
  PipelineKey* = object
    topology*: uint32
    doubleSided*: bool
    blended*: bool
    ibl*, post*, mirrored*, background*: bool

  VkTextureData* = ref object
    image*: VkImage
    memory*: VkDeviceMemory
    view*: VkImageView
    sampler*: VkSampler
    format*: VkFormat
    mipLevels*: int
    layers*: int
    isCube*: bool

  VkBufferBlock* = ref object
    buffer*: VkBuffer
    memory*: VkDeviceMemory
    mapped*: pointer
    capacity*, used*, users*: int

  MaterialData* = ref object
    binding*: MaterialData
    references*: int
    materialVersion*: uint64
    environmentVersion*: uint64
    descriptorPool*: VkDescriptorPool
    descriptorSet*: VkDescriptorSet
    textures*: seq[VkTextureData]
    ibl*: bool

  PrimitiveData* = ref object
    vertexBlock*, indexBlock*: VkBufferBlock
    vertexOffset*, indexOffset*: VkDeviceSize
    geometryVersion*: uint64
    vertexBuffer*: VkBuffer
    vertexMemory*: VkDeviceMemory
    vertexPtr*: pointer
    vertexCapacity*: int
    indexBuffer*: VkBuffer
    indexMemory*: VkDeviceMemory
    indexPtr*: pointer
    indexCapacity*: int
    indexCount*: int
    topology*: VkPrimitiveTopology

  GltfFileData* = ref object
    sceneVersion*: uint64

  VkTexture* = VkTextureData
  VkPrimitive* = PrimitiveData
  VkMaterial* = MaterialData
