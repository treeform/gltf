type
  PrimitiveData* = ref object
    geometryVersion*: uint64

  MaterialData* = ref object
    materialVersion*: uint64

  GltfFileData* = ref object
    sceneVersion*: uint64
