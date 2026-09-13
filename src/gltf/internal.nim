import
  chroma, vmath,
  common

type
  BufferView* = object
    buffer*: int
    byteOffset*, byteLength*, byteStride*: int

  SparseIndices* = object
    bufferView*: int
    byteOffset*: int
    componentType*: ComponentType

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
    componentType*: ComponentType
    kind*: AccessorKind
    normalized*: bool
    sparse*: SparseInfo

  Texture* = object
    source*: int
    sampler*: int

  Sampler* = object
    magFilter*: TextureMagFilter
    minFilter*: TextureMinFilter
    wrapS*, wrapT*: TextureWrap

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
    unlit*: bool
    alphaCutoff*: float32
    doubleSided*: bool
    transmissionFactor*: float32
    hasDiffuseTransmission*: bool
    diffuseTransmissionFactor*: float32
    diffuseTransmissionColorFactor*: Vec3
    diffuseTransmissionTexture*, diffuseTransmissionColorTexture*: MaterialTexture
    hasTransmission*, hasVolume*, hasIor*: bool
    transmissionTexture*, thicknessTexture*: MaterialTexture
    thicknessFactor*, attenuationDistance*, ior*: float32
    attenuationColor*: Vec3
    hasSpecular*: bool
    specularFactor*: float32
    specularColorFactor*: Vec3
    sheenColorFactor*: Vec3
    sheenRoughnessFactor*: float32

  MeshInfo* = object
    name*: string
    primitives*: seq[int]
    weights*: seq[float32]
    targetNames*: seq[string]

  PrimitiveAttributes* = object
    position*, normal*, tangent*, color0*, texcoord0*, texcoord1*: int
    joints0*, weights0*: int

  DracoAttributeInfo* = object
    name*: string
    id*: int

  DracoInfo* = object
    used*: bool
    bufferView*: int
    attributes*: seq[DracoAttributeInfo]

  MorphTargetInfo* = object
    position*, normal*, tangent*: int

  PrimitiveInfo* = object
    attributes*: PrimitiveAttributes
    indices*, material*: int
    mode*: PrimitiveMode
    draco*: DracoInfo
    morphTargets*: seq[MorphTargetInfo]

  SkinInfo* = object
    name*: string
    inverseBindMatrices*: int
    skeleton*: int
    joints*: seq[int]
