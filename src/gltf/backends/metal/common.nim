when defined(macosx):
  import pkg/metal4

type
  MetalTexture* = ref object
    width*, height*: int
    when defined(macosx):
      texture*: MTLTexture

  PrimitiveData* = ref object
    geometryVersion*: uint64
    vertexCount*: int
    indexCount*: int
    uses32BitIndices*: bool
    when defined(macosx):
      vertexBuffer*: MTLBuffer
      indexBuffer*: MTLBuffer

  MaterialData* = ref object
    materialVersion*: uint64
    baseColor*: MetalTexture
    metallicRoughness*: MetalTexture
    normal*: MetalTexture
    occlusion*: MetalTexture
    emissive*: MetalTexture

  GltfFileData* = ref object
    sceneVersion*: uint64
