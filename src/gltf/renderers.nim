import
  common, models

type
  RendererConfig* = object
    usePbr*: bool
    loadEnvironment*: bool

proc initRendererConfig*(): RendererConfig =
  ## Returns default renderer settings.
  RendererConfig(
    usePbr: true,
    loadEnvironment: true
  )

proc prepareRenderer*(
  document: Document,
  config = initRendererConfig()
): void {.raises: [GltfError].} =
  ## Prepares renderer state for a document.
  discard document
  discard config
  raise newException(
    GltfError,
    "Renderer support is not implemented yet."
  )
