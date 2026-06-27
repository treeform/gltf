import
  chroma, pixie, vmath

when defined(useDirectX):
  import backends/directx/common
elif defined(useVulkan):
  import backends/vulkan/common
elif defined(useMetal4):
  import backends/metal/common
else:
  import backends/opengl/common

type
  GltfError* = object of CatchableError

  ComponentType* = enum
    ByteComponent = 5120
    UnsignedByteComponent = 5121
    ShortComponent = 5122
    UnsignedShortComponent = 5123
    UnsignedIntComponent = 5125
    FloatComponent = 5126

  TextureMagFilter* = enum
    NearestMagFilter = 9728
    LinearMagFilter = 9729

  TextureMinFilter* = enum
    NearestMinFilter = 9728
    LinearMinFilter = 9729
    NearestMipmapNearestMinFilter = 9984
    LinearMipmapNearestMinFilter = 9985
    NearestMipmapLinearMinFilter = 9986
    LinearMipmapLinearMinFilter = 9987

  TextureWrap* = enum
    ClampToEdgeWrap = 33071
    MirroredRepeatWrap = 33648
    RepeatWrap = 10497

  PrimitiveMode* = enum
    PointsMode = 0
    LinesMode = 1
    LineLoopMode = 2
    LineStripMode = 3
    TrianglesMode = 4
    TriangleStripMode = 5
    TriangleFanMode = 6

  TextureTransform* = object
    texCoord*: int
    offset*: Vec2
    scale*: Vec2
    rotation*: float32

  TextureSampler* = object
    magFilter*: TextureMagFilter
    minFilter*: TextureMinFilter
    wrapS*: TextureWrap
    wrapT*: TextureWrap

  AlphaMode* = enum
    OpaqueAlphaMode, MaskAlphaMode, BlendAlphaMode

  CameraKind* = enum
    PerspectiveLens, OrthographicLens

  PerspectiveCamera* = object
    yfov*: float32
    aspectRatio*: float32
    znear*: float32
    zfar*: float32

  OrthographicCamera* = object
    xmag*: float32
    ymag*: float32
    znear*: float32
    zfar*: float32

  Camera* = ref object
    name*: string
    kind*: CameraKind
    perspective*: PerspectiveCamera
    orthographic*: OrthographicCamera

  JointIds* = array[4, uint16]

  MorphTarget* = ref object
    positionDeltas*: seq[Vec3]
    normalDeltas*: seq[Vec3]
    tangentDeltas*: seq[Vec3]

  Primitive* = ref object
    points*: seq[Vec3]
    basePoints*: seq[Vec3]
    uvs*: seq[Vec2]
    uvs1*: seq[Vec2]
    normals*: seq[Vec3]
    baseNormals*: seq[Vec3]
    tangents*: seq[Vec4]
    baseTangents*: seq[Vec4]
    colors*: seq[ColorRGBX]
    jointIds*: seq[JointIds]
    jointWeights*: seq[Vec4]
    indices16*: seq[uint16]
    indices32*: seq[uint32]
    morphTargets*: seq[MorphTarget]
    material*: Material
    mode*: PrimitiveMode
    geometryVersion*: uint64
    data*: PrimitiveData

  Mesh* = ref object
    name*: string
    primitives*: seq[Primitive]
    targetNames*: seq[string]

  Node* = ref object
    name*: string
    visible*: bool
    pos*: Vec3
    rot*: Quat
    scale*: Vec3
    mat*: Mat4

    baseVisible*: bool
    basePos*: Vec3
    baseRot*: Quat
    baseScale*: Vec3

    animations*: seq[AnimationClip]
    activeClips*: seq[int]
    animTime*: float32

    mesh*: Mesh
    morphWeights*: seq[float32]
    baseMorphWeights*: seq[float32]
    skin*: Skin
    camera*: Camera
    nodes*: seq[Node]

  Scene* = ref object
    name*: string
    nodes*: seq[Node]

  Skin* = ref object
    name*: string
    joints*: seq[Node]
    inverseBindMatrices*: seq[Mat4]
    skeleton*: Node

  AnimPath* = enum
    AnimTranslation, AnimRotation, AnimScale, AnimVisibility, AnimWeights

  AnimInterpolation* = enum
    aiStep, aiLinear, aiCubicSpline

  AnimationChannel* = object
    target*: Node
    path*: AnimPath
    interpolation*: AnimInterpolation
    times*: seq[float32]
    valuesVec3*: seq[Vec3]
    inTangentsVec3*: seq[Vec3]
    outTangentsVec3*: seq[Vec3]
    valuesQuat*: seq[Quat]
    inTangentsQuat*: seq[Quat]
    outTangentsQuat*: seq[Quat]
    valuesFloat*: seq[float32]
    inTangentsFloat*: seq[float32]
    outTangentsFloat*: seq[float32]
    valuesWeights*: seq[seq[float32]]
    inTangentsWeights*: seq[seq[float32]]
    outTangentsWeights*: seq[seq[float32]]

  AnimationClip* = object
    name*: string
    duration*: float32
    channels*: seq[AnimationChannel]

  Material* = ref object
    name*: string
    baseColor*: Image
    baseColorKtx2*: string
    baseColorName*: string
    baseColorTransform*: TextureTransform
    baseColorSampler*: TextureSampler
    baseColorFactor*: Color
    metallicRoughness*: Image
    metallicRoughnessKtx2*: string
    metallicRoughnessName*: string
    metallicRoughnessTransform*: TextureTransform
    metallicRoughnessSampler*: TextureSampler
    metallicFactor*: float32
    roughnessFactor*: float32
    normal*: Image
    normalKtx2*: string
    normalName*: string
    normalTransform*: TextureTransform
    normalSampler*: TextureSampler
    hasNormalTexture*: bool
    normalScale*: float32
    occlusion*: Image
    occlusionKtx2*: string
    occlusionName*: string
    occlusionTransform*: TextureTransform
    occlusionSampler*: TextureSampler
    occlusionStrength*: float32
    emissive*: Image
    emissiveKtx2*: string
    emissiveName*: string
    emissiveTransform*: TextureTransform
    emissiveSampler*: TextureSampler
    emissiveFactor*: Color

    alphaMode*: AlphaMode
    alphaCutoff*: float32
    doubleSided*: bool
    transmissionFactor*: float32
    materialVersion*: uint64
    data*: MaterialData

  AABounds* = object
    min*, max*: Vec3

  Bounds* = object
    center*: Vec3
    size*: Vec3
    radius*: float32

  BoundingSphere* = object
    center*: Vec3
    radius*: float

  GltfFile* = ref object
    path*: string
    root*: Node
    scenes*: seq[Scene]
    scene*: int
    cameras*: seq[Camera]
    skins*: seq[Skin]
    unsupportedUsedExtensions*: seq[string]
    sceneVersion*: uint64
    data*: GltfFileData

  DebugView* = enum
    dvLit,
    dvUnlit,
    dvNormals,
    dvAoBake,
    dvMetallic,
    dvSpecular

  RenderParams* = object
    size*: IVec2
    clearColor*: Color
    transform*: Mat4
    view*: Mat4
    proj*: Mat4
    tint*: Color
    useTrs*: bool
    ambientLightColor*: Color
    sunLightDirection*: Vec3
    sunLightColor*: Color
    rimLightDirection*: Vec3
    rimLightColor*: Color
    debugView*: DebugView
    cameraPosition*: Vec3
    useShadows*: bool
    drawSkybox*: bool
    skyboxLod*: float32
    vsync*: bool
