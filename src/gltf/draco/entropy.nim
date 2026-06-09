import
  std/[strformat],
  bitstreams, types

const
  AnsP8Precision = 256'u32
  AnsLBase = 4096'u32
  AnsIoBase = 256'u32

type
  AnsDecoder = object
    data: string
    offset: int
    state: uint32

  RAnsDecoder = object
    precisionBits: int
    precision: uint32
    precisionMask: uint32
    lBase: uint32
    lut: seq[uint32]
    probs: seq[uint32]
    cumProbs: seq[uint32]
    ans: AnsDecoder

  RAnsSymbolDecoder = object
    symbolCount: int
    ans: RAnsDecoder

  RAnsBitDecoder* = object
    ans: AnsDecoder
    probZero: uint32
    p: uint32

proc byteAt(data: string, offset: int): uint32 =
  ## Reads a byte from a raw string.
  data[offset].uint32 and 0xff'u32

proc readLe16(data: string, offset: int): uint32 =
  ## Reads a little-endian 16-bit value from a raw string.
  byteAt(data, offset) or (byteAt(data, offset + 1) shl 8)

proc readLe24(data: string, offset: int): uint32 =
  ## Reads a little-endian 24-bit value from a raw string.
  readLe16(data, offset) or (byteAt(data, offset + 2) shl 16)

proc readLe32(data: string, offset: int): uint32 =
  ## Reads a little-endian 32-bit value from a raw string.
  readLe16(data, offset) or
    (byteAt(data, offset + 2) shl 16) or
    (byteAt(data, offset + 3) shl 24)

proc ansReadInit(
  ans: var AnsDecoder,
  data: string,
  encodedSize: int,
  lBase: uint32 = AnsLBase
) =
  ## Initializes an rANS state from encoded bytes.
  if encodedSize < 1 or encodedSize > data.len:
    raise newException(DracoError, "Invalid Draco rANS payload size")
  ans.data = data
  let mode = byteAt(data, encodedSize - 1) shr 6
  case mode
  of 0:
    ans.offset = encodedSize - 1
    ans.state = byteAt(data, encodedSize - 1) and 0x3f'u32
  of 1:
    if encodedSize < 2:
      raise newException(DracoError, "Invalid Draco rANS state")
    ans.offset = encodedSize - 2
    ans.state = readLe16(data, encodedSize - 2) and 0x3fff'u32
  of 2:
    if encodedSize < 3:
      raise newException(DracoError, "Invalid Draco rANS state")
    ans.offset = encodedSize - 3
    ans.state = readLe24(data, encodedSize - 3) and 0x3fffff'u32
  of 3:
    if encodedSize < 4:
      raise newException(DracoError, "Invalid Draco rANS state")
    ans.offset = encodedSize - 4
    ans.state = readLe32(data, encodedSize - 4) and 0x3fffffff'u32
  else:
    discard
  ans.state += lBase
  if ans.state >= lBase * AnsIoBase:
    raise newException(DracoError, "Invalid Draco rANS initial state")

proc renorm(ans: var AnsDecoder, lBase: uint32) =
  ## Renormalizes an rANS state.
  while ans.state < lBase and ans.offset > 0:
    dec ans.offset
    ans.state = ans.state * AnsIoBase + byteAt(ans.data, ans.offset)

proc rabsRead(ans: var AnsDecoder, p: uint32): bool =
  ## Reads one binary rANS symbol.
  ans.renorm(AnsLBase)
  let
    x = ans.state
    quot = x shr 8
    rem = x and 0xff'u32
    xn = quot * p
  if rem < p:
    ans.state = xn + rem
    true
  else:
    ans.state = x - xn - p
    false

proc initRAnsDecoder(bits: int): RAnsDecoder =
  ## Creates an rANS symbol decoder state.
  result.precisionBits = bits
  result.precision = 1'u32 shl bits
  result.precisionMask = result.precision - 1
  result.lBase = result.precision * 4

proc buildLookup(decoder: var RAnsDecoder, probs: seq[uint32]) =
  ## Builds an rANS lookup table.
  decoder.lut.setLen(decoder.precision.int)
  decoder.probs.setLen(probs.len)
  decoder.cumProbs.setLen(probs.len)
  var
    cumProb = 0'u32
    actProb = 0'u32
  for i, prob in probs:
    decoder.probs[i] = prob
    decoder.cumProbs[i] = cumProb
    cumProb += prob
    if cumProb > decoder.precision:
      raise newException(DracoError, "Invalid Draco rANS probability table")
    for j in actProb ..< cumProb:
      decoder.lut[j.int] = i.uint32
    actProb = cumProb
  if cumProb != decoder.precision:
    raise newException(DracoError, "Invalid Draco rANS precision sum")

proc ransRead(decoder: var RAnsDecoder): uint32 =
  ## Reads one rANS symbol.
  decoder.ans.renorm(decoder.lBase)
  let
    state = decoder.ans.state
    rem = state and decoder.precisionMask
    symbol = decoder.lut[rem.int]
  decoder.ans.state =
    (state shr decoder.precisionBits) *
    decoder.probs[symbol.int] +
    rem -
    decoder.cumProbs[symbol.int]
  symbol

proc precisionBits(uniqueSymbolsBitLength: int): int =
  ## Computes the rANS precision bits for an alphabet size.
  let value = (3 * uniqueSymbolsBitLength) div 2
  max(12, min(20, value))

proc createSymbolDecoder(
  stream: var DracoStream,
  uniqueSymbolsBitLength: int
): RAnsSymbolDecoder =
  ## Reads an rANS symbol probability table.
  result.ans = initRAnsDecoder(precisionBits(uniqueSymbolsBitLength))
  result.symbolCount = stream.readVarint().int
  if result.symbolCount div 64 > stream.remaining():
    raise newException(DracoError, "Invalid Draco symbol count")
  var
    probs = newSeq[uint32](result.symbolCount)
    i = 0
  while i < result.symbolCount:
    let probData = stream.readUint8()
    let token = probData and 3'u8
    if token == 3:
      let offset = (probData shr 2).int
      if i + offset >= result.symbolCount:
        raise newException(DracoError, "Invalid Draco zero probability run")
      for j in 0 .. offset:
        probs[i + j] = 0
      i += offset + 1
    else:
      var prob = (probData shr 2).uint32
      for b in 0 ..< token.int:
        prob = prob or (stream.readUint8().uint32 shl (8 * (b + 1) - 2))
      probs[i] = prob
      inc i
  if result.symbolCount > 0:
    result.ans.buildLookup(probs)

proc startSymbolDecoding(
  decoder: var RAnsSymbolDecoder,
  stream: var DracoStream
) =
  ## Starts an rANS symbol payload.
  let encodedSize = stream.readVarint().int
  if encodedSize > stream.remaining():
    raise newException(DracoError, "Invalid Draco symbol payload size")
  let data = stream.readBytes(encodedSize)
  ansReadInit(decoder.ans.ans, data, encodedSize, decoder.ans.lBase)

proc decodeSymbol(decoder: var RAnsSymbolDecoder): uint32 =
  ## Decodes one rANS symbol.
  decoder.ans.ransRead()

proc decodeTaggedSymbols(
  valueCount: int,
  componentCount: int,
  stream: var DracoStream,
  values: var seq[uint32]
) =
  ## Decodes tagged Draco symbols.
  var tagDecoder = stream.createSymbolDecoder(5)
  tagDecoder.startSymbolDecoding(stream)
  if valueCount > 0 and tagDecoder.symbolCount == 0:
    raise newException(DracoError, "Invalid Draco tag symbol table")
  discard stream.startBits(false)
  var valueId = 0
  var i = 0
  while i < valueCount:
    let bitLength = tagDecoder.decodeSymbol().int
    for j in 0 ..< componentCount:
      discard j
      values[valueId] = stream.readBits(bitLength)
      inc valueId
    i += componentCount
  stream.endBits()

proc decodeRawSymbols(
  valueCount: int,
  stream: var DracoStream,
  values: var seq[uint32]
) =
  ## Decodes raw Draco symbols.
  let maxBitLength = stream.readUint8().int
  if maxBitLength < 1 or maxBitLength > 18:
    raise newException(
      DracoError,
      &"Invalid Draco raw symbol bit length {maxBitLength}"
    )
  var decoder = stream.createSymbolDecoder(maxBitLength)
  if valueCount > 0 and decoder.symbolCount == 0:
    raise newException(DracoError, "Invalid Draco raw symbol table")
  decoder.startSymbolDecoding(stream)
  for i in 0 ..< valueCount:
    values[i] = decoder.decodeSymbol()

proc decodeSymbols*(
  valueCount: int,
  componentCount: int,
  stream: var DracoStream
): seq[uint32] =
  ## Decodes Draco entropy-coded symbols.
  result.setLen(valueCount)
  if valueCount == 0:
    return
  let scheme = stream.readUint8()
  case scheme
  of 0:
    decodeTaggedSymbols(valueCount, componentCount, stream, result)
  of 1:
    decodeRawSymbols(valueCount, stream, result)
  else:
    raise newException(DracoError, &"Invalid Draco symbol coding {scheme}")

proc startDecoding*(decoder: var RAnsBitDecoder, stream: var DracoStream) =
  ## Starts an rANS bit payload.
  decoder.probZero = stream.readUint8().uint32
  decoder.p = AnsP8Precision - decoder.probZero
  let encodedSize = stream.readVarint().int
  if encodedSize > stream.remaining():
    raise newException(DracoError, "Invalid Draco bit payload size")
  let data = stream.readBytes(encodedSize)
  decoder.ans.ansReadInit(data, encodedSize)

proc decodeBit*(decoder: var RAnsBitDecoder): bool =
  ## Decodes one rANS bit.
  decoder.ans.rabsRead(decoder.p)

proc decodeBits*(decoder: var RAnsBitDecoder, count: int): uint32 =
  ## Decodes several rANS bits into an integer.
  for i in 0 ..< count:
    discard i
    result = result shl 1
    if decoder.decodeBit():
      result += 1
