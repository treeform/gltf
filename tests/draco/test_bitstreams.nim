import
  gltf/draco/bitstreams,
  helpers

proc testByteReads() =
  ## Checks byte-aligned little-endian scalar decoding.
  var stream = initDracoStream("\x76\x54\x32\x10\x00\x00\x80hello")
  doAssert stream.remaining() == 12
  doAssert stream.readUint8() == 0x76'u8
  doAssert stream.readUint16() == 0x3254'u16
  doAssert stream.readUint32() == 0x80000010'u32
  doAssert stream.readString(5) == "hello"
  doAssert stream.remaining() == 0

  stream = initDracoStream("\x00\x00\x80\x3f")
  doAssert approx(stream.readFloat32(), 1.0'f)

  stream = initDracoStream("abcdef")
  stream.advance(2)
  var sub = stream.substream()
  doAssert sub.readBytes(4) == "cdef"

proc testVarints() =
  ## Checks Draco varint and signed varint decoding.
  var stream = initDracoStream("\x05")
  doAssert stream.readVarint() == 5'u32

  stream = initDracoStream("\x81\x01")
  doAssert stream.readVarint() == 129'u32

  stream = initDracoStream("\x02")
  doAssert stream.readSignedVarint() == 1'i32

  stream = initDracoStream("\x03")
  doAssert stream.readSignedVarint() == -2'i32

  stream = initDracoStream("\x80\x80\x80\x80\x80\x00")
  expectDracoError:
    discard stream.readVarint()

proc testAlignedBits() =
  ## Checks byte-aligned bit decoding in least-significant-bit order.
  var stream = initDracoStream("\x76\x54\x32\x10\x76\x54\x32\x10")
  discard stream.startBits(false)
  doAssert stream.readBits(16) == 0x5476'u32
  doAssert stream.readBits(16) == 0x1032'u32
  doAssert stream.readBits(16) == 0x5476'u32
  doAssert stream.readBits(16) == 0x1032'u32
  stream.endBits()
  doAssert stream.remaining() == 0

proc testUnalignedBits() =
  ## Checks sub-byte bit reads and byte cursor advancement.
  var stream = initDracoStream("\x76\x54\x32\x10")
  discard stream.startBits(false)
  doAssert stream.readBits(4) == 0x6'u32
  doAssert stream.readBits(4) == 0x7'u32
  doAssert stream.readBits(3) == 0x4'u32
  stream.endBits()
  doAssert stream.remaining() == 2

  stream = initDracoStream("\x03\x05")
  doAssert stream.startBits(true) == 3'u32
  doAssert stream.readBits(3) == 5'u32
  stream.endBits()
  doAssert stream.remaining() == 0

proc testSingleBits() =
  ## Checks one-bit reads across byte boundaries.
  var stream = initDracoStream("\xaa\xaa")
  discard stream.startBits(false)
  for i in 0 ..< 16:
    doAssert stream.readBits(1) == uint32(i mod 2)
  stream.endBits()
  doAssert stream.remaining() == 0

proc testBitErrors() =
  ## Checks bounds errors from bit and byte readers.
  var stream = initDracoStream("\x00")
  expectDracoError:
    discard stream.readUint16()

  stream = initDracoStream("\x00")
  expectDracoError:
    discard stream.readBits(1)

  discard stream.startBits(false)
  expectDracoError:
    discard stream.readBits(33)
  discard stream.readBits(8)
  expectDracoError:
    discard stream.readBits(1)

proc runBitstreamTests*() =
  ## Runs Draco bitstream tests.
  echo "Testing Draco bitstreams"
  testByteReads()
  testVarints()
  testAlignedBits()
  testUnalignedBits()
  testSingleBits()
  testBitErrors()
