import
  std/[strformat],
  types

type
  BitDecoder = object
    data: string
    byteOffset: int
    byteLength: int
    bitOffset: int

  DracoStream* = object
    data*: string
    pos*: int
    bitstreamVersion*: int
    bitMode: bool
    bits: BitDecoder

proc initDracoStream*(data: string): DracoStream =
  ## Creates a decoder stream over a byte string.
  DracoStream(data: data)

proc remaining*(stream: DracoStream): int =
  ## Returns the unread byte count.
  stream.data.len - stream.pos

proc requireBytes(stream: DracoStream, count: int) =
  ## Raises when the stream cannot provide the requested bytes.
  if count < 0 or stream.pos + count > stream.data.len:
    raise newException(DracoError, "Unexpected end of Draco payload")

proc readUint8*(stream: var DracoStream): uint8 =
  ## Reads an unsigned byte.
  stream.requireBytes(1)
  result = stream.data[stream.pos].uint8
  inc stream.pos

proc readInt8*(stream: var DracoStream): int8 =
  ## Reads a signed byte.
  cast[int8](stream.readUint8())

proc readUint16*(stream: var DracoStream): uint16 =
  ## Reads an unsigned little-endian 16-bit integer.
  stream.requireBytes(2)
  result =
    stream.data[stream.pos].uint16 or
    (stream.data[stream.pos + 1].uint16 shl 8)
  stream.pos += 2

proc readInt16*(stream: var DracoStream): int16 =
  ## Reads a signed little-endian 16-bit integer.
  cast[int16](stream.readUint16())

proc readUint32*(stream: var DracoStream): uint32 =
  ## Reads an unsigned little-endian 32-bit integer.
  stream.requireBytes(4)
  result =
    stream.data[stream.pos].uint32 or
    (stream.data[stream.pos + 1].uint32 shl 8) or
    (stream.data[stream.pos + 2].uint32 shl 16) or
    (stream.data[stream.pos + 3].uint32 shl 24)
  stream.pos += 4

proc readInt32*(stream: var DracoStream): int32 =
  ## Reads a signed little-endian 32-bit integer.
  cast[int32](stream.readUint32())

proc readFloat32*(stream: var DracoStream): float32 =
  ## Reads a little-endian float32.
  let bits = stream.readUint32()
  cast[float32](bits)

proc readString*(stream: var DracoStream, count: int): string =
  ## Reads a fixed number of bytes as a string.
  stream.requireBytes(count)
  result = stream.data[stream.pos ..< stream.pos + count]
  stream.pos += count

proc readBytes*(stream: var DracoStream, count: int): string =
  ## Reads a fixed number of raw bytes.
  stream.readString(count)

proc advance*(stream: var DracoStream, count: int) =
  ## Advances the byte cursor.
  stream.requireBytes(count)
  stream.pos += count

proc readVarint*(stream: var DracoStream): uint32 =
  ## Reads a Draco varint value.
  var
    chunks: seq[uint32]
    done = false
  while not done:
    let byte = stream.readUint8()
    chunks.add((byte and 0x7f'u8).uint32)
    done = (byte and 0x80'u8) == 0
    if chunks.len > 5:
      raise newException(DracoError, "Invalid Draco varint")
  for i in countdown(chunks.len - 1, 0):
    result = result * 128'u32 + chunks[i]

proc readSignedVarint*(stream: var DracoStream): int32 =
  ## Reads a zig-zag encoded signed Draco varint value.
  let value = stream.readVarint()
  if (value and 1) != 0:
    result = -int32(value shr 1) - 1
  else:
    result = int32(value shr 1)

proc startBits*(stream: var DracoStream, decodeSize: bool): uint32 =
  ## Starts LSB-first bit decoding at the current byte position.
  if decodeSize:
    result = stream.readVarint()
  stream.bitMode = true
  stream.bits = BitDecoder(
    data: stream.data,
    byteOffset: stream.pos,
    byteLength: stream.remaining()
  )

proc readBits*(stream: var DracoStream, count: int): uint32 =
  ## Reads up to 32 bits in least-significant-bit order.
  if not stream.bitMode:
    raise newException(DracoError, "Draco bit decoder is not active")
  if count < 0 or count > 32:
    raise newException(DracoError, &"Invalid Draco bit count {count}")
  var
    bitsRead = 0
    offset = stream.bits.bitOffset
  while bitsRead < count:
    let byteIndex = offset shr 3
    if byteIndex >= stream.bits.byteLength:
      raise newException(DracoError, "Unexpected end of Draco bitstream")
    let
      bitShift = offset and 7
      bitsAvail = 8 - bitShift
      bitsNeed = count - bitsRead
      bitsTake = min(bitsAvail, bitsNeed)
      mask = (1'u32 shl bitsTake) - 1
      byte = stream.bits.data[
        stream.bits.byteOffset + byteIndex
      ].uint32
    result = result or (((byte shr bitShift) and mask) shl bitsRead)
    bitsRead += bitsTake
    offset += bitsTake
  stream.bits.bitOffset = offset

proc endBits*(stream: var DracoStream) =
  ## Ends bit decoding and advances to the next unread byte.
  if not stream.bitMode:
    return
  let bytesRead = (stream.bits.bitOffset + 7) div 8
  stream.pos = stream.bits.byteOffset + bytesRead
  stream.bitMode = false

proc substream*(stream: DracoStream): DracoStream =
  ## Creates a stream from the unread bytes of another stream.
  result = initDracoStream(stream.data[stream.pos ..< stream.data.len])
  result.bitstreamVersion = stream.bitstreamVersion
