import
  chroma, opengl, vmath

type
  BufferView* = object
    buffer*: int
    byteOffset*, byteLength*, byteStride*: int

  SparseIndices* = object
    bufferView*: int
    byteOffset*: int
    componentType*: GLenum

  SparseValues* = object
    bufferView*: int
    byteOffset*: int

  SparseInfo* = object
    count*: int
    indices*: SparseIndices
    values*: SparseValues
    used*: bool

  AccessorKind* = enum
    atSCALAR, atVEC2, atVEC3, atVEC4, atMAT2, atMAT3, atMAT4

  Accessor* = object
    bufferView*: int
    byteOffset*, count*: int
    componentType*: GLenum
    kind*: AccessorKind
    normalized*: bool
    sparse*: SparseInfo

  Texture* = object
    source*: int
    sampler*: int

  Sampler* = object
    magFilter*, minFilter*, wrapS*, wrapT*: GLint

  MaterialTexture* = object
    index*: int
    texCoord*: int
    offset*: Vec2
    uvScale*: Vec2
    rotation*: float32
    scale*: float32
    strength*: float32

  PbrMetallicRoughness* = object
    baseColorTexture*: MaterialTexture
    baseColorFactor*: Color
    metallicRoughnessTexture*: MaterialTexture
    metallicFactor*: float32
    roughnessFactor*: float32

  MaterialInfo* = object
    name*: string
    pbrMetallicRoughness*: PbrMetallicRoughness
    normalTexture*: MaterialTexture
    occlusionTexture*: MaterialTexture
    emissiveTexture*: MaterialTexture
    emissiveFactor*: Color
    alphaMode*: string
    alphaCutoff*: float32
    doubleSided*: bool
    transmissionFactor*: float32

  MeshInfo* = object
    name*: string
    primitives*: seq[int]
    weights*: seq[float32]
    targetNames*: seq[string]

  PrimitiveAttributes* = object
    position*, normal*, color0*, texcoord0*, texcoord1*: int
    joints0*, weights0*: int

  MorphTargetInfo* = object
    position*, normal*, tangent*: int

  PrimitiveInfo* = object
    attributes*: PrimitiveAttributes
    indices*, material*: int
    mode*: GLenum
    morphTargets*: seq[MorphTargetInfo]

  SkinInfo* = object
    name*: string
    inverseBindMatrices*: int
    skeleton*: int
    joints*: seq[int]
