import
  std/os,
  common, models

proc loadDocument*(
  path: string,
  options = initLoadOptions()
): Document {.raises: [IOError, GltfError].} =
  ## Loads a glTF document from disk.
  discard options
  if not fileExists(path):
    raise newException(IOError, "File not found: " & path)
  raise newException(
    GltfError,
    "glTF loading is not implemented yet."
  )
