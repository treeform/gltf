type
  GltfError* = object of CatchableError

  GltfFormat* = enum
    gfJson,
    gfBinary

  LoadOptions* = object
    loadBuffers*: bool
    loadImages*: bool
    formatHint*: GltfFormat

proc initLoadOptions*(): LoadOptions =
  ## Returns default loading options.
  LoadOptions(
    loadBuffers: true,
    loadImages: true,
    formatHint: gfJson
  )
