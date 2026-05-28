when not defined(windows):
  {.error: "The glTF Vulkan backend currently requires Windows.".}

import pkg/vk14 except Window

type
  PipelineKey* = object
    topology*: uint32
    doubleSided*: bool
    blended*: bool

  VkTextureData* = ref object
    image*: VkImage
    memory*: VkDeviceMemory
    view*: VkImageView
    sampler*: VkSampler
    format*: VkFormat
    mipLevels*: int
    layers*: int
    isCube*: bool

  MaterialData* = ref object
    materialVersion*: uint64
    descriptorPool*: VkDescriptorPool
    descriptorSet*: VkDescriptorSet
    textures*: seq[VkTextureData]

  PrimitiveData* = ref object
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
