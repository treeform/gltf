import opengl

type
  PrimitiveData* = ref object
    uploaded*: bool
    geometryVersion*: uint64
    vertexArrayId*: GLuint
    pointsId*: GLuint
    uvsId*: GLuint
    uvs1Id*: GLuint
    normalsId*: GLuint
    tangentsId*: GLuint
    colorsId*: GLuint
    jointIdsId*: GLuint
    jointWeightsId*: GLuint
    indicesId*: GLuint

  MaterialData* = ref object
    materialVersion*: uint64
    baseColorId*: GLuint
    baseColorSrgbId*: GLuint
    metallicRoughnessId*: GLuint
    normalId*: GLuint
    occlusionId*: GLuint
    emissiveId*: GLuint
    emissiveSrgbId*: GLuint
    transmissionId*, thicknessId*: GLuint
    diffuseTransmissionId*, diffuseTransmissionColorId*: GLuint
    anisotropyId*: GLuint
    clearcoatId*, clearcoatRoughnessId*, clearcoatNormalId*: GLuint

  GltfFileData* = ref object
    sceneVersion*: uint64
