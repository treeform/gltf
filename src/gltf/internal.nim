import
  chroma, opengl, vmath

type
  BufferView* = object
    buffer*: int
    byteOffset*, byteLength*, byteStride*: int

  AccessorKind* = enum
    atSCALAR, atVEC2, atVEC3, atVEC4, atMAT2, atMAT3, atMAT4

  Accessor* = object
    bufferView*: int
    byteOffset*, count*: int
    componentType*: GLenum
    kind*: AccessorKind

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

  PrimitiveAttributes* = object
    position*, normal*, color0*, texcoord0*: int

  PrimitiveInfo* = object
    attributes*: PrimitiveAttributes
    indices*, material*: int
    mode*: GLenum
