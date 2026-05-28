## Backend selection helpers shared by tests and tools.

when defined(useDirectX) or defined(useVulkan):
  import windy

when defined(useDirectX):
  import ./directx/renderer as selectedBackend
elif defined(useVulkan):
  import ./vulkan/renderer as selectedBackend
elif defined(useMetal4):
  import ./metal/renderer as selectedBackend
else:
  import ./opengl/renderer as selectedBackend

export selectedBackend

type RenderBackend* = enum
  rbOpenGL = "OpenGL"
  rbDirectX = "DirectX"
  rbVulkan = "Vulkan"
  rbMetal = "Metal"

const
  ActiveBackend* =
    when defined(useDirectX):
      rbDirectX
    elif defined(useVulkan):
      rbVulkan
    elif defined(useMetal4):
      rbMetal
    else:
      rbOpenGL

  BackendName* = $ActiveBackend
  BackendUsesOpenGlRenderer* = ActiveBackend == rbOpenGL
  BackendHasNativeRenderer* = ActiveBackend in {rbOpenGL, rbDirectX, rbVulkan}
  VertexEntryPoint* = selectedBackend.VertexEntryPoint
  FragmentEntryPoint* = selectedBackend.FragmentEntryPoint

  PbrVertexShader* = selectedBackend.PbrVertexShader
  PbrFragmentShader* = selectedBackend.PbrFragmentShader
  SkyboxVertexShader* = selectedBackend.SkyboxVertexShader
  SkyboxFragmentShader* = selectedBackend.SkyboxFragmentShader
  ShadowDepthVertexShader* = selectedBackend.ShadowDepthVertexShader
  ShadowDepthFragmentShader* = selectedBackend.ShadowDepthFragmentShader

proc loadBackendExtensions*() =
  ## Loads graphics extensions when the selected backend needs an explicit load.
  when defined(useDirectX) or defined(useVulkan):
    windy.loadExtensions()
  elif defined(useMetal4):
    discard
  else:
    discard
