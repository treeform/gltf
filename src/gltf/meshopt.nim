## Pure Nim decoder for EXT_meshopt_compression.
##
## The bitstream decoder follows meshoptimizer by Arseny Kapoulkine, licensed
## under the MIT License: https://github.com/zeux/meshoptimizer
##
## Copyright (c) 2016-2026 Arseny Kapoulkine
##
## Permission is hereby granted, free of charge, to any person obtaining a copy
## of this software and associated documentation files (the "Software"), to deal
## in the Software without restriction, including without limitation the rights
## to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
## copies of the Software, and to permit persons to whom the Software is
## furnished to do so, subject to the following conditions:
##
## The above copyright notice and this permission notice shall be included in
## all copies or substantial portions of the Software.
##
## THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
## IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
## FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
## AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
## LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
## OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
## SOFTWARE.

import
  std/math,
  flatty/binny,
  common

const
  ByteGroupSize = 16
  ByteGroupDecodeLimit = 24
  VertexBlockSizeBytes = 8192
  VertexBlockMaxSize = 256

proc fail(message: string) {.noreturn.} =
  raise newException(GltfError, "Invalid EXT_meshopt_compression data: " & message)

proc byteAt(data: string, offset: int): uint8 =
  if offset < 0 or offset >= data.len:
    fail("truncated bitstream")
  data[offset].uint8

proc setByte(data: var string, offset: int, value: uint8) =
  data[offset] = char(value)

proc writeUint16(data: var string, offset: int, value: uint16) =
  data.setByte(offset, uint8(value and 0xff))
  data.setByte(offset + 1, uint8(value shr 8))

proc writeUint32(data: var string, offset: int, value: uint32) =
  data.setByte(offset, uint8(value and 0xff))
  data.setByte(offset + 1, uint8((value shr 8) and 0xff))
  data.setByte(offset + 2, uint8((value shr 16) and 0xff))
  data.setByte(offset + 3, uint8(value shr 24))

proc decodeByteGroup(
  data: string,
  offset: var int,
  bits: int,
  output: var array[ByteGroupSize, uint8]
) =
  if bits == 0:
    output = default(array[ByteGroupSize, uint8])
    return
  if bits == 8:
    for i in 0 ..< ByteGroupSize:
      output[i] = data.byteAt(offset + i)
    offset += ByteGroupSize
    return

  let
    packedSize = ByteGroupSize * bits div 8
    sentinel = uint8((1 shl bits) - 1)
  var literalOffset = offset + packedSize
  for i in 0 ..< ByteGroupSize:
    let
      packed = data.byteAt(offset + i * bits div 8)
      shift = 8 - bits - (i * bits mod 8)
      encoded = (packed shr shift) and sentinel
    if encoded == sentinel:
      output[i] = data.byteAt(literalOffset)
      inc literalOffset
    else:
      output[i] = encoded
  offset = literalOffset

proc decodeByteStream(
  data: string,
  offset: var int,
  outputSize: int
): seq[uint8] =
  let
    groupCount = outputSize div ByteGroupSize
    headerSize = (groupCount + 3) div 4
    headerOffset = offset
  if outputSize mod ByteGroupSize != 0:
    fail("unaligned attribute block")
  if data.len - offset < headerSize:
    fail("truncated attribute header")
  offset += headerSize
  result.setLen(outputSize)
  for group in 0 ..< groupCount:
    if data.len - offset < ByteGroupDecodeLimit:
      fail("truncated attribute group")
    let
      code = (data.byteAt(headerOffset + group div 4) shr
        ((group mod 4) * 2)) and 3
      bits = [0, 2, 4, 8][code]
    var decoded: array[ByteGroupSize, uint8]
    decodeByteGroup(data, offset, bits, decoded)
    for i in 0 ..< ByteGroupSize:
      result[group * ByteGroupSize + i] = decoded[i]

proc unzigzag(value: uint8): uint8 =
  (0'u8 - (value and 1)) xor (value shr 1)

proc addWrap(a, b: uint32): uint32 =
  uint32((a.uint64 + b.uint64) and uint32.high.uint64)

proc addWrap(a: uint32, b: int): uint32 =
  uint32((a.int64 + b.int64) and uint32.high.int64)

proc vertexBlockSize(stride: int): int =
  min((VertexBlockSizeBytes div stride) and not 15, VertexBlockMaxSize)

proc decodeAttributes(data: string, count, stride: int): string =
  if stride <= 0 or stride > 256 or stride mod 4 != 0:
    fail("invalid attribute stride")
  if data.len < 1 or data.byteAt(0) != 0xa0:
    fail("invalid attribute header")

  let
    tailSize = max(32, stride)
    blockCapacity = vertexBlockSize(stride)
  if count < 0 or blockCapacity <= 0 or data.len - 1 < tailSize:
    fail("invalid attribute stream size")

  result = newString(count * stride)
  var
    offset = 1
    vertexOffset = 0
    lastVertex = newSeq[uint8](stride)
  for i in 0 ..< stride:
    lastVertex[i] = data.byteAt(data.len - stride + i)

  while vertexOffset < count:
    let
      blockCount = min(blockCapacity, count - vertexOffset)
      alignedCount = (blockCount + ByteGroupSize - 1) and
        not (ByteGroupSize - 1)
    for component in 0 ..< stride:
      let deltas = decodeByteStream(data, offset, alignedCount)
      var previous = lastVertex[component]
      for vertex in 0 ..< blockCount:
        previous = uint8(
          (previous.uint16 + unzigzag(deltas[vertex]).uint16) and 0xff
        )
        result.setByte(
          (vertexOffset + vertex) * stride + component,
          previous
        )
      lastVertex[component] = previous
    vertexOffset += blockCount

  if data.len - offset != tailSize:
    fail(
      "attribute stream has " & $(data.len - offset - tailSize) &
      " trailing bytes"
    )

proc decodeVByte(data: string, offset: var int, limit: int): uint32 =
  if offset >= limit:
    fail("truncated index stream at byte " & $offset)
  let lead = data.byteAt(offset)
  inc offset
  if lead < 128:
    return lead.uint32

  result = uint32(lead and 127)
  var shift = 7
  for _ in 0 ..< 4:
    if offset >= limit:
      fail("truncated index stream at byte " & $offset)
    let group = data.byteAt(offset)
    inc offset
    result = result or (uint32(group and 127) shl shift)
    shift += 7
    if group < 128:
      return

proc decodeIndex(data: string, offset: var int, limit: int, last: uint32): uint32 =
  let
    value = decodeVByte(data, offset, limit)
    delta = (value shr 1) xor (0'u32 - (value and 1))
  addWrap(last, delta)

proc writeIndex(data: var string, index, stride: int, value: uint32) =
  if stride == 2:
    if value > uint16.high.uint32:
      fail("index exceeds uint16")
    data.writeUint16(index * stride, value.uint16)
  else:
    data.writeUint32(index * stride, value)

proc pushVertex(
  fifo: var array[16, uint32],
  offset: var int,
  value: uint32,
  advance = true
) =
  fifo[offset] = value
  if advance:
    offset = (offset + 1) and 15

proc pushEdge(
  fifo: var array[16, array[2, uint32]],
  offset: var int,
  a, b: uint32
) =
  fifo[offset] = [a, b]
  offset = (offset + 1) and 15

proc decodeTriangles(data: string, count, stride: int): string =
  if count < 0 or count mod 3 != 0:
    fail("invalid triangle count")
  if stride notin [2, 4]:
    fail("invalid triangle stride")
  let triangleCount = count div 3
  if data.len < 1 + triangleCount + 16:
    fail("truncated triangle stream")
  if (data.byteAt(0) and 0xf0) != 0xe0:
    fail("invalid triangle header")
  let version = int(data.byteAt(0) and 0x0f)
  if version > 1:
    fail("unsupported triangle version")

  var
    edgeFifo: array[16, array[2, uint32]]
    vertexFifo: array[16, uint32]
  for i in 0 ..< 16:
    edgeFifo[i] = [uint32.high, uint32.high]
    vertexFifo[i] = uint32.high

  let
    codeEnd = 1 + triangleCount
    dataEnd = data.len - 16
    fecMax = if version >= 1: 13 else: 15
  var
    codeOffset = 1
    dataOffset = codeEnd
    edgeOffset = 0
    vertexOffset = 0
    next = 0'u32
    last = 0'u32
    outputIndex = 0
  result = newString(count * stride)

  while codeOffset < codeEnd:
    let code = data.byteAt(codeOffset)
    inc codeOffset
    var a, b, c: uint32
    if code < 0xf0:
      let
        fe = int(code shr 4)
        fec = int(code and 15)
      a = edgeFifo[(edgeOffset - 1 - fe) and 15][0]
      b = edgeFifo[(edgeOffset - 1 - fe) and 15][1]
      if fec < fecMax:
        c = if fec == 0: next else:
          vertexFifo[(vertexOffset - 1 - fec) and 15]
        if fec == 0:
          inc next
          pushVertex(vertexFifo, vertexOffset, c)
      else:
        if fec != 15:
          last = addWrap(last, fec * 2 - 27)
        else:
          last = decodeIndex(data, dataOffset, dataEnd, last)
        c = last
        pushVertex(vertexFifo, vertexOffset, c)
      pushEdge(edgeFifo, edgeOffset, c, b)
      pushEdge(edgeFifo, edgeOffset, a, c)
    else:
      let codeAux =
        if code < 0xfe:
          data.byteAt(dataEnd + int(code and 15))
        else:
          if dataOffset >= dataEnd:
            fail("truncated triangle data")
          let value = data.byteAt(dataOffset)
          inc dataOffset
          value
      let
        fea = if code == 0xff: 15 else: 0
        feb = int(codeAux shr 4)
        fec = int(codeAux and 15)
      if code >= 0xfe and codeAux == 0:
        next = 0
      a = if fea == 0: next else: 0
      if fea == 0:
        inc next
      b = if feb == 0: next else:
        vertexFifo[(vertexOffset - feb) and 15]
      if feb == 0:
        inc next
      c = if fec == 0: next else:
        vertexFifo[(vertexOffset - fec) and 15]
      if fec == 0:
        inc next
      if fea == 15:
        last = decodeIndex(data, dataOffset, dataEnd, last)
        a = last
      if feb == 15:
        last = decodeIndex(data, dataOffset, dataEnd, last)
        b = last
      if fec == 15:
        last = decodeIndex(data, dataOffset, dataEnd, last)
        c = last
      pushVertex(vertexFifo, vertexOffset, a)
      pushVertex(vertexFifo, vertexOffset, b, feb in [0, 15])
      pushVertex(vertexFifo, vertexOffset, c, fec in [0, 15])
      pushEdge(edgeFifo, edgeOffset, b, a)
      pushEdge(edgeFifo, edgeOffset, c, b)
      pushEdge(edgeFifo, edgeOffset, a, c)

    result.writeIndex(outputIndex, stride, a)
    result.writeIndex(outputIndex + 1, stride, b)
    result.writeIndex(outputIndex + 2, stride, c)
    outputIndex += 3

  if dataOffset != dataEnd:
    fail("triangle stream has trailing data")

proc decodeIndices(data: string, count, stride: int): string =
  if count < 0 or stride notin [2, 4]:
    fail("invalid index sequence layout")
  if data.len < 1 + count + 4:
    fail("truncated index sequence")
  if (data.byteAt(0) and 0xf0) != 0xd0:
    fail("invalid index sequence header")
  if (data.byteAt(0) and 0x0f) > 1:
    fail("unsupported index sequence version")

  let dataEnd = data.len - 4
  var
    offset = 1
    last = [0'u32, 0'u32]
  result = newString(count * stride)
  for i in 0 ..< count:
    var value = decodeVByte(data, offset, dataEnd)
    let current = int(value and 1)
    value = value shr 1
    let delta = (value shr 1) xor (0'u32 - (value and 1))
    let index = addWrap(last[current], delta)
    last[current] = index
    result.writeIndex(i, stride, index)
  if offset != dataEnd:
    fail("index sequence has trailing data")

proc roundedInt(value: float32): int32 =
  int32(value + (if value >= 0: 0.5'f32 else: -0.5'f32))

proc decodeOctahedral(data: var string, count, stride: int) =
  if stride notin [4, 8]:
    fail("invalid octahedral stride")
  let maximum = if stride == 4: 127.0'f32 else: 32767.0'f32
  for i in 0 ..< count:
    let offset = i * stride
    var x, y, z: float32
    if stride == 4:
      x = cast[int8](data.byteAt(offset)).float32
      y = cast[int8](data.byteAt(offset + 1)).float32
      z = cast[int8](data.byteAt(offset + 2)).float32
    else:
      x = cast[int16](data.readUint16(offset)).float32
      y = cast[int16](data.readUint16(offset + 2)).float32
      z = cast[int16](data.readUint16(offset + 4)).float32
    z -= abs(x) + abs(y)
    let correction = min(z, 0.0'f32)
    x += (if x >= 0: correction else: -correction)
    y += (if y >= 0: correction else: -correction)
    let scale = maximum / sqrt(x * x + y * y + z * z)
    if stride == 4:
      data.setByte(offset, cast[uint8](roundedInt(x * scale).int8))
      data.setByte(offset + 1, cast[uint8](roundedInt(y * scale).int8))
      data.setByte(offset + 2, cast[uint8](roundedInt(z * scale).int8))
    else:
      data.writeUint16(offset, cast[uint16](roundedInt(x * scale).int16))
      data.writeUint16(offset + 2, cast[uint16](roundedInt(y * scale).int16))
      data.writeUint16(offset + 4, cast[uint16](roundedInt(z * scale).int16))

proc decodeQuaternion(data: var string, count, stride: int) =
  if stride != 8:
    fail("invalid quaternion stride")
  let scale = 32767.0'f32 / sqrt(2.0'f32)
  for i in 0 ..< count:
    let offset = i * stride
    var values: array[4, int16]
    for component in 0 ..< 4:
      values[component] = cast[int16](data.readUint16(offset + component * 2))
    let
      sf = values[3].int32 or 3
      s = sf.float32
      x = values[0].float32
      y = values[1].float32
      z = values[2].float32
      square = max(s * s * 2.0'f32 - x * x - y * y - z * z, 0.0'f32)
      w = sqrt(square)
      finalScale = scale / s
      decoded = [
        roundedInt(x * finalScale).int16,
        roundedInt(y * finalScale).int16,
        roundedInt(z * finalScale).int16,
        roundedInt(w * finalScale).int16
      ]
      largest = values[3].int and 3
    for component in 0 ..< 4:
      data.writeUint16(
        offset + ((largest + component + 1) and 3) * 2,
        cast[uint16](decoded[component])
      )

proc decodeExponential(data: var string, count, stride: int) =
  if stride <= 0 or stride mod 4 != 0:
    fail("invalid exponential stride")
  for offset in countup(0, count * stride - 4, 4):
    let value = data.readUint32(offset)
    var mantissa = int32(value and 0x00ffffff)
    if (value and 0x00800000) != 0:
      mantissa -= 1 shl 24
    let
      exponent = cast[int8](uint8(value shr 24)).int
      scale = cast[float32](uint32(exponent + 127) shl 23)
    data.writeUint32(
      offset,
      cast[uint32](scale * mantissa.float32)
    )

proc decodeMeshopt*(
  data: string,
  count, stride: int,
  mode, filter: string
): string =
  ## Decodes one EXT_meshopt_compression buffer view.
  if mode != "ATTRIBUTES" and filter notin ["", "NONE"]:
    fail("index modes do not support filters")
  case mode
  of "ATTRIBUTES":
    result = decodeAttributes(data, count, stride)
  of "TRIANGLES":
    result = decodeTriangles(data, count, stride)
  of "INDICES":
    result = decodeIndices(data, count, stride)
  else:
    fail("unsupported mode " & mode)

  case filter
  of "", "NONE":
    discard
  of "OCTAHEDRAL":
    decodeOctahedral(result, count, stride)
  of "QUATERNION":
    decodeQuaternion(result, count, stride)
  of "EXPONENTIAL":
    decodeExponential(result, count, stride)
  else:
    fail("unsupported filter " & filter)
