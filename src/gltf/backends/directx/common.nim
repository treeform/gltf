when not defined(windows):
  {.error: "The glTF DirectX backend requires Windows.".}

import
  pkg/dx12

type
  DxTopology* = enum
    dtPoint, dtLine, dtTriangle

  PipelineKey* = object
    topology*: DxTopology
    doubleSided*: bool
    blended*: bool

  DxTexture* = ref object
    resource*: ID3D12Resource
    format*: uint32
    isCube*: bool
    mipLevels*: int

  PrimitiveData* = ref object
    geometryVersion*: uint64
    vertexBuffer*: ID3D12Resource
    vertexBufferPtr*: pointer
    vertexBufferView*: D3D12_VERTEX_BUFFER_VIEW
    vertexCapacity*: int
    indexBuffer*: ID3D12Resource
    indexBufferPtr*: pointer
    indexBufferView*: D3D12_INDEX_BUFFER_VIEW
    indexCapacity*: int
    indexCount*: int
    topology*: uint32
    topologyKind*: DxTopology

  MaterialData* = ref object
    materialVersion*: uint64
    heap*: ID3D12DescriptorHeap
    handleGpu*: D3D12_GPU_DESCRIPTOR_HANDLE
    textures*: seq[DxTexture]

  GltfFileData* = ref object
    sceneVersion*: uint64

  DxPrimitive* = PrimitiveData
  DxMaterial* = MaterialData
