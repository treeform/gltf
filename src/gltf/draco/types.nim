import
  ../common

type
  DracoDecodeAttribute* = object
    name*: string
    id*: int
    componentType*: ComponentType

  DracoAttributeData* = object
    name*: string
    componentType*: ComponentType
    componentCount*: int
    data*: string

  DracoDecodeResult* = object
    pointCount*: int
    faceCount*: int
    indices*: seq[uint32]
    attributes*: seq[DracoAttributeData]

  DracoError* = object of GltfError

  DracoDataType* = enum
    InvalidType = 0
    Int8Type = 1
    Uint8Type = 2
    Int16Type = 3
    Uint16Type = 4
    Int32Type = 5
    Uint32Type = 6
    Int64Type = 7
    Uint64Type = 8
    Float32Type = 9
    Float64Type = 10
    BoolType = 11

  DracoAttributeKind* = enum
    InvalidAttribute = -1
    PositionAttribute = 0
    NormalAttribute = 1
    ColorAttribute = 2
    TexCoordAttribute = 3
    GenericAttribute = 4

  DracoAttribute* = object
    kind*: DracoAttributeKind
    dataType*: DracoDataType
    componentType*: ComponentType
    numComponents*: int
    normalized*: bool
    byteStride*: int
    uniqueId*: int
    values*: string
    intValues*: seq[int32]
    pointMap*: seq[int]
    identityMap*: bool

  DracoMesh* = object
    pointCount*: int
    faceCount*: int
    faces*: seq[uint32]
    attributes*: seq[DracoAttribute]

proc dataTypeLength*(dataType: DracoDataType): int =
  ## Returns the byte size for one Draco scalar value.
  case dataType
  of Int8Type, Uint8Type, BoolType:
    1
  of Int16Type, Uint16Type:
    2
  of Int32Type, Uint32Type, Float32Type:
    4
  of Int64Type, Uint64Type, Float64Type:
    8
  of InvalidType:
    0

proc componentType*(dataType: DracoDataType): ComponentType =
  ## Converts a Draco data type to a glTF component type.
  case dataType
  of Int8Type:
    ByteComponent
  of Uint8Type, BoolType:
    UnsignedByteComponent
  of Int16Type:
    ShortComponent
  of Uint16Type:
    UnsignedShortComponent
  of Int32Type, Uint32Type:
    UnsignedIntComponent
  of Float32Type, Float64Type:
    FloatComponent
  of Int64Type, Uint64Type, InvalidType:
    raise newException(DracoError, "Unsupported Draco attribute data type")
