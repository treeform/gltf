when defined(macosx):
  proc shaderFunction(renderer: Renderer, source, entry: string): MTLFunction =
    ## Compiles a Shady-generated entry and preserves compiler diagnostics.
    var
      error: NSError
      library = renderer.ctx.device.newLibraryWithSource(
        @source,
        0.ID,
        error.addr
      )
    if library.isNil:
      raise newException(GltfError, "Metal shader " & entry & ": " & $error)
    result = library.newFunctionWithName(@entry)
    library.freeMetal()
    checkNil(result, "Could not load a generated shader entry")

  proc pipeline(renderer: Renderer, vertex, fragment: MTLFunction,
      format: MTLPixelFormat, blended, background,
          post: bool): MTLRenderPipelineState =
    ## Creates a render pipeline around the shared generated shaders.
    var
      descriptor = MTLRenderPipelineDescriptor.alloc().init()
      error: NSError
    descriptor.setVertexFunction(vertex)
    descriptor.setFragmentFunction(fragment)
    let color = descriptor.colorAttachments().objectAtIndexedSubscript(0)
    color.setPixelFormat(format)
    if post:
      let vertexDescriptor = MTLVertexDescriptor.vertexDescriptor()
      vertexDescriptor.setAttribute(0, MTLVertexFormatFloat2, 0)
      let layout = vertexDescriptor.layouts().objectAtIndexedSubscript(MetalVertexBufferIndex)
      layout.setStride(8)
      layout.setStepFunction(MTLVertexStepFunctionPerVertex)
      descriptor.setVertexDescriptor(vertexDescriptor)
    else:
      descriptor.setVertexDescriptor(createVertexDescriptor())
      descriptor.setDepthAttachmentPixelFormat(MTLPixelFormatDepth32Float)
      if background:
        descriptor.setRasterSampleCount(4)
      else:
        descriptor.colorAttachments().objectAtIndexedSubscript(
            1).setPixelFormat(MTLPixelFormatR8Uint)
    if blended:
      color.setBlendingEnabled(true)
      color.setSourceRGBBlendFactor(MTLBlendFactorSourceAlpha)
      color.setDestinationRGBBlendFactor(MTLBlendFactorOneMinusSourceAlpha)
      color.setRgbBlendOperation(MTLBlendOperationAdd)
      color.setSourceAlphaBlendFactor(MTLBlendFactorOne)
      color.setDestinationAlphaBlendFactor(MTLBlendFactorOneMinusSourceAlpha)
      color.setAlphaBlendOperation(MTLBlendOperationAdd)
    result = renderer.ctx.device.newRenderPipelineStateWithDescriptor(
      descriptor,
      error.addr
    )
    descriptor.freeMetal()
    if result.isNil:
      raise newException(GltfError, "Metal pipeline: " & $error)

  proc iblPipeline(renderer: Renderer, key: string,
      bindings: seq[int]): MetalIblPipeline =
    ## Caches generated sampler configurations with bounded GPU ownership.
    for item in renderer.iblPipelines:
      if item.key == key:
        return item
    let source = shareMetalSamplers(shaderSources.IblFragMsl, bindings)
    var
      vertex = renderer.shaderFunction(PbrVertexShader, VertexEntryPoint)
      fragment = renderer.shaderFunction(source, FragmentEntryPoint)
    result.key = key
    result.opaque = renderer.pipeline(
      vertex,
      fragment,
      MTLPixelFormatRGBA16Float,
      false,
      false,
      false
    )
    result.blended = renderer.pipeline(
      vertex,
      fragment,
      MTLPixelFormatRGBA16Float,
      true,
      false,
      false
    )
    result.backgroundOpaque = renderer.pipeline(
      vertex,
      fragment,
      MTLPixelFormatRGBA8Unorm,
      false,
      true,
      false
    )
    result.backgroundBlended = renderer.pipeline(
      vertex,
      fragment,
      MTLPixelFormatRGBA8Unorm,
      true,
      true,
      false
    )
    vertex.freeMetal()
    fragment.freeMetal()
    if renderer.iblPipelines.len == 64:
      var oldest = renderer.iblPipelines[0]
      oldest.opaque.freeMetal()
      oldest.blended.freeMetal()
      oldest.backgroundOpaque.freeMetal()
      oldest.backgroundBlended.freeMetal()
      renderer.iblPipelines.delete(0)
    renderer.iblPipelines.add(result)

  proc ensureHdr(renderer: Renderer, width, height: int) =
    ## Allocates matching HDR, tone-flag, and presentation resources.
    renderer.ensureTargets(width, height)
    if renderer.hdrTexture.isNil:
      renderer.hdrTexture = renderer.createTarget(
        width,
        height,
        MTLPixelFormatRGBA16Float
      )
      renderer.flagTexture = renderer.createTarget(
        width,
        height,
        MTLPixelFormatR8Uint
      )
    if renderer.postPipeline.isNil:
      var
        vertex = renderer.shaderFunction(
          shaderSources.HdrPostVertMsl,
          VertexEntryPoint
        )
        fragment = renderer.shaderFunction(
          shaderSources.HdrPostFragMsl,
          FragmentEntryPoint
        )
      renderer.postPipeline = renderer.pipeline(
        vertex,
        fragment,
        MTLPixelFormatBGRA8Unorm,
        false,
        false,
        true
      )
      vertex.freeMetal()
      fragment.freeMetal()
      let vertices = [-1.0'f, -1.0'f, 3.0'f, -1.0'f, -1.0'f, 3.0'f]
      renderer.postVertices = renderer.uploadBuffer(vertices)

  proc retainFrame(renderer: Renderer, buffer: MTLBuffer) =
    ## Keeps a transient constant buffer alive until its command completes.
    renderer.frameResources.add(cast[NSObject](buffer))

  proc releaseFrame(renderer: Renderer) =
    ## Releases resources after the frame's GPU work has completed.
    for resource in renderer.frameResources:
      resource.release()
    renderer.frameResources.setLen(0)

  proc renderIblPrimitive(renderer: Renderer, encoder: MTLRenderCommandEncoder,
      entry: BlendEntry, ctx: PbrContext) =
    ## Binds shared shader data and draws one evaluated primitive.
    let
      primitive = entry.primitive
      material = primitive.material
    renderer.ensurePrimitive(primitive)
    renderer.prepareIblMaterial(material)
    let data = primitive.data
    if data == nil or data.vertexCount == 0:
      return
    let
      bindings = renderer.materialBindings(material)
      pipelines = renderer.iblPipeline(bindings.key, bindings.indices)
      blend = material.alphaMode == BlendAlphaMode or ctx.tint.a < 1
      pipeline = if ctx.transmissionBackground:
        (if blend: pipelines.backgroundBlended else: pipelines.backgroundOpaque)
        else: (if blend: pipelines.blended else: pipelines.opaque)
    encoder.setRenderPipelineState(pipeline)
    encoder.setDepthStencilState(if material.alphaMode == BlendAlphaMode:
      renderer.depthReadState else: renderer.depthState)
    encoder.setCullMode(if material.doubleSided: MTLCullModeNone else: MTLCullModeBack)
    let mirrored = dot(cross(entry.transform[0].xyz, entry.transform[1].xyz),
      entry.transform[2].xyz) < 0
    encoder.setFrontFacingWinding(if mirrored: MTLWindingClockwise else: MTLWindingCounterClockwise)
    let
      vertexBytes = shadyVertexConstants(
        entry.node,
        renderer.scene,
        entry.transform,
        ctx.view,
        ctx.proj
      )
      fragmentBytes = ctx.materialConstants(
        primitive,
        entry.transform,
        IblLayout
      )
      vertexBuffer = renderer.uploadBuffer(vertexBytes)
      fragmentBuffer = renderer.uploadBuffer(fragmentBytes)
    renderer.retainFrame(vertexBuffer)
    renderer.retainFrame(fragmentBuffer)
    encoder.setVertexBuffer(vertexBuffer, 0, 0)
    encoder.setFragmentBuffer(fragmentBuffer, 0, 1)
    encoder.setVertexBuffer(data.vertexBuffer, 0, MetalVertexBufferIndex)
    for i, name in IblTextureNames:
      let unit = IblSamplerNames.find(name)
      var texture = case unit
        of 5: ctx.iblEnvironment.specular
        of 7: ctx.iblEnvironment.diffuse
        of 8: ctx.iblEnvironment.lut
        of 9: ctx.iblEnvironment.charlie
        of 10: ctx.iblEnvironment.charlieLut
        of 11: ctx.iblEnvironment.sheenEnergyLut
        of 12:
          if ctx.transmissionBackground or renderer.transmissionTexture.isNil:
            renderer.whiteTexture
          else: renderer.transmissionTexture
        else:
          if material.data.iblTextures[unit] != nil:
            material.data.iblTextures[unit].texture
          else: renderer.whiteTexture
      encoder.setFragmentTexture(texture, i.uint)
    for i, sampler in bindings.states:
      encoder.setFragmentSamplerState(sampler, i.uint)
      renderer.frameResources.add(cast[NSObject](sampler))
    encoder.drawPrimitives(
      primitive.mode.metalPrimitive(),
      0,
      data.vertexCount.uint
    )

  proc collectEntries(node: Node, ctx: PbrContext,
      opaque, blended, transmitted: var seq[BlendEntry]) =
    ## Keeps opaque, blended and transmitted draws in explicit ordered lists.
    if node == nil or not node.visible:
      return
    if node.mesh != nil:
      for primitive in node.mesh.primitives:
        let entry = BlendEntry(
          node: node,
          primitive: primitive,
          transform: node.mat
        )
        if primitive.material.hasTransmission or
            primitive.material.transmissionFactor > 0:
            transmitted.add(entry)
        elif primitive.material.alphaMode == BlendAlphaMode or ctx.tint.a < 1:
          blended.add(entry)
        else:
          opaque.add(entry)
    for child in node.nodes:
      collectEntries(child, ctx, opaque, blended, transmitted)

  proc sortEntries(ctx: PbrContext, entries: var seq[BlendEntry]) =
    ## Sorts by indexed-vertex centroid in view space like the reference.
    var sorted: seq[tuple[depth: float32, entry: BlendEntry]]
    for entry in entries:
      let primitive = entry.primitive
      var
        center = vec3(0)
        count = 0
      if primitive.indices16.len > 0:
        for index in primitive.indices16:
          center += primitive.points[index]
        count = primitive.indices16.len
      elif primitive.indices32.len > 0:
        for index in primitive.indices32:
          center += primitive.points[index]
        count = primitive.indices32.len
      else:
        for point in primitive.points:
          center += point
        count = primitive.points.len
      if count > 0:
        center /= count.float32
      sorted.add(((ctx.view * entry.transform * vec4(center, 1)).z, entry))
    sorted.sort(proc(a, b: tuple[depth: float32, entry: BlendEntry]): int =
      ## Compares view-space depths with stable input order for ties.
      cmp(a.depth, b.depth))
    for i, item in sorted:
      entries[i] = item.entry

  proc beginIblPass(renderer: Renderer, command: MTLCommandBuffer,
      ctx: PbrContext, width, height: int,
          background: bool): MTLRenderCommandEncoder =
    ## Clears and begins the HDR pass or the multisampled transmission snapshot.
    let pass = MTLRenderPassDescriptor.renderPassDescriptor()
    let color = pass.colorAttachments().objectAtIndexedSubscript(0)
    color.setTexture(if background: renderer.transmissionMsaa else: renderer.hdrTexture)
    color.setLoadAction(MTLLoadActionClear)
    color.setStoreAction(if background: MTLStoreActionMultisampleResolve else: MTLStoreActionStore)
    if background:
      color.setResolveTexture(renderer.transmissionTexture)
    color.setClearColor(MTLClearColor(
      red: pow(ctx.clearColor.r.float64, 2.2),
      green: pow(ctx.clearColor.g.float64, 2.2),
      blue: pow(ctx.clearColor.b.float64, 2.2),
      alpha: ctx.clearColor.a.float64
    ))
    if not background:
      let flags = pass.colorAttachments().objectAtIndexedSubscript(1)
      flags.setTexture(renderer.flagTexture)
      flags.setLoadAction(MTLLoadActionClear)
      flags.setStoreAction(MTLStoreActionStore)
      flags.setClearColor(MTLClearColor(red: 1, green: 0, blue: 0, alpha: 0))
    let depth = pass.depthAttachment()
    depth.setTexture(if background: renderer.transmissionDepth else: renderer.depthTexture)
    depth.setLoadAction(MTLLoadActionClear)
    depth.setStoreAction(MTLStoreActionDontCare)
    depth.setClearDepth(1.0)
    result = command.renderCommandEncoderWithDescriptor(pass)
    result.setViewport(MTLViewport(
      originX: 0,
      originY: 0,
      width: width.float64,
      height: height.float64,
      znear: 0,
      zfar: 1
    ))

  proc encodeIbl(renderer: Renderer, command: MTLCommandBuffer,
      target: MTLTexture, width, height: int) =
    ## Renders a same-frame transmission snapshot, HDR scene, and tone mapping.
    let ctx = renderer.pbrContext
    renderer.ensureHdr(width, height)
    renderer.scene.updateTransforms(ctx.transform, ctx.useTrs)
    ctx.updatePunctualLights(renderer.scene)
    var opaque, blended, transmitted: seq[BlendEntry]
    collectEntries(renderer.scene, ctx, opaque, blended, transmitted)
    ctx.sortEntries(blended)
    ctx.sortEntries(transmitted)
    if transmitted.len > 0:
      if renderer.transmissionTexture.isNil:
        renderer.transmissionTexture = renderer.createTarget(
          1024,
          1024,
          MTLPixelFormatRGBA8Unorm,
          mipmapped = true
        )
        renderer.transmissionMsaa = renderer.createTarget(
          1024,
          1024,
          MTLPixelFormatRGBA8Unorm,
          samples = 4
        )
        renderer.transmissionDepth = renderer.createTarget(
          1024,
          1024,
          MTLPixelFormatDepth32Float,
          samples = 4
        )
      ctx.transmissionBackground = true
      let encoder = renderer.beginIblPass(command, ctx, 1024, 1024, true)
      for entry in opaque:
        renderer.renderIblPrimitive(encoder, entry, ctx)
      for entry in blended:
        renderer.renderIblPrimitive(encoder, entry, ctx)
      encoder.endEncoding()
      let blit = command.blitCommandEncoder()
      blit.generateMipmapsForTexture(renderer.transmissionTexture)
      blit.endEncoding()
      ctx.transmissionBackground = false
    let encoder = renderer.beginIblPass(command, ctx, width, height, false)
    for entries in [opaque, transmitted, blended]:
      for entry in entries:
        renderer.renderIblPrimitive(encoder, entry, ctx)
    encoder.endEncoding()
    let pass = MTLRenderPassDescriptor.renderPassDescriptor()
    let color = pass.colorAttachments().objectAtIndexedSubscript(0)
    color.setTexture(target)
    color.setLoadAction(MTLLoadActionDontCare)
    color.setStoreAction(MTLStoreActionStore)
    let post = command.renderCommandEncoderWithDescriptor(pass)
    post.setRenderPipelineState(renderer.postPipeline)
    post.setCullMode(MTLCullModeNone)
    post.setViewport(MTLViewport(
      originX: 0,
      originY: 0,
      width: width.float64,
      height: height.float64,
      znear: 0,
      zfar: 1
    ))
    post.setVertexBuffer(renderer.postVertices, 0, MetalVertexBufferIndex)
    var data = constants(metalUniformLayout(shaderSources.HdrPostFragMsl))
    data.put("exposure", ctx.exposure)
    data.put("renderTextureYFlip", true)
    post.setFragmentBytes(data.data[0].addr, data.data.len.uint, 1)
    post.setFragmentTexture(renderer.flagTexture, 0)
    post.setFragmentTexture(renderer.hdrTexture, 1)
    post.setFragmentSamplerState(renderer.sampler, 0)
    post.setFragmentSamplerState(renderer.sampler, 1)
    post.drawPrimitives(MTLPrimitiveTypeTriangle, 0, 3)
    post.endEncoding()

  proc attachIblEnvironment*(ctx: PbrContext, environment: IblEnvironment,
      owned = true) =
    ## Uses the shared filtered lighting profile for subsequent frames.
    if ctx.ownsIblEnvironment:
      ctx.iblEnvironment.destroy()
    ctx.iblEnvironment = environment
    ctx.ownsIblEnvironment = owned
    ctx.environmentMapStrength = environment.intensityScale

  proc beginIblFrame*(ctx: PbrContext) =
    ## Validates the environment before queuing the frame's scene.
    doAssert not ctx.iblEnvironment.specular.isNil

  proc endIblFrame*(ctx: PbrContext) =
    ## Leaves presentation to the renderer's explicit endFrame phase.
    discard ctx
