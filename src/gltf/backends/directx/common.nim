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
    ibl*, post*, mirrored*, background*, downsample*: bool
    samplerSlots*: array[28, int]

  DxTexture* = ref object
    resource*: ID3D12Resource
    format*: uint32
    isCube*: bool
    mipLevels*: int

  DxBufferBlock* = ref object
    resource*: ID3D12Resource
    mapped*: pointer
    capacity*, used*, users*: int

  PrimitiveData* = ref object
    vertexBlock*, indexBlock*: DxBufferBlock
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
    binding*: MaterialData
    references*: int
    materialVersion*: uint64
    environmentVersion*: uint64
    heap*: ID3D12DescriptorHeap
    handleGpu*: D3D12_GPU_DESCRIPTOR_HANDLE
    textures*: seq[DxTexture]
    samplerHeap*: ID3D12DescriptorHeap
    samplerSlots*: array[28, int]
    ibl*: bool

  GltfFileData* = ref object
    sceneVersion*: uint64

  DxPrimitive* = PrimitiveData
  DxMaterial* = MaterialData
