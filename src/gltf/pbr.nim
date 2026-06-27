import common

when defined(useDirectX):
  import backends/directx/renderer as backendRenderer
elif defined(useVulkan):
  import backends/vulkan/renderer as backendRenderer
elif defined(useMetal4):
  import backends/metal/renderer as backendRenderer
else:
  import backends/opengl/renderer as backendRenderer

export
  common.DebugView,
  common.RenderParams,
  backendRenderer
