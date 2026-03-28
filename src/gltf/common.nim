import
  chroma, opengl, pixie, vmath

type
  GltfError* = object of CatchableError

  TextureTransform* = object
    texCoord*: int
    offset*: Vec2
    scale*: Vec2
    rotation*: float32

  TextureSampler* = object
    magFilter*: GLint
    minFilter*: GLint
    wrapS*: GLint
    wrapT*: GLint

  AlphaMode* = enum
    OpaqueAlphaMode, MaskAlphaMode, BlendAlphaMode

  CameraKind* = enum
    ckPerspective, ckOrthographic

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

  Primitive* = ref object
    points*: seq[Vec3]
    uvs*: seq[Vec2]
    normals*: seq[Vec3]
    tangents*: seq[Vec4]
    colors*: seq[ColorRGBX]
    jointIds*: seq[JointIds]
    jointWeights*: seq[Vec4]
    indices16*: seq[uint16]
    indices32*: seq[uint32]
    material*: Material
    mode*: GLenum

    uploaded*: bool
    vertexArrayId*: GLuint
    pointsId*: GLuint
    uvsId*: GLuint
    normalsId*: GLuint
    tangentsId*: GLuint
    colorsId*: GLuint
    jointIdsId*: GLuint
    jointWeightsId*: GLuint
    indicesId*: GLuint

  Mesh* = ref object
    name*: string
    primitives*: seq[Primitive]

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
    currentClip*: int
    animTime*: float32

    mesh*: Mesh
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
    AnimTranslation, AnimRotation, AnimScale, AnimVisibility

  AnimationChannel* = object
    target*: Node
    path*: AnimPath
    times*: seq[float32]
    valuesVec3*: seq[Vec3]
    valuesQuat*: seq[Quat]
    valuesFloat*: seq[float32]

  AnimationClip* = object
    name*: string
    duration*: float32
    channels*: seq[AnimationChannel]

  Material* = ref object
    name*: string
    baseColor*: Image
    baseColorTransform*: TextureTransform
    baseColorSampler*: TextureSampler
    baseColorFactor*: Color
    metallicRoughness*: Image
    metallicRoughnessTransform*: TextureTransform
    metallicRoughnessSampler*: TextureSampler
    metallicFactor*: float32
    roughnessFactor*: float32
    normal*: Image
    normalTransform*: TextureTransform
    normalSampler*: TextureSampler
    hasNormalTexture*: bool
    normalScale*: float32
    occlusion*: Image
    occlusionTransform*: TextureTransform
    occlusionSampler*: TextureSampler
    occlusionStrength*: float32
    emissive*: Image
    emissiveTransform*: TextureTransform
    emissiveSampler*: TextureSampler
    emissiveFactor*: Color

    alphaMode*: AlphaMode
    alphaCutoff*: float32
    doubleSided*: bool
    transmissionFactor*: float32

    baseColorId*: GLuint
    metallicRoughnessId*: GLuint
    normalId*: GLuint
    occlusionId*: GLuint
    emissiveId*: GLuint

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

