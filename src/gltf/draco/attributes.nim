import
  std/[math, strformat],
  ../common,
  bitstreams, entropy, meshes, types

const
  EncoderGeneric = 0
  EncoderInteger = 1
  EncoderQuantization = 2
  EncoderNormals = 3
  MeshVertexAttribute = 0
  PredictionNone = -2
  PredictionDifference = 0
  PredictionParallelogram = 1
  PredictionMultiParallelogram = 2
  PredictionConstrainedMultiParallelogram = 4
  PredictionTexCoordsPortable = 5
  PredictionGeometricNormal = 6
  TransformWrap = 1
  TransformNormalOctahedron = 2
  TransformNormalOctahedronCanonicalized = 3
  PositionKind = 0
  NormalKind = 1
  ColorKind = 2
  TexCoordKind = 3
  GenericKind = 4
  UpperNormalBound = 1 shl 29

type
  AttributeController = ref object
    linear: bool
    attrDataId: int
    elementType: int
    attrIds: seq[int]
    decoderTypes: seq[int]
    pointIds: seq[int]
    encodingKind: int

  WrapTransform = object
    minValue: int32
    maxValue: int32
    maxDif: int32

  OctTool = object
    qBits: int
    maxQuantizedValue: int
    maxValue: int
    centerValue: int
    dequantizationScale: float32

  NormalTransform = object
    tool: OctTool
    canonical: bool

  PredictionInfo = object
    predictionMethod: int
    transformType: int
    wrap: WrapTransform
    normal: NormalTransform
    creaseEdges: seq[seq[bool]]
    orientations: seq[bool]
    flipDecoder: RAnsBitDecoder

proc signedSymbol(value: uint32): int32 =
  ## Converts an unsigned Draco symbol to a signed integer.
  let shifted = int32(value shr 1)
  if (value and 1) != 0:
    return -shifted - 1
  else:
    return shifted

proc appendUint8(data: var string, value: uint8) =
  ## Appends one byte to a binary string.
  data.add(char(value))

proc appendUint16(data: var string, value: uint16) =
  ## Appends a little-endian uint16 to a binary string.
  data.appendUint8((value and 0xff'u16).uint8)
  data.appendUint8((value shr 8).uint8)

proc appendUint32(data: var string, value: uint32) =
  ## Appends a little-endian uint32 to a binary string.
  data.appendUint8((value and 0xff'u32).uint8)
  data.appendUint8(((value shr 8) and 0xff'u32).uint8)
  data.appendUint8(((value shr 16) and 0xff'u32).uint8)
  data.appendUint8(((value shr 24) and 0xff'u32).uint8)

proc appendFloat32(data: var string, value: float32) =
  ## Appends a little-endian float32 to a binary string.
  data.appendUint32(cast[uint32](value))

proc dracoKind(value: int): DracoAttributeKind =
  ## Converts a Draco attribute kind id.
  case value
  of PositionKind:
    return PositionAttribute
  of NormalKind:
    return NormalAttribute
  of ColorKind:
    return ColorAttribute
  of TexCoordKind:
    return TexCoordAttribute
  of GenericKind:
    return GenericAttribute
  else:
    raise newException(DracoError, &"Invalid Draco attribute kind {value}")

proc dracoType(value: int): DracoDataType =
  ## Converts a Draco scalar data type id.
  if value < InvalidType.int or value > BoolType.int:
    raise newException(DracoError, &"Invalid Draco data type {value}")
  return DracoDataType(value)

proc addAttribute(
  mesh: var DracoMesh,
  kind: DracoAttributeKind,
  dataType: DracoDataType,
  numComponents: int,
  normalized: bool,
  uniqueId: int
): int =
  ## Adds a decoded attribute descriptor to the mesh.
  if numComponents <= 0:
    raise newException(DracoError, "Invalid Draco attribute component count")
  var attr = DracoAttribute(
    kind: kind,
    dataType: dataType,
    componentType: dataType.componentType(),
    numComponents: numComponents,
    normalized: normalized,
    byteStride: dataType.dataTypeLength() * numComponents,
    uniqueId: uniqueId,
    identityMap: true
  )
  mesh.attributes.add(attr)
  return mesh.attributes.len - 1

proc mappedIndex(attr: DracoAttribute, pointId: int): int =
  ## Returns the attribute value index for a point id.
  if attr.identityMap:
    return pointId
  return attr.pointMap[pointId]

proc intComponent(attr: DracoAttribute, entry, component: int): int32 =
  ## Returns one integer component from an attribute.
  return attr.intValues[entry * attr.numComponents + component]

proc setOctBits(tool: var OctTool, qBits: int) =
  ## Initializes octahedral normal helper constants.
  if qBits < 2 or qBits > 30:
    raise newException(DracoError, "Invalid Draco normal quantization bits")
  tool.qBits = qBits
  tool.maxQuantizedValue = (1 shl qBits) - 1
  tool.maxValue = tool.maxQuantizedValue - 1
  tool.centerValue = tool.maxValue div 2
  tool.dequantizationScale = 2.0'f / tool.maxValue.float32

proc setMaxQuantizedValue(tool: var OctTool, value: int) =
  ## Initializes octahedral helper constants from the max quantized value.
  if value mod 2 == 0:
    raise newException(DracoError, "Invalid Draco octahedral max value")
  var
    q = 0
    v = value
  while v > 0:
    v = v shr 1
    inc q
  tool.setOctBits(q)

proc invertDiamond(tool: OctTool, s, t: int32): array[2, int32] =
  ## Inverts the octahedral diamond transform.
  var
    signS = 0'i32
    signT = 0'i32
  if s >= 0 and t >= 0:
    signS = 1
    signT = 1
  elif s <= 0 and t <= 0:
    signS = -1
    signT = -1
  else:
    signS = if s > 0: 1'i32 else: -1'i32
    signT = if t > 0: 1'i32 else: -1'i32
  let
    cornerS = signS * tool.centerValue.int32
    cornerT = signT * tool.centerValue.int32
  var
    us = s + s - cornerS
    ut = t + t - cornerT
  if signS * signT >= 0:
    let tmp = us
    us = -ut
    ut = -tmp
  else:
    let tmp = us
    us = ut
    ut = tmp
  us += cornerS
  ut += cornerT
  return [us div 2, ut div 2]

proc canonicalizeOctahedralCoords(
  tool: OctTool,
  sIn, tIn: int32
): array[2, int32] =
  ## Canonicalizes octahedral edge coordinates.
  var
    s = sIn
    t = tIn
  if (s == 0 and t == 0) or
    (s == 0 and t == tool.maxValue.int32) or
    (s == tool.maxValue.int32 and t == 0):
      s = tool.maxValue.int32
      t = tool.maxValue.int32
  elif s == 0 and t > tool.centerValue.int32:
    t = tool.centerValue.int32 - (t - tool.centerValue.int32)
  elif s == tool.maxValue.int32 and t < tool.centerValue.int32:
    t = tool.centerValue.int32 + (tool.centerValue.int32 - t)
  elif t == tool.maxValue.int32 and s < tool.centerValue.int32:
    s = tool.centerValue.int32 + (tool.centerValue.int32 - s)
  elif t == 0 and s > tool.centerValue.int32:
    s = tool.centerValue.int32 - (s - tool.centerValue.int32)
  return [s, t]

proc canonicalizeIntegerVector(
  tool: OctTool,
  vector: var array[3, int32]
) =
  ## Normalizes an integer vector to the octahedral center value.
  let absSum =
    abs(vector[0]) + abs(vector[1]) + abs(vector[2])
  if absSum == 0:
    vector[0] = tool.centerValue.int32
    vector[1] = 0
    vector[2] = 0
  else:
    vector[0] = int32((vector[0].int64 * tool.centerValue) div absSum)
    vector[1] = int32((vector[1].int64 * tool.centerValue) div absSum)
    if vector[2] >= 0:
      vector[2] = tool.centerValue.int32 - abs(vector[0]) - abs(vector[1])
    else:
      vector[2] = -(tool.centerValue.int32 - abs(vector[0]) - abs(vector[1]))

proc integerVectorToOct(
  tool: OctTool,
  vector: array[3, int32]
): array[2, int32] =
  ## Converts an integer vector to quantized octahedral coordinates.
  var
    s: int32
    t: int32
  if vector[0] >= 0:
    s = vector[1] + tool.centerValue.int32
    t = vector[2] + tool.centerValue.int32
  else:
    if vector[1] < 0:
      s = abs(vector[2])
    else:
      s = tool.maxValue.int32 - abs(vector[2])
    if vector[2] < 0:
      t = abs(vector[1])
    else:
      t = tool.maxValue.int32 - abs(vector[1])
  return tool.canonicalizeOctahedralCoords(s, t)

proc octToUnit(tool: OctTool, s, t: int32): array[3, float32] =
  ## Converts quantized octahedral coordinates to a unit vector.
  var
    y = s.float32 * tool.dequantizationScale - 1.0'f
    z = t.float32 * tool.dequantizationScale - 1.0'f
  let x = 1.0'f - abs(y) - abs(z)
  var xOffset = -x
  if xOffset < 0:
    xOffset = 0
  if y < 0:
    y += xOffset
  else:
    y -= xOffset
  if z < 0:
    z += xOffset
  else:
    z -= xOffset
  let normSq = x * x + y * y + z * z
  if normSq < 0.000001'f:
    return [0.0'f, 0.0'f, 0.0'f]
  let scale = 1.0'f / sqrt(normSq)
  return [x * scale, y * scale, z * scale]

proc decodeWrapTransform(stream: var DracoStream): WrapTransform =
  ## Decodes wrap prediction transform data.
  result.minValue = stream.readInt32()
  result.maxValue = stream.readInt32()
  if result.minValue > result.maxValue:
    raise newException(DracoError, "Invalid Draco wrap range")
  let diff = result.maxValue - result.minValue
  if diff < 0 or diff >= int32.high:
    raise newException(DracoError, "Invalid Draco wrap difference")
  result.maxDif = diff + 1

proc computeOriginal(
  transform: WrapTransform,
  predicted: openArray[int32],
  corrections: seq[int32],
  corrOffset: int,
  outData: var seq[int32],
  outOffset: int,
  componentCount: int
) =
  ## Applies a wrap transform to prediction corrections.
  for c in 0 ..< componentCount:
    var pred = predicted[c]
    if pred > transform.maxValue:
      pred = transform.maxValue
    elif pred < transform.minValue:
      pred = transform.minValue
    var orig = pred + corrections[corrOffset + c]
    if orig > transform.maxValue:
      orig -= transform.maxDif
    elif orig < transform.minValue:
      orig += transform.maxDif
    outData[outOffset + c] = orig

proc isBottomLeft(s, t: int32): bool =
  ## Returns true when an octahedral point is in the bottom-left quadrant.
  if s == 0 and t == 0:
    return true
  return s < 0 and t <= 0

proc rotationCount(s, t: int32): int =
  ## Computes the octahedral canonicalization rotation count.
  if s == 0:
    if t == 0:
      return 0
    if t > 0:
      return 3
    return 1
  if s > 0:
    if t >= 0:
      return 2
    return 1
  if t <= 0:
    return 0
  else:
    return 3

proc rotatePoint(
  s, t: int32,
  count: int
): tuple[s: int32, t: int32] =
  ## Rotates an octahedral point by quarter turns.
  case count mod 4
  of 1:
    return (t, -s)
  of 2:
    return (-s, -t)
  of 3:
    return (-t, s)
  else:
    return (s, t)

proc computeOriginal(
  transform: NormalTransform,
  predicted: openArray[int32],
  corrections: seq[int32],
  corrOffset: int,
  outData: var seq[int32],
  outOffset: int
) =
  ## Applies a normal octahedral prediction transform.
  if not transform.canonical:
    raise newException(DracoError, "Unsupported Draco normal transform")
  let
    center = transform.tool.centerValue.int32
    maxValue = transform.tool.maxQuantizedValue.int32
  var
    predS = predicted[0] - center
    predT = predicted[1] - center
  let predInDiamond = abs(predS) + abs(predT) <= center
  if not predInDiamond:
    let inv = transform.tool.invertDiamond(predS, predT)
    predS = inv[0]
    predT = inv[1]
  let
    bottomLeft = isBottomLeft(predS, predT)
    rotations = rotationCount(predS, predT)
  if not bottomLeft:
    let rotated = rotatePoint(predS, predT, rotations)
    predS = rotated.s
    predT = rotated.t
  var
    origS = predS + corrections[corrOffset]
    origT = predT + corrections[corrOffset + 1]
  if origS > center:
    origS -= maxValue
  elif origS < -center:
    origS += maxValue
  if origT > center:
    origT -= maxValue
  elif origT < -center:
    origT += maxValue
  if not bottomLeft:
    let rotated = rotatePoint(origS, origT, (4 - rotations) mod 4)
    origS = rotated.s
    origT = rotated.t
  if not predInDiamond:
    let inv = transform.tool.invertDiamond(origS, origT)
    origS = inv[0]
    origT = inv[1]
  outData[outOffset] = origS + center
  outData[outOffset + 1] = origT + center

proc computeParallelogram(
  corner: int,
  dataId: int,
  table: CornerTable,
  data: EncodingData,
  decoded: seq[int32],
  componentCount: int,
  outPrediction: var seq[int32]
): bool =
  ## Computes one parallelogram prediction.
  let opp = table.opposite(corner)
  if opp < 0:
    return false
  let
    next = opp.nextCorner()
    prev = opp.previousCorner()
    oppData = data.vertexToValue[table.vertex(opp)]
    nextData = data.vertexToValue[table.vertex(next)]
    prevData = data.vertexToValue[table.vertex(prev)]
  if oppData < dataId and nextData < dataId and prevData < dataId:
    for c in 0 ..< componentCount:
      outPrediction[c] =
        decoded[nextData * componentCount + c] +
        decoded[prevData * componentCount + c] -
        decoded[oppData * componentCount + c]
    return true
  return false

proc computeParallelogram(
  corner: int,
  dataId: int,
  conn: AttributeCornerTable,
  data: EncodingData,
  decoded: seq[int32],
  componentCount: int,
  outPrediction: var seq[int32]
): bool =
  ## Computes a parallelogram prediction on attribute connectivity.
  let opp = conn.effectiveOpposites[corner]
  if opp < 0:
    return false
  let
    next = opp.nextCorner()
    prev = opp.previousCorner()
    oppData = data.vertexToValue[conn.cornerToVertex[opp]]
    nextData = data.vertexToValue[conn.cornerToVertex[next]]
    prevData = data.vertexToValue[conn.cornerToVertex[prev]]
  if oppData < dataId and nextData < dataId and prevData < dataId:
    for c in 0 ..< componentCount:
      outPrediction[c] =
        decoded[nextData * componentCount + c] +
        decoded[prevData * componentCount + c] -
        decoded[oppData * componentCount + c]
    return true
  return false

proc parentAttribute(mesh: DracoMesh, kind: DracoAttributeKind): int =
  ## Returns the first decoded attribute of a given kind.
  for i, attr in mesh.attributes:
    if attr.kind == kind:
      return i
  return -1

proc computeNormalPrediction(
  table: CornerTable,
  mesh: DracoMesh,
  data: EncodingData,
  position: DracoAttribute,
  entryToPoint: seq[int],
  corner: int
): array[3, int32] =
  ## Computes an area-weighted geometric normal prediction.
  proc posForCorner(c: int): array[3, int32] =
    let
      vertexId = table.vertex(c)
      dataId = data.vertexToValue[vertexId]
      pointId = entryToPoint[dataId]
      entry = position.mappedIndex(pointId)
    return [
      position.intComponent(entry, 0),
      position.intComponent(entry, 1),
      position.intComponent(entry, 2)
    ]

  let center = posForCorner(corner)
  var
    current = corner
    leftTraversal = true
    normal = [0'i64, 0'i64, 0'i64]
    guard = 0
  while current >= 0 and guard < table.cornerCount():
    inc guard
    let
      nextPos = posForCorner(current.nextCorner())
      prevPos = posForCorner(current.previousCorner())
      ax = nextPos[0].int64 - center[0].int64
      ay = nextPos[1].int64 - center[1].int64
      az = nextPos[2].int64 - center[2].int64
      bx = prevPos[0].int64 - center[0].int64
      by = prevPos[1].int64 - center[1].int64
      bz = prevPos[2].int64 - center[2].int64
    normal[0] += ay * bz - az * by
    normal[1] += az * bx - ax * bz
    normal[2] += ax * by - ay * bx
    if leftTraversal:
      current = table.swingLeft(current)
      if current < 0:
        current = table.swingRight(corner)
        leftTraversal = false
      elif current == corner:
        current = -1
    else:
      current = table.swingRight(current)
      if current == corner:
        current = -1
  let absSum = abs(normal[0]) + abs(normal[1]) + abs(normal[2])
  if absSum > UpperNormalBound:
    let quotient = absSum div UpperNormalBound
    if quotient > 0:
      normal[0] = normal[0] div quotient
      normal[1] = normal[1] div quotient
      normal[2] = normal[2] div quotient
  return [
    normal[0].int32,
    normal[1].int32,
    normal[2].int32
  ]

proc computeTexPrediction(
  table: CornerTable,
  mesh: DracoMesh,
  data: EncodingData,
  position: DracoAttribute,
  entryToPoint: seq[int],
  decoded: seq[int32],
  dataId: int,
  corner: int,
  orientations: var seq[bool]
): array[2, int32] =
  ## Computes portable texture-coordinate prediction.
  proc posForData(id: int): array[3, int64] =
    let
      pointId = entryToPoint[id]
      entry = position.mappedIndex(pointId)
    return [
      position.intComponent(entry, 0).int64,
      position.intComponent(entry, 1).int64,
      position.intComponent(entry, 2).int64
    ]

  let
    next = corner.nextCorner()
    prev = corner.previousCorner()
    nextData = data.vertexToValue[table.vertex(next)]
    prevData = data.vertexToValue[table.vertex(prev)]
  if prevData < dataId and nextData < dataId:
    let
      nOff = nextData * 2
      pOff = prevData * 2
      nextUv = [decoded[nOff], decoded[nOff + 1]]
      prevUv = [decoded[pOff], decoded[pOff + 1]]
    if nextUv == prevUv:
      return prevUv
    let
      tipPos = posForData(dataId)
      nextPos = posForData(nextData)
      prevPos = posForData(prevData)
      pn = [
        prevPos[0] - nextPos[0],
        prevPos[1] - nextPos[1],
        prevPos[2] - nextPos[2]
      ]
      pnNorm = pn[0] * pn[0] + pn[1] * pn[1] + pn[2] * pn[2]
    if pnNorm != 0:
      let
        cn = [
          tipPos[0] - nextPos[0],
          tipPos[1] - nextPos[1],
          tipPos[2] - nextPos[2]
        ]
        dot = pn[0] * cn[0] + pn[1] * cn[1] + pn[2] * cn[2]
        du = prevUv[0].int64 - nextUv[0].int64
        dv = prevUv[1].int64 - nextUv[1].int64
        xUv = [
          nextUv[0].int64 * pnNorm + dot * du,
          nextUv[1].int64 * pnNorm + dot * dv
        ]
        xPos = [
          nextPos[0] + (dot * pn[0]) div pnNorm,
          nextPos[1] + (dot * pn[1]) div pnNorm,
          nextPos[2] + (dot * pn[2]) div pnNorm
        ]
        cx = [
          tipPos[0] - xPos[0],
          tipPos[1] - xPos[1],
          tipPos[2] - xPos[2]
        ]
        cxNorm = cx[0] * cx[0] + cx[1] * cx[1] + cx[2] * cx[2]
        norm = sqrt((cxNorm * pnNorm).float64).int64
        cxUv = [dv * norm, -du * norm]
      if orientations.len > 0:
        let orientation = orientations.pop()
        if orientation:
          return [
            ((xUv[0] + cxUv[0]) div pnNorm).int32,
            ((xUv[1] + cxUv[1]) div pnNorm).int32
          ]
        return [
          ((xUv[0] - cxUv[0]) div pnNorm).int32,
          ((xUv[1] - cxUv[1]) div pnNorm).int32
        ]
  var offset = 0
  if prevData < dataId:
    offset = prevData * 2
  if nextData < dataId:
    offset = nextData * 2
  elif dataId > 0:
    offset = (dataId - 1) * 2
  else:
    return [0'i32, 0'i32]
  return [decoded[offset], decoded[offset + 1]]

proc readPredictionInfo(
  stream: var DracoStream,
  predictionMethod: int,
  transformType: int,
  positiveCorrections: bool,
  entryCount: int,
  table: CornerTable
): PredictionInfo =
  ## Decodes prediction side data.
  result.predictionMethod = predictionMethod
  result.transformType = transformType
  case transformType
  of TransformWrap:
    discard
  of TransformNormalOctahedronCanonicalized:
    result.normal.canonical = true
  of TransformNormalOctahedron:
    result.normal.canonical = false
  else:
    if predictionMethod != PredictionNone:
      raise newException(DracoError, "Unsupported Draco prediction transform")

  case predictionMethod
  of PredictionConstrainedMultiParallelogram:
    result.creaseEdges.setLen(4)
    for i in 0 ..< 4:
      let flagCount = stream.readVarint().int
      if flagCount > table.cornerCount():
        raise newException(DracoError, "Invalid Draco crease count")
      result.creaseEdges[i].setLen(flagCount)
      if flagCount > 0:
        var bitDecoder = RAnsBitDecoder()
        bitDecoder.startDecoding(stream)
        for j in 0 ..< flagCount:
          result.creaseEdges[i][j] = bitDecoder.decodeBit()
  of PredictionTexCoordsPortable:
    let orientationCount = stream.readInt32()
    if orientationCount < 0:
      raise newException(DracoError, "Invalid Draco UV orientation count")
    result.orientations.setLen(orientationCount)
    var
      lastOrientation = true
      bitDecoder = RAnsBitDecoder()
    bitDecoder.startDecoding(stream)
    for i in 0 ..< orientationCount:
      if not bitDecoder.decodeBit():
        lastOrientation = not lastOrientation
      result.orientations[i] = lastOrientation
  of PredictionGeometricNormal:
    discard
  else:
    discard

  if transformType == TransformWrap:
    result.wrap = stream.decodeWrapTransform()
  elif transformType in {
    TransformNormalOctahedron,
    TransformNormalOctahedronCanonicalized
  }:
    let
      maxValue = stream.readInt32().int
      center = stream.readInt32()
    discard center
    result.normal.tool.setMaxQuantizedValue(maxValue)
  if predictionMethod == PredictionGeometricNormal:
    result.flipDecoder.startDecoding(stream)
  discard positiveCorrections
  discard entryCount

proc decodeIntegerValues(
  stream: var DracoStream,
  mesh: DracoMesh,
  attr: DracoAttribute,
  pointIds: seq[int],
  data: EncodingData,
  table: CornerTable,
  conn: AttributeCornerTable,
  useAttrConn: bool,
  decoderType: int
): seq[int32] =
  ## Decodes portable integer attribute values.
  let
    predictionMethod = stream.readInt8().int
    transformType =
      if predictionMethod != PredictionNone:
        stream.readInt8().int
      else:
        -1
    componentCount =
      if decoderType == EncoderNormals:
        2
      else:
        attr.numComponents
    valueCount = pointIds.len * componentCount
  when defined(dracoDebug):
    if predictionMethod != PredictionNone:
      echo "Draco prediction uid=", attr.uniqueId,
        " kind=", attr.kind,
        " decoder=", decoderType,
        " method=", predictionMethod,
        " transform=", transformType,
        " points=", pointIds.len,
        " useAttrConn=", useAttrConn
  var prediction = PredictionInfo(predictionMethod: predictionMethod, transformType: transformType)
  let correctionsPositive =
    transformType in {
      TransformNormalOctahedron,
      TransformNormalOctahedronCanonicalized
    }
  var values = newSeq[int32](valueCount)
  let compressed = stream.readUint8()
  if compressed > 0:
    let symbols = decodeSymbols(valueCount, componentCount, stream)
    for i, symbol in symbols:
      values[i] =
        if predictionMethod == PredictionNone or not correctionsPositive:
          signedSymbol(symbol)
        else:
          symbol.int32
  else:
    let byteCount = stream.readUint8().int
    for i in 0 ..< valueCount:
      var raw = 0'u32
      for b in 0 ..< byteCount:
        raw = raw or (stream.readUint8().uint32 shl (b * 8))
      values[i] = cast[int32](raw)
  if predictionMethod == PredictionNone:
    return values
  prediction = readPredictionInfo(
    stream,
    predictionMethod,
    transformType,
    correctionsPositive,
    pointIds.len,
    table
  )
  result.setLen(valueCount)
  let nc = componentCount
  let predTable =
    if useAttrConn:
      CornerTable(
        faceCount: table.faceCount,
        cornerToVertex: conn.cornerToVertex,
        opposites: conn.effectiveOpposites,
        vertexCorners: conn.vertexLeftmost,
        vertexCount: conn.vertexParents.len
      )
    else:
      table
  case predictionMethod
  of PredictionDifference:
    if transformType == TransformWrap:
      var zero = newSeq[int32](nc)
      prediction.wrap.computeOriginal(zero, values, 0, result, 0, nc)
      for offset in countup(nc, valueCount - nc, nc):
        prediction.wrap.computeOriginal(
          result.toOpenArray(offset - nc, offset - 1),
          values,
          offset,
          result,
          offset,
          nc
        )
    else:
      var zero = newSeq[int32](nc)
      prediction.normal.computeOriginal(zero, values, 0, result, 0)
      for offset in countup(nc, valueCount - nc, nc):
        prediction.normal.computeOriginal(
          result.toOpenArray(offset - nc, offset - 1),
          values,
          offset,
          result,
          offset
        )
  of PredictionParallelogram:
    var pred = newSeq[int32](nc)
    prediction.wrap.computeOriginal(pred, values, 0, result, 0, nc)
    for p in 1 ..< pointIds.len:
      let corner = data.valueToCorner[p]
      let ok =
        if useAttrConn:
          computeParallelogram(
            corner,
            p,
            conn,
            data,
            result,
            nc,
            pred
          )
        else:
          computeParallelogram(
            corner,
            p,
            table,
            data,
            result,
            nc,
            pred
          )
      let dst = p * nc
      if ok:
        prediction.wrap.computeOriginal(pred, values, dst, result, dst, nc)
      else:
        prediction.wrap.computeOriginal(
          result.toOpenArray(dst - nc, dst - 1),
          values,
          dst,
          result,
          dst,
          nc
        )
  of PredictionMultiParallelogram, PredictionConstrainedMultiParallelogram:
    var
      pred = newSeq[int32](nc)
      predVals = newSeq[seq[int32]](4)
      creasePos = [0, 0, 0, 0]
    for i in 0 ..< predVals.len:
      predVals[i] = newSeq[int32](nc)
    prediction.wrap.computeOriginal(pred, values, 0, result, 0, nc)
    for p in 1 ..< pointIds.len:
      for c in 0 ..< nc:
        pred[c] = 0
      var
        usedCount = 0
        candidateCount = 0
        corner = data.valueToCorner[p]
        firstCorner = corner
        firstPass = true
        guard = 0
      while corner != -1 and guard < predTable.cornerCount():
        inc guard
        let ok =
          if useAttrConn:
            computeParallelogram(
              corner,
              p,
              conn,
              data,
              result,
              nc,
              predVals[candidateCount]
            )
          else:
            computeParallelogram(
              corner,
              p,
              table,
              data,
              result,
              nc,
              predVals[candidateCount]
            )
        if ok:
          inc candidateCount
          if candidateCount == 4:
            break
        if predictionMethod == PredictionConstrainedMultiParallelogram:
          if firstPass:
            corner =
              if useAttrConn:
                conn.effectiveOpposites[corner.nextCorner()].nextCorner()
              else:
                table.swingLeft(corner)
          else:
            corner =
              if useAttrConn:
                conn.effectiveOpposites[corner.previousCorner()].previousCorner()
              else:
                table.swingRight(corner)
          if corner == firstCorner:
            break
          if corner == -1 and firstPass:
            firstPass = false
            corner =
              if useAttrConn:
                conn.effectiveOpposites[firstCorner.previousCorner()]
                  .previousCorner()
              else:
                table.swingRight(firstCorner)
        else:
          corner =
            if useAttrConn:
              conn.effectiveOpposites[corner.previousCorner()].previousCorner()
            else:
              table.swingRight(corner)
          if corner == firstCorner:
            corner = -1
      if candidateCount > 0:
        if predictionMethod == PredictionConstrainedMultiParallelogram:
          let context = candidateCount - 1
          for i in 0 ..< candidateCount:
            let pos = creasePos[context]
            inc creasePos[context]
            if pos >= prediction.creaseEdges[context].len:
              when defined(dracoDebug):
                echo "Draco crease miss context=", context,
                  " pos=", pos,
                  " len=", prediction.creaseEdges[context].len,
                  " p=", p,
                  " candidates=", candidateCount,
                  " useAttrConn=", useAttrConn
              continue
            if not prediction.creaseEdges[context][pos]:
              for c in 0 ..< nc:
                pred[c] += predVals[i][c]
              inc usedCount
        else:
          for i in 0 ..< candidateCount:
            for c in 0 ..< nc:
              pred[c] += predVals[i][c]
          usedCount = candidateCount
      let dst = p * nc
      if usedCount == 0:
        prediction.wrap.computeOriginal(
          result.toOpenArray(dst - nc, dst - 1),
          values,
          dst,
          result,
          dst,
          nc
        )
      else:
        for c in 0 ..< nc:
          pred[c] = pred[c] div usedCount.int32
        prediction.wrap.computeOriginal(pred, values, dst, result, dst, nc)
  of PredictionTexCoordsPortable:
    let posId = mesh.parentAttribute(PositionAttribute)
    if posId < 0:
      raise newException(DracoError, "Draco UV prediction needs positions")
    let position = mesh.attributes[posId]
    for p in 0 ..< pointIds.len:
      let pred = computeTexPrediction(
        predTable,
        mesh,
        data,
        position,
        pointIds,
        result,
        p,
        data.valueToCorner[p],
        prediction.orientations
      )
      prediction.wrap.computeOriginal(
        pred,
        values,
        p * nc,
        result,
        p * nc,
        nc
      )
  of PredictionGeometricNormal:
    let posId = mesh.parentAttribute(PositionAttribute)
    if posId < 0:
      raise newException(DracoError, "Draco normal prediction needs positions")
    let position = mesh.attributes[posId]
    var tool = prediction.normal.tool
    for p in 0 ..< pointIds.len:
      var pred3 = computeNormalPrediction(
        predTable,
        mesh,
        data,
        position,
        pointIds,
        data.valueToCorner[p]
      )
      tool.canonicalizeIntegerVector(pred3)
      if prediction.flipDecoder.decodeBit():
        pred3[0] = -pred3[0]
        pred3[1] = -pred3[1]
        pred3[2] = -pred3[2]
      let pred = tool.integerVectorToOct(pred3)
      prediction.normal.computeOriginal(
        pred,
        values,
        p * nc,
        result,
        p * nc
      )
  else:
    raise newException(DracoError, &"Unsupported Draco prediction {predictionMethod}")

proc decodeQuantization(
  stream: var DracoStream,
  attr: DracoAttribute
): tuple[minValues: seq[float32], range: float32, bits: int] =
  ## Decodes quantization transform data.
  result.minValues.setLen(attr.numComponents)
  for i in 0 ..< attr.numComponents:
    result.minValues[i] = stream.readFloat32()
  result.range = stream.readFloat32()
  result.bits = stream.readUint8().int
  if result.bits < 1 or result.bits > 30:
    raise newException(DracoError, "Invalid Draco quantization bits")

proc storeIntegerAttribute(attr: var DracoAttribute) =
  ## Stores decoded integer values into the final byte buffer.
  attr.values.setLen(0)
  for value in attr.intValues:
    case attr.componentType
    of ByteComponent, UnsignedByteComponent:
      attr.values.appendUint8(value.uint8)
    of ShortComponent, UnsignedShortComponent:
      attr.values.appendUint16(value.uint16)
    of UnsignedIntComponent:
      attr.values.appendUint32(value.uint32)
    of FloatComponent:
      attr.values.appendFloat32(value.float32)

proc storeQuantizedAttribute(
  attr: var DracoAttribute,
  minValues: seq[float32],
  range: float32,
  bits: int
) =
  ## Dequantizes and stores a floating-point attribute.
  let
    maxValue = ((1'u32 shl bits) - 1).float32
    delta = range / maxValue
  attr.values.setLen(0)
  for i in 0 ..< attr.intValues.len div attr.numComponents:
    for c in 0 ..< attr.numComponents:
      let value = attr.intValues[i * attr.numComponents + c].float32 *
        delta + minValues[c]
      attr.values.appendFloat32(value)

proc storeNormalAttribute(
  attr: var DracoAttribute,
  qBits: int
) =
  ## Converts and stores an octahedral normal attribute.
  var tool = OctTool()
  tool.setOctBits(qBits)
  attr.values.setLen(0)
  for i in 0 ..< attr.intValues.len div 2:
    let vector = tool.octToUnit(
      attr.intValues[i * 2],
      attr.intValues[i * 2 + 1]
    )
    attr.values.appendFloat32(vector[0])
    attr.values.appendFloat32(vector[1])
    attr.values.appendFloat32(vector[2])

proc decodeGenericValues(
  stream: var DracoStream,
  attr: var DracoAttribute,
  pointCount: int
) =
  ## Decodes uncompressed generic attribute values.
  let byteCount = pointCount * attr.byteStride
  attr.values = stream.readBytes(byteCount)

proc decodeControllerData(
  stream: var DracoStream,
  mesh: var DracoMesh,
  controller: AttributeController
) =
  ## Decodes one sequential attribute decoder descriptor block.
  let count = stream.readVarint().int
  if count <= 0:
    raise newException(DracoError, "Invalid Draco attribute count")
  controller.attrIds.setLen(count)
  controller.decoderTypes.setLen(count)
  for i in 0 ..< count:
    let
      kind = stream.readUint8().int.dracoKind()
      dataType = stream.readUint8().int.dracoType()
      componentCount = stream.readUint8().int
      normalized = stream.readUint8() > 0
      uniqueId = stream.readVarint().int
    controller.attrIds[i] = mesh.addAttribute(
      kind,
      dataType,
      componentCount,
      normalized,
      uniqueId
    )
  for i in 0 ..< count:
    controller.decoderTypes[i] = stream.readUint8().int

proc readEdgebreakerController(
  stream: var DracoStream,
  state: var EdgebreakerMesh,
  id: int
): AttributeController =
  ## Reads one edgebreaker attribute decoder controller.
  result = AttributeController()
  result.attrDataId = stream.readInt8().int
  result.elementType = stream.readUint8().int
  discard stream.readUint8()
  if result.elementType == MeshVertexAttribute:
    if result.attrDataId >= 0:
      if result.attrDataId >= state.attributeData.len:
        raise newException(DracoError, "Invalid Draco attribute data id")
      state.attributeData[result.attrDataId].decoderId = id
      state.attributeData[result.attrDataId].connectivityUsed = false
      result.encodingKind = result.attrDataId
    else:
      state.posDataDecoderId = id
      result.encodingKind = -1
  else:
    if result.attrDataId < 0 or result.attrDataId >= state.attributeData.len:
      raise newException(DracoError, "Invalid Draco corner attribute data id")
    state.attributeData[result.attrDataId].decoderId = id
    result.encodingKind = result.attrDataId

proc prepareController(
  controller: AttributeController,
  mesh: var DracoMesh,
  state: var EdgebreakerMesh
) =
  ## Generates traversal sequence and point maps for one controller.
  if controller.linear:
    controller.pointIds.setLen(mesh.pointCount)
    for i in 0 ..< mesh.pointCount:
      controller.pointIds[i] = i
    for attrId in controller.attrIds:
      mesh.attributes[attrId].identityMap = true
    return
  if controller.elementType == MeshVertexAttribute:
    if controller.encodingKind == -1:
      controller.pointIds = state.cornerTable.generateSequence(
        mesh,
        state.posEncoding
      )
      for attrId in controller.attrIds:
        mesh.attributes[attrId].applyPointMap(
          state.cornerTable,
          mesh,
          state.posEncoding
        )
    else:
      let dataId = controller.encodingKind
      controller.pointIds = state.cornerTable.generateSequence(
        mesh,
        state.attributeData[dataId].encoding
      )
      for attrId in controller.attrIds:
        mesh.attributes[attrId].applyPointMap(
          state.cornerTable,
          mesh,
          state.attributeData[dataId].encoding
        )
  else:
    let dataId = controller.encodingKind
    controller.pointIds = state.attributeData[dataId].connectivity
      .generateSequence(
        state.cornerTable,
        mesh,
        state.attributeData[dataId].encoding
      )
    for attrId in controller.attrIds:
      mesh.attributes[attrId].applyPointMap(
        state.attributeData[dataId].connectivity,
        mesh,
        state.attributeData[dataId].encoding
      )

proc controllerEncoding(
  controller: AttributeController,
  state: var EdgebreakerMesh
): tuple[data: EncodingData, conn: AttributeCornerTable, useConn: bool] =
  ## Returns the prediction connectivity for a controller.
  if controller.linear:
    var data = EncodingData()
    data.vertexToValue.setLen(controller.pointIds.len)
    data.valueToCorner.setLen(controller.pointIds.len)
    data.valueCount = controller.pointIds.len
    for i in 0 ..< controller.pointIds.len:
      data.vertexToValue[i] = i
      data.valueToCorner[i] = i
    return (data, AttributeCornerTable(), false)
  if controller.elementType == MeshVertexAttribute:
    if controller.encodingKind == -1:
      return (state.posEncoding, AttributeCornerTable(), false)
    return (
      state.attributeData[controller.encodingKind].encoding,
      AttributeCornerTable(),
      false
    )
  return (
    state.attributeData[controller.encodingKind].encoding,
    state.attributeData[controller.encodingKind].connectivity,
    true
  )

proc decodeControllerAttributes(
  stream: var DracoStream,
  mesh: var DracoMesh,
  state: var EdgebreakerMesh,
  controller: AttributeController
) =
  ## Decodes all attributes owned by one controller.
  let enc = controller.controllerEncoding(state)
  var transformKinds = newSeq[int](controller.attrIds.len)
  var quantData: seq[tuple[minValues: seq[float32], range: float32, bits: int]]
  var normalBits = newSeq[int](controller.attrIds.len)
  quantData.setLen(controller.attrIds.len)

  for i, attrId in controller.attrIds:
    var attr = mesh.attributes[attrId]
    case controller.decoderTypes[i]
    of EncoderGeneric:
      decodeGenericValues(stream, attr, controller.pointIds.len)
    of EncoderInteger, EncoderQuantization, EncoderNormals:
      attr.intValues = decodeIntegerValues(
        stream,
        mesh,
        attr,
        controller.pointIds,
        enc.data,
        state.cornerTable,
        enc.conn,
        enc.useConn,
        controller.decoderTypes[i]
      )
    else:
      raise newException(
        DracoError,
        &"Unsupported Draco attribute encoder {controller.decoderTypes[i]}"
      )
    mesh.attributes[attrId] = attr
    transformKinds[i] = controller.decoderTypes[i]

  for i, attrId in controller.attrIds:
    case transformKinds[i]
    of EncoderQuantization:
      quantData[i] = decodeQuantization(stream, mesh.attributes[attrId])
    of EncoderNormals:
      normalBits[i] = stream.readUint8().int
    else:
      discard

  for i, attrId in controller.attrIds:
    var attr = mesh.attributes[attrId]
    case transformKinds[i]
    of EncoderGeneric:
      discard
    of EncoderInteger:
      attr.storeIntegerAttribute()
    of EncoderQuantization:
      attr.storeQuantizedAttribute(
        quantData[i].minValues,
        quantData[i].range,
        quantData[i].bits
      )
    of EncoderNormals:
      attr.storeNormalAttribute(normalBits[i])
    else:
      discard
    mesh.attributes[attrId] = attr

proc decodeEdgebreakerAttributes*(
  stream: var DracoStream,
  state: var EdgebreakerMesh
) =
  ## Decodes all attributes for an edgebreaker mesh.
  let controllerCount = stream.readUint8().int
  var controllers = newSeq[AttributeController](controllerCount)
  for i in 0 ..< controllerCount:
    controllers[i] = readEdgebreakerController(stream, state, i)
  for i in 0 ..< controllerCount:
    decodeControllerData(stream, state.mesh, controllers[i])
  for i in 0 ..< controllerCount:
    when defined(dracoDebug):
      echo "Draco prepare controller=", i,
        " attrs=", controllers[i].attrIds.len,
        " element=", controllers[i].elementType,
        " encoding=", controllers[i].encodingKind
    controllers[i].prepareController(state.mesh, state)
    when defined(dracoDebug):
      echo "Draco decode controller=", i,
        " points=", controllers[i].pointIds.len
    decodeControllerAttributes(stream, state.mesh, state, controllers[i])

proc decodeSequentialAttributes*(
  stream: var DracoStream,
  mesh: var DracoMesh
) =
  ## Decodes all attributes for a sequential mesh.
  let controllerCount = stream.readUint8().int
  var controllers = newSeq[AttributeController](controllerCount)
  for i in 0 ..< controllerCount:
    controllers[i] = AttributeController(linear: true)
  for i in 0 ..< controllerCount:
    decodeControllerData(stream, mesh, controllers[i])
  var dummy = EdgebreakerMesh(mesh: mesh)
  for i in 0 ..< controllerCount:
    controllers[i].prepareController(mesh, dummy)
    decodeControllerAttributes(stream, mesh, dummy, controllers[i])
