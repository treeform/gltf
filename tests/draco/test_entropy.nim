import
  gltf/draco/bitstreams,
  gltf/draco/entropy {.all.},
  helpers

proc testPrecisionBits() =
  ## Checks rANS precision selection from alphabet bit lengths.
  doAssert precisionBits(0) == 12
  doAssert precisionBits(8) == 12
  doAssert precisionBits(14) == 20
  doAssert precisionBits(30) == 20

proc testLookupTable() =
  ## Checks rANS lookup table construction and validation.
  var decoder = initRAnsDecoder(12)
  decoder.buildLookup(@[2048'u32, 2048'u32])

  decoder = initRAnsDecoder(12)
  expectDracoError:
    decoder.buildLookup(@[1'u32])

  decoder = initRAnsDecoder(12)
  expectDracoError:
    decoder.buildLookup(@[4097'u32])

proc testDecodeSymbolsErrors() =
  ## Checks entropy decoder empty and malformed symbol streams.
  var stream = initDracoStream("")
  doAssert decodeSymbols(0, 1, stream).len == 0

  stream = initDracoStream("\x02")
  expectDracoError:
    discard decodeSymbols(1, 1, stream)

  stream = initDracoStream("\x01\x00")
  expectDracoError:
    discard decodeSymbols(1, 1, stream)

proc testBitDecoderErrors() =
  ## Checks malformed rANS bit payloads.
  var
    decoder: RAnsBitDecoder
    stream = initDracoStream("\x80\x02")
  expectDracoError:
    decoder.startDecoding(stream)

  stream = initDracoStream("\x80\x00")
  expectDracoError:
    decoder.startDecoding(stream)

proc runEntropyTests*() =
  ## Runs Draco entropy tests.
  echo "Testing Draco entropy"
  testPrecisionBits()
  testLookupTable()
  testDecodeSymbolsErrors()
  testBitDecoderErrors()
