import
  gltf/dracos,
  helpers

proc testMalformedPayloads() =
  ## Checks public decoder errors for invalid Draco headers.
  expectDracoError:
    discard decodeDraco("", @[])
  expectDracoError:
    discard decodeDraco("NOPE!\x02\x02\x01\x00\x00\x00", @[])
  expectDracoError:
    discard decodeDraco("DRACO\x02\x03\x01\x00\x00\x00", @[])
  expectDracoError:
    discard decodeDraco("DRACO\x02\x02\x00\x00\x00\x00", @[])
  expectDracoError:
    discard decodeDraco("DRACO\x02\x02\x01\xff\x00\x00", @[])

proc runDecoderTests*() =
  ## Runs small Draco decoder payload tests.
  echo "Testing Draco decoders"
  testMalformedPayloads()
