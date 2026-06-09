import
  std/[tables],
  bitstreams, entropy, types

const
  InvalidCorner = -1
  InvalidVertex = -1
  TopologyC = 0
  TopologyS = 1
  TopologyL = 3
  TopologyR = 5
  TopologyE = 7
  TopologyInvalid = 9
  RightFaceEdge = 1
  EdgeSymbolToTopology = [TopologyC, TopologyS, TopologyL, TopologyR, TopologyE]

type
  CornerTable* = object
    faceCount*: int
    cornerToVertex*: seq[int]
    opposites*: seq[int]
    vertexCorners*: seq[int]
    vertexCount*: int

  AttributeCornerTable* = object
    edgeOnSeam*: seq[uint8]
    vertexOnSeam*: seq[uint8]
    cornerToVertex*: seq[int]
    vertexLeftmost*: seq[int]
    vertexParents*: seq[int]
    effectiveOpposites*: seq[int]

  EncodingData* = object
    vertexToValue*: seq[int]
    valueToCorner*: seq[int]
    valueCount*: int

  AttributeData* = object
    decoderId*: int
    connectivity*: AttributeCornerTable
    connectivityUsed*: bool
    encoding*: EncodingData
    seamCorners*: seq[int]

  TopologySplit = object
    splitSymbolId: int
    sourceSymbolId: int
    sourceEdge: int

  TraversalDecoder = object
    kind: int
    symbolStream: DracoStream
    startFaces: RAnsBitDecoder
    attrSeams: seq[RAnsBitDecoder]
    activeContext: int
    lastSymbol: int
    minValence: int
    maxValence: int
    vertexValences: seq[int]
    contextSymbols: seq[seq[uint32]]
    contextCounters: seq[int]

  EdgebreakerMesh* = object
    mesh*: DracoMesh
    cornerTable*: CornerTable
    attributeData*: seq[AttributeData]
    posEncoding*: EncodingData
    posDataDecoderId*: int

proc fillSeq(values: var seq[int], value: int) =
  ## Fills an integer sequence with a repeated value.
  for i in 0 ..< values.len:
    values[i] = value

template debugDraco(message: string) =
  ## Prints Draco mesh decoder debug output when enabled.
  when defined(dracoDebug):
    echo message

proc reset(table: var CornerTable, faceCount, vertexCapacity: int) =
  ## Resets a corner table to invalid connectivity.
  table.faceCount = faceCount
  table.cornerToVertex.setLen(faceCount * 3)
  table.opposites.setLen(faceCount * 3)
  table.vertexCorners.setLen(vertexCapacity)
  table.vertexCount = 0
  table.cornerToVertex.fillSeq(InvalidVertex)
  table.opposites.fillSeq(InvalidCorner)
  table.vertexCorners.fillSeq(InvalidCorner)

proc cornerCount*(table: CornerTable): int =
  ## Returns the number of corners in the table.
  table.cornerToVertex.len

proc nextCorner*(corner: int): int =
  ## Returns the next corner on the same triangle.
  if corner < 0:
    return InvalidCorner
  let rem = corner mod 3
  if rem == 2:
    corner - 2
  else:
    corner + 1

proc previousCorner*(corner: int): int =
  ## Returns the previous corner on the same triangle.
  if corner < 0:
    return InvalidCorner
  let rem = corner mod 3
  if rem == 0:
    corner + 2
  else:
    corner - 1

proc face*(corner: int): int =
  ## Returns the triangle id for a corner.
  if corner < 0:
    return -1
  corner div 3

proc vertex*(table: CornerTable, corner: int): int =
  ## Returns the vertex mapped to a corner.
  if corner < 0 or corner >= table.cornerToVertex.len:
    return InvalidVertex
  table.cornerToVertex[corner]

proc opposite*(table: CornerTable, corner: int): int =
  ## Returns the opposite corner across an edge.
  if corner < 0 or corner >= table.opposites.len:
    return InvalidCorner
  table.opposites[corner]

proc leftMostCorner*(table: CornerTable, vertex: int): int =
  ## Returns a representative corner for a vertex.
  if vertex < 0 or vertex >= table.vertexCount:
    return InvalidCorner
  table.vertexCorners[vertex]

proc setLeftMostCorner(table: var CornerTable, vertex, corner: int) =
  ## Stores a representative corner for a vertex.
  if vertex >= 0 and vertex < table.vertexCorners.len:
    table.vertexCorners[vertex] = corner

proc addNewVertex(table: var CornerTable): int =
  ## Adds one vertex to a corner table.
  result = table.vertexCount
  inc table.vertexCount
  if result >= table.vertexCorners.len:
    table.vertexCorners.setLen(table.vertexCorners.len + 64)
    for i in result ..< table.vertexCorners.len:
      table.vertexCorners[i] = InvalidCorner
  table.vertexCorners[result] = InvalidCorner

proc makeVertexIsolated(table: var CornerTable, vertex: int) =
  ## Marks a corner-table vertex as isolated.
  if vertex >= 0 and vertex < table.vertexCount:
    table.vertexCorners[vertex] = InvalidCorner

proc swingLeft*(table: CornerTable, corner: int): int =
  ## Moves counter-clockwise around a vertex.
  let opp = table.opposite(corner.nextCorner())
  if opp < 0:
    return InvalidCorner
  opp.nextCorner()

proc swingRight*(table: CornerTable, corner: int): int =
  ## Moves clockwise around a vertex.
  let opp = table.opposite(corner.previousCorner())
  if opp < 0:
    return InvalidCorner
  opp.previousCorner()

proc addSeamEdge(
  attr: var AttributeCornerTable,
  table: CornerTable,
  corner: int
) =
  ## Adds a seam edge to an attribute corner table.
  if corner < 0:
    return
  attr.edgeOnSeam[corner] = 1
  attr.vertexOnSeam[table.vertex(corner.nextCorner())] = 1
  attr.vertexOnSeam[table.vertex(corner.previousCorner())] = 1
  let opp = table.opposite(corner)
  if opp != InvalidCorner:
    attr.edgeOnSeam[opp] = 1
    attr.vertexOnSeam[table.vertex(opp.nextCorner())] = 1
    attr.vertexOnSeam[table.vertex(opp.previousCorner())] = 1

proc seamOpposite(
  attr: AttributeCornerTable,
  table: CornerTable,
  corner: int
): int =
  ## Returns an opposite corner while honoring seam edges.
  if corner < 0 or attr.edgeOnSeam[corner] != 0:
    return InvalidCorner
  table.opposite(corner)

proc rebuildEffectiveOpposites(
  attr: var AttributeCornerTable,
  table: CornerTable
) =
  ## Rebuilds seam-aware opposite corners for traversal.
  attr.effectiveOpposites.setLen(table.cornerCount())
  for c in 0 ..< table.cornerCount():
    attr.effectiveOpposites[c] =
      if attr.edgeOnSeam[c] != 0:
        InvalidCorner
      else:
        table.opposite(c)

proc recomputeVertices(
  attr: var AttributeCornerTable,
  table: CornerTable
) =
  ## Recomputes attribute vertices from seam edges.
  let
    cornerCount = table.cornerCount()
    baseVertices = table.vertexCount
  attr.cornerToVertex.setLen(cornerCount)
  attr.cornerToVertex.fillSeq(InvalidVertex)
  attr.vertexParents.setLen(cornerCount)
  attr.vertexLeftmost.setLen(cornerCount)
  attr.rebuildEffectiveOpposites(table)
  var newVertexCount = 0
  for v in 0 ..< baseVertices:
    let c = table.leftMostCorner(v)
    if c == InvalidCorner:
      continue
    var
      firstVertex = newVertexCount
      firstCorner = c
    inc newVertexCount
    attr.vertexParents[firstVertex] = firstVertex
    if attr.vertexOnSeam[v] != 0:
      var active = firstCorner
      while true:
        let opp = attr.seamOpposite(table, active.nextCorner())
        if opp == InvalidCorner:
          break
        active = opp.nextCorner()
        if active == c:
          raise newException(DracoError, "Invalid Draco attribute seam ring")
        firstCorner = active
    attr.cornerToVertex[firstCorner] = firstVertex
    attr.vertexLeftmost[firstVertex] = firstCorner
    var active = firstCorner
    while true:
      let baseOpp = table.opposite(active.previousCorner())
      if baseOpp == InvalidCorner:
        break
      active = baseOpp.previousCorner()
      if active == firstCorner:
        break
      if attr.edgeOnSeam[active.nextCorner()] != 0:
        firstVertex = newVertexCount
        inc newVertexCount
        attr.vertexParents[firstVertex] = firstVertex
        attr.vertexLeftmost[firstVertex] = active
      attr.cornerToVertex[active] = firstVertex
  attr.vertexParents.setLen(newVertexCount)
  attr.vertexLeftmost.setLen(newVertexCount)

proc initAttributeCornerTable(table: CornerTable): AttributeCornerTable =
  ## Creates an empty attribute corner table.
  result.edgeOnSeam.setLen(table.cornerCount())
  result.vertexOnSeam.setLen(table.vertexCount)
  result.cornerToVertex.setLen(table.cornerCount())
  result.cornerToVertex.fillSeq(InvalidVertex)

proc decodeHoleAndTopologySplitEvents(
  stream: var DracoStream,
  table: CornerTable,
  splits: var seq[TopologySplit]
) =
  ## Decodes hole and topology split event metadata.
  let splitCount = stream.readVarint().int
  if splitCount > table.faceCount:
    raise newException(DracoError, "Invalid Draco topology split count")
  if splitCount > 0:
    var lastSource = 0
    for i in 0 ..< splitCount:
      discard i
      var event = TopologySplit()
      let delta = stream.readVarint().int
      event.sourceSymbolId = lastSource + delta
      let splitDelta = stream.readVarint().int
      if splitDelta > event.sourceSymbolId:
        raise newException(DracoError, "Invalid Draco topology split")
      event.splitSymbolId = event.sourceSymbolId - splitDelta
      lastSource = event.sourceSymbolId
      splits.add(event)
    discard stream.startBits(false)
    for i in 0 ..< splitCount:
      splits[i].sourceEdge = (stream.readBits(1) and 1).int
    stream.endBits()

proc isTopologySplit(
  splits: var seq[TopologySplit],
  encoderSymbolId: int,
  faceEdge: var int,
  splitSymbolId: var int
): bool =
  ## Pops the next topology split event for an encoder symbol.
  if splits.len == 0:
    return false
  let event = splits[^1]
  if event.sourceSymbolId > encoderSymbolId:
    splitSymbolId = -1
    return true
  if event.sourceSymbolId != encoderSymbolId:
    return false
  faceEdge = event.sourceEdge
  splitSymbolId = event.splitSymbolId
  discard splits.pop()
  true

proc decodeTraversalSymbols(
  decoder: var TraversalDecoder,
  stream: var DracoStream
) =
  ## Decodes standard traversal symbol bit data.
  decoder.symbolStream = stream.substream()
  let traversalSize = decoder.symbolStream.startBits(true).int
  if traversalSize > stream.remaining():
    raise newException(DracoError, "Invalid Draco traversal size")
  stream.pos += decoder.symbolStream.pos + traversalSize

proc startTraversalDecoder(
  decoder: var TraversalDecoder,
  stream: var DracoStream,
  kind: int,
  table: CornerTable,
  encodedVertexCount: int,
  attributeDataCount: int
) =
  ## Starts an edgebreaker traversal decoder.
  decoder.kind = kind
  decoder.activeContext = -1
  decoder.lastSymbol = -1
  decoder.minValence = 2
  decoder.maxValence = 7
  if kind == 0:
    decoder.decodeTraversalSymbols(stream)
  decoder.startFaces.startDecoding(stream)
  decoder.attrSeams.setLen(attributeDataCount)
  for i in 0 ..< attributeDataCount:
    decoder.attrSeams[i].startDecoding(stream)
  if kind == 2:
    decoder.vertexValences = newSeq[int](encodedVertexCount)
    let contextCount = decoder.maxValence - decoder.minValence + 1
    decoder.contextSymbols.setLen(contextCount)
    decoder.contextCounters.setLen(contextCount)
    for i in 0 ..< contextCount:
      let symbolCount = stream.readVarint().int
      if symbolCount > table.faceCount:
        raise newException(DracoError, "Invalid Draco valence symbol count")
      if symbolCount > 0:
        decoder.contextSymbols[i] = decodeSymbols(symbolCount, 1, stream)
      decoder.contextCounters[i] = symbolCount

proc decodeSymbol(
  decoder: var TraversalDecoder,
  table: CornerTable
): int =
  ## Decodes one edgebreaker traversal symbol.
  case decoder.kind
  of 0:
    result = decoder.symbolStream.readBits(1).int
    if result != TopologyC:
      result = result or (decoder.symbolStream.readBits(2).int shl 1)
  of 2:
    if decoder.activeContext >= 0:
      dec decoder.contextCounters[decoder.activeContext]
      if decoder.contextCounters[decoder.activeContext] < 0:
        return TopologyInvalid
      let symbolId = decoder.contextSymbols[
        decoder.activeContext
      ][decoder.contextCounters[decoder.activeContext]].int
      if symbolId > 4:
        return TopologyInvalid
      result = EdgeSymbolToTopology[symbolId]
    else:
      result = TopologyE
  else:
    raise newException(DracoError, "Unsupported Draco traversal decoder")
  discard table
  decoder.lastSymbol = result

proc newActiveCornerReached(
  decoder: var TraversalDecoder,
  table: CornerTable,
  corner: int
) =
  ## Updates traversal context after a corner is reached.
  if decoder.kind != 2:
    return
  let
    next = corner.nextCorner()
    prev = corner.previousCorner()
  case decoder.lastSymbol
  of TopologyC, TopologyS:
    inc decoder.vertexValences[table.vertex(next)]
    inc decoder.vertexValences[table.vertex(prev)]
  of TopologyR:
    inc decoder.vertexValences[table.vertex(corner)]
    inc decoder.vertexValences[table.vertex(next)]
    decoder.vertexValences[table.vertex(prev)] += 2
  of TopologyL:
    inc decoder.vertexValences[table.vertex(corner)]
    decoder.vertexValences[table.vertex(next)] += 2
    inc decoder.vertexValences[table.vertex(prev)]
  of TopologyE:
    decoder.vertexValences[table.vertex(corner)] += 2
    decoder.vertexValences[table.vertex(next)] += 2
    decoder.vertexValences[table.vertex(prev)] += 2
  else:
    discard
  let activeValence = decoder.vertexValences[table.vertex(next)]
  decoder.activeContext =
    max(decoder.minValence, min(decoder.maxValence, activeValence)) -
    decoder.minValence

proc mergeVertices(decoder: var TraversalDecoder, dest, source: int) =
  ## Merges traversal valence state for two vertices.
  if decoder.kind == 2:
    decoder.vertexValences[dest] += decoder.vertexValences[source]

proc decodeAttributeSeam(
  decoder: var TraversalDecoder,
  attribute: int
): bool =
  ## Decodes one attribute seam flag.
  decoder.attrSeams[attribute].decodeBit()

proc leftMostCornerForVertex(table: CornerTable, vertex: int): int =
  ## Returns the next corner after the left-most corner of a vertex.
  table.leftMostCorner(vertex).nextCorner()

proc decodeConnectivitySymbols(
  table: var CornerTable,
  decoder: var TraversalDecoder,
  splits: var seq[TopologySplit],
  attributeDataCount: int,
  symbolCount: int,
  maxVertexCount: int,
  isVertexHole: var seq[uint8]
): int =
  ## Decodes edgebreaker connectivity symbols.
  var
    activeCorners: seq[int]
    splitActiveCorners: Table[int, int]
    invalidVertices: seq[int]
    faceCountDecoded = 0

  for symbolId in 0 ..< symbolCount:
    let
      faceIndex = faceCountDecoded
      symbol = decoder.decodeSymbol(table)
    inc faceCountDecoded
    var checkSplit = false
    case symbol
    of TopologyC:
      if activeCorners.len == 0:
        raise newException(DracoError, "Invalid Draco C symbol")
      let
        cornerA = activeCorners[^1]
        vertexX = table.vertex(cornerA.nextCorner())
        cornerB = table.leftMostCornerForVertex(vertexX)
      if cornerA == cornerB or
        table.opposite(cornerA) != InvalidCorner or
        table.opposite(cornerB) != InvalidCorner:
          raise newException(DracoError, "Invalid Draco C connectivity")
      let corner = 3 * faceIndex
      table.opposites[cornerA] = corner + 1
      table.opposites[corner + 1] = cornerA
      table.opposites[cornerB] = corner + 2
      table.opposites[corner + 2] = cornerB
      let
        vertAPrev = table.vertex(cornerA.previousCorner())
        vertBNext = table.vertex(cornerB.nextCorner())
      if vertexX == vertAPrev or vertexX == vertBNext:
        raise newException(DracoError, "Invalid Draco C vertex")
      table.cornerToVertex[corner] = vertexX
      table.cornerToVertex[corner + 1] = vertBNext
      table.cornerToVertex[corner + 2] = vertAPrev
      table.setLeftMostCorner(vertAPrev, corner + 2)
      isVertexHole[vertexX] = 0
      activeCorners[^1] = corner
    of TopologyR, TopologyL:
      if activeCorners.len == 0:
        raise newException(DracoError, "Invalid Draco L/R symbol")
      let cornerA = activeCorners[^1]
      if table.opposite(cornerA) != InvalidCorner:
        raise newException(DracoError, "Invalid Draco L/R opposite")
      let corner = 3 * faceIndex
      var
        oppCorner: int
        cornerL: int
        cornerR: int
      if symbol == TopologyR:
        oppCorner = corner + 2
        cornerL = corner + 1
        cornerR = corner
      else:
        oppCorner = corner + 1
        cornerL = corner
        cornerR = corner + 2
      table.opposites[oppCorner] = cornerA
      table.opposites[cornerA] = oppCorner
      let newVertex = table.addNewVertex()
      if table.vertexCount > maxVertexCount:
        raise newException(DracoError, "Too many Draco vertices")
      table.cornerToVertex[oppCorner] = newVertex
      table.setLeftMostCorner(newVertex, oppCorner)
      let vertexR = table.vertex(cornerA.previousCorner())
      table.cornerToVertex[cornerR] = vertexR
      table.setLeftMostCorner(vertexR, cornerR)
      table.cornerToVertex[cornerL] = table.vertex(cornerA.nextCorner())
      activeCorners[^1] = corner
      checkSplit = true
    of TopologyS:
      if activeCorners.len == 0:
        raise newException(DracoError, "Invalid Draco S symbol")
      let cornerB = activeCorners.pop()
      if symbolId in splitActiveCorners:
        activeCorners.add(splitActiveCorners[symbolId])
      if activeCorners.len == 0:
        raise newException(DracoError, "Invalid Draco S active stack")
      let cornerA = activeCorners[^1]
      if cornerA == cornerB or
        table.opposite(cornerA) != InvalidCorner or
        table.opposite(cornerB) != InvalidCorner:
          raise newException(DracoError, "Invalid Draco S opposite")
      let corner = 3 * faceIndex
      table.opposites[cornerA] = corner + 2
      table.opposites[corner + 2] = cornerA
      table.opposites[cornerB] = corner + 1
      table.opposites[corner + 1] = cornerB
      let vertexP = table.vertex(cornerA.previousCorner())
      table.cornerToVertex[corner] = vertexP
      table.cornerToVertex[corner + 1] = table.vertex(cornerA.nextCorner())
      let vertBPrev = table.vertex(cornerB.previousCorner())
      table.cornerToVertex[corner + 2] = vertBPrev
      table.setLeftMostCorner(vertBPrev, corner + 2)
      var cornerN = cornerB.nextCorner()
      let vertexN = table.vertex(cornerN)
      decoder.mergeVertices(vertexP, vertexN)
      table.setLeftMostCorner(vertexP, table.leftMostCorner(vertexN))
      let firstCorner = cornerN
      while cornerN != InvalidCorner:
        table.cornerToVertex[cornerN] = vertexP
        cornerN = table.swingLeft(cornerN)
        if cornerN == firstCorner:
          raise newException(DracoError, "Invalid Draco S loop")
      table.makeVertexIsolated(vertexN)
      if attributeDataCount == 0:
        invalidVertices.add(vertexN)
      activeCorners[^1] = corner
    of TopologyE:
      let corner = 3 * faceIndex
      let firstVertex = table.addNewVertex()
      table.cornerToVertex[corner] = firstVertex
      table.cornerToVertex[corner + 1] = table.addNewVertex()
      table.cornerToVertex[corner + 2] = table.addNewVertex()
      if table.vertexCount > maxVertexCount:
        raise newException(DracoError, "Too many Draco E vertices")
      table.setLeftMostCorner(firstVertex, corner)
      table.setLeftMostCorner(firstVertex + 1, corner + 1)
      table.setLeftMostCorner(firstVertex + 2, corner + 2)
      activeCorners.add(corner)
      checkSplit = true
    else:
      raise newException(DracoError, "Invalid Draco topology symbol")

    decoder.newActiveCornerReached(table, activeCorners[^1])
    if checkSplit:
      let encoderSymbolId = symbolCount - symbolId - 1
      var
        edge = 0
        splitSymbol = 0
      while splits.isTopologySplit(encoderSymbolId, edge, splitSymbol):
        if splitSymbol < 0:
          raise newException(DracoError, "Invalid Draco topology split id")
        let active = activeCorners[^1]
        let newActive =
          if edge == RightFaceEdge:
            active.nextCorner()
          else:
            active.previousCorner()
        let decoderSplitId = symbolCount - splitSymbol - 1
        splitActiveCorners[decoderSplitId] = newActive

  while activeCorners.len > 0:
    let corner = activeCorners.pop()
    let interiorFace = decoder.startFaces.decodeBit()
    if interiorFace:
      if faceCountDecoded >= table.faceCount:
        raise newException(DracoError, "Invalid Draco start face count")
      let
        cornerA = corner
        vertN = table.vertex(cornerA.nextCorner())
        cornerB = table.leftMostCornerForVertex(vertN)
        vertX = table.vertex(cornerB.nextCorner())
        cornerC = table.leftMostCornerForVertex(vertX)
      if corner == cornerB or corner == cornerC or cornerB == cornerC:
        raise newException(DracoError, "Invalid Draco start face")
      if table.opposite(corner) != InvalidCorner or
        table.opposite(cornerB) != InvalidCorner or
        table.opposite(cornerC) != InvalidCorner:
          raise newException(DracoError, "Invalid Draco start opposite")
      let
        vertP = table.vertex(cornerC.nextCorner())
        faceIndex = faceCountDecoded
        newCorner = 3 * faceIndex
      inc faceCountDecoded
      table.opposites[newCorner] = corner
      table.opposites[corner] = newCorner
      table.opposites[newCorner + 1] = cornerB
      table.opposites[cornerB] = newCorner + 1
      table.opposites[newCorner + 2] = cornerC
      table.opposites[cornerC] = newCorner + 2
      table.cornerToVertex[newCorner] = vertX
      table.cornerToVertex[newCorner + 1] = vertP
      table.cornerToVertex[newCorner + 2] = vertN
      for ci in 0 ..< 3:
        isVertexHole[table.vertex(newCorner + ci)] = 0

  if faceCountDecoded != table.faceCount:
    raise newException(DracoError, "Invalid Draco decoded face count")

  var numVertices = table.vertexCount
  for invalidVertex in invalidVertices:
    var srcVertex = numVertices - 1
    while srcVertex >= 0 and table.leftMostCorner(srcVertex) == InvalidCorner:
      dec numVertices
      srcVertex = numVertices - 1
    if srcVertex < invalidVertex:
      continue
    let start = table.leftMostCorner(srcVertex)
    var
      cid = start
      leftTraversal = true
    while cid != InvalidCorner:
      if table.vertex(cid) != srcVertex:
        raise newException(DracoError, "Invalid Draco isolated vertex")
      table.cornerToVertex[cid] = invalidVertex
      if leftTraversal:
        let next = table.swingLeft(cid)
        if next == InvalidCorner:
          leftTraversal = false
          cid = table.swingRight(start)
        elif next == start:
          break
        else:
          cid = next
      else:
        cid = table.swingRight(cid)
    table.setLeftMostCorner(invalidVertex, table.leftMostCorner(srcVertex))
    table.makeVertexIsolated(srcVertex)
    isVertexHole[invalidVertex] = isVertexHole[srcVertex]
    isVertexHole[srcVertex] = 0
    dec numVertices
  numVertices

proc decodeAttributeConnectivities(
  table: CornerTable,
  decoder: var TraversalDecoder,
  data: var seq[AttributeData]
) =
  ## Decodes seam edges for non-position attributes.
  if data.len == 0:
    return
  for faceId in 0 ..< table.faceCount:
    let
      corner = faceId * 3
      corners = [corner, corner.nextCorner(), corner.previousCorner()]
    for c in corners:
      let opp = table.opposite(c)
      if opp == InvalidCorner:
        for i in 0 ..< data.len:
          data[i].seamCorners.add(c)
        continue
      let oppFace = opp.face()
      if oppFace < faceId:
        continue
      for i in 0 ..< data.len:
        if decoder.decodeAttributeSeam(i):
          data[i].seamCorners.add(c)

proc assignPointsToCorners(
  state: var EdgebreakerMesh,
  connectivityVertexCount: int,
  isVertexHole: seq[uint8]
) =
  ## Assigns decoded point ids to mesh corners.
  let table = state.cornerTable
  state.mesh.faceCount = table.faceCount
  state.mesh.faces.setLen(table.faceCount * 3)
  if state.attributeData.len == 0:
    for faceId in 0 ..< table.faceCount:
      let corner = faceId * 3
      state.mesh.faces[corner] = table.vertex(corner).uint32
      state.mesh.faces[corner + 1] = table.vertex(corner + 1).uint32
      state.mesh.faces[corner + 2] = table.vertex(corner + 2).uint32
    state.mesh.pointCount = connectivityVertexCount
    return

  let cornerCount = table.cornerCount()
  debugDraco(
    "Draco edgebreaker assign begin corners=" & $cornerCount &
      " vertices=" & $table.vertexCount
  )
  var
    cornerToPoint = newSeq[int](cornerCount)
    pointCount = 0
  cornerToPoint.fillSeq(InvalidVertex)

  var
    attrCornerMaps = newSeq[seq[int]](state.attributeData.len)
    attrSeamMaps = newSeq[seq[uint8]](state.attributeData.len)
  for i in 0 ..< state.attributeData.len:
    attrCornerMaps[i] = state.attributeData[i].connectivity.cornerToVertex
    attrSeamMaps[i] = state.attributeData[i].connectivity.vertexOnSeam

  for v in 0 ..< table.vertexCount:
    when defined(dracoDebug):
      if v mod 5000 == 0:
        debugDraco(
          "Draco edgebreaker assign vertex=" & $v &
            " points=" & $pointCount
        )
    var
      firstCorner = table.leftMostCorner(v)
      steps = 0
    if firstCorner == InvalidCorner:
      continue
    if v >= isVertexHole.len:
      raise newException(DracoError, "Invalid Draco point hole vertex")
    if isVertexHole[v] == 0:
      block findSeam:
        for i in 0 ..< attrCornerMaps.len:
          let vertex = table.vertex(firstCorner)
          if vertex < 0 or vertex >= attrSeamMaps[i].len:
            raise newException(DracoError, "Invalid Draco seam vertex")
          if attrSeamMaps[i][vertex] == 0:
            continue
          if firstCorner >= attrCornerMaps[i].len:
            raise newException(DracoError, "Invalid Draco seam corner")
          let firstVertex = attrCornerMaps[i][firstCorner]
          var active = table.swingRight(firstCorner)
          steps = 0
          while active != firstCorner:
            if active == InvalidCorner:
              raise newException(DracoError, "Invalid Draco point seam")
            if active < 0 or active >= attrCornerMaps[i].len:
              raise newException(DracoError, "Invalid Draco seam walk")
            if attrCornerMaps[i][active] != firstVertex:
              firstCorner = active
              break findSeam
            active = table.swingRight(active)
            inc steps
            if steps > cornerCount:
              raise newException(DracoError, "Invalid Draco point seam loop")

    var
      corner = firstCorner
      previous = firstCorner
    cornerToPoint[corner] = pointCount
    inc pointCount
    corner = table.swingRight(corner)
    steps = 0
    while corner != InvalidCorner:
      if corner < 0 or corner >= cornerCount:
        raise newException(DracoError, "Invalid Draco point corner")
      if corner == firstCorner:
        break
      var seam = false
      for i in 0 ..< attrCornerMaps.len:
        if corner >= attrCornerMaps[i].len or
          previous >= attrCornerMaps[i].len:
            raise newException(
              DracoError,
              "Invalid Draco attribute point corner"
            )
        if attrCornerMaps[i][corner] != attrCornerMaps[i][previous]:
          seam = true
          break
      if seam:
        cornerToPoint[corner] = pointCount
        inc pointCount
      else:
        cornerToPoint[corner] = cornerToPoint[previous]
      previous = corner
      corner = table.swingRight(corner)
      inc steps
      if steps > cornerCount:
        raise newException(DracoError, "Invalid Draco point loop")

  debugDraco("Draco edgebreaker assign faces")
  for faceId in 0 ..< table.faceCount:
    let corner = faceId * 3
    if cornerToPoint[corner] < 0 or
      cornerToPoint[corner + 1] < 0 or
      cornerToPoint[corner + 2] < 0:
        raise newException(DracoError, "Invalid Draco point assignment")
    state.mesh.faces[corner] = cornerToPoint[corner].uint32
    state.mesh.faces[corner + 1] = cornerToPoint[corner + 1].uint32
    state.mesh.faces[corner + 2] = cornerToPoint[corner + 2].uint32
  state.mesh.pointCount = pointCount

proc initEncoding(data: var EncodingData, vertexCount: int) =
  ## Initializes attribute traversal encoding data.
  data.vertexToValue.setLen(vertexCount)
  data.vertexToValue.fillSeq(0)
  data.valueToCorner.setLen(0)
  data.valueCount = 0

proc decodeEdgebreakerMesh*(
  stream: var DracoStream,
  traversalKind: int
): EdgebreakerMesh =
  ## Decodes Draco edgebreaker mesh connectivity.
  debugDraco("Draco edgebreaker begin")
  result.posDataDecoderId = -1
  let
    encodedVertexCount = stream.readVarint().int
    faceCount = stream.readVarint().int
    attributeDataCount = stream.readUint8().int
    symbolCount = stream.readVarint().int
    splitSymbolCount = stream.readVarint().int
  debugDraco(
    "Draco edgebreaker header vertices=" & $encodedVertexCount &
      " faces=" & $faceCount &
      " attrs=" & $attributeDataCount &
      " symbols=" & $symbolCount &
      " splits=" & $splitSymbolCount &
      " traversal=" & $traversalKind
  )
  if faceCount > int.high div 3:
    raise newException(DracoError, "Too many Draco faces")
  if encodedVertexCount > faceCount * 3:
    raise newException(DracoError, "Invalid Draco vertex count")
  if symbolCount > faceCount:
    raise newException(DracoError, "Invalid Draco symbol count")
  if splitSymbolCount > symbolCount:
    raise newException(DracoError, "Invalid Draco split symbol count")
  let maxVertexCount = encodedVertexCount + splitSymbolCount
  result.cornerTable.reset(faceCount, maxVertexCount)
  result.attributeData.setLen(attributeDataCount)
  for i in 0 ..< attributeDataCount:
    result.attributeData[i].decoderId = -1
    result.attributeData[i].connectivityUsed = true

  var splits: seq[TopologySplit]
  decodeHoleAndTopologySplitEvents(stream, result.cornerTable, splits)
  debugDraco("Draco edgebreaker splits=" & $splits.len)
  var
    traversal = TraversalDecoder()
    isVertexHole = newSeq[uint8](maxVertexCount)
  for i in 0 ..< isVertexHole.len:
    isVertexHole[i] = 1
  traversal.startTraversalDecoder(
    stream,
    traversalKind,
    result.cornerTable,
    maxVertexCount,
    attributeDataCount
  )
  debugDraco("Draco edgebreaker traversal ready")
  let connectivityVertexCount = result.cornerTable.decodeConnectivitySymbols(
    traversal,
    splits,
    attributeDataCount,
    symbolCount,
    maxVertexCount,
    isVertexHole
  )
  debugDraco(
    "Draco edgebreaker connectivity vertices=" & $connectivityVertexCount
  )
  if traversal.kind == 0:
    traversal.symbolStream.endBits()
  result.cornerTable.decodeAttributeConnectivities(
    traversal,
    result.attributeData
  )
  debugDraco("Draco edgebreaker seams decoded")
  for i in 0 ..< result.attributeData.len:
    var attr = initAttributeCornerTable(result.cornerTable)
    for corner in result.attributeData[i].seamCorners:
      attr.addSeamEdge(result.cornerTable, corner)
    attr.recomputeVertices(result.cornerTable)
    result.attributeData[i].connectivity = attr
    debugDraco("Draco edgebreaker attr " & $i & " vertices recomputed")
  result.posEncoding.initEncoding(result.cornerTable.vertexCount)
  for i in 0 ..< result.attributeData.len:
    let vertexCount = max(
      result.attributeData[i].connectivity.vertexParents.len,
      result.cornerTable.vertexCount
    )
    result.attributeData[i].encoding.initEncoding(vertexCount)
  result.assignPointsToCorners(connectivityVertexCount, isVertexHole)
  debugDraco("Draco edgebreaker points=" & $result.mesh.pointCount)

proc decodeSequentialMesh*(
  stream: var DracoStream
): DracoMesh =
  ## Decodes Draco sequential mesh connectivity.
  let
    faceCount = stream.readVarint().int
    pointCount = stream.readVarint().int
    connectivityMethod = stream.readUint8()
  result.faceCount = faceCount
  result.pointCount = pointCount
  result.faces.setLen(faceCount * 3)
  if connectivityMethod == 0:
    let symbols = decodeSymbols(faceCount * 3, 1, stream)
    var lastIndex = 0'i32
    for i, encoded in symbols:
      var diff = int32(encoded shr 1)
      if (encoded and 1) != 0:
        if diff > lastIndex:
          raise newException(DracoError, "Invalid Draco index delta")
        diff = -diff
      result.faces[i] = uint32(lastIndex + diff)
      lastIndex = lastIndex + diff
  elif pointCount < 256:
    for i in 0 ..< result.faces.len:
      result.faces[i] = stream.readUint8().uint32
  elif pointCount < (1 shl 16):
    for i in 0 ..< result.faces.len:
      result.faces[i] = stream.readUint16().uint32
  elif pointCount < (1 shl 21):
    for i in 0 ..< result.faces.len:
      result.faces[i] = stream.readVarint()
  else:
    for i in 0 ..< result.faces.len:
      result.faces[i] = stream.readUint32()
proc generateSequence*(
  table: CornerTable,
  mesh: DracoMesh,
  data: var EncodingData
): seq[int] =
  ## Generates mesh traversal point ids for attribute decoding.
  data.valueToCorner.setLen(0)
  data.valueCount = 0
  var
    faceVisited = newSeq[uint8](table.faceCount)
    vertexVisited = newSeq[uint8](table.vertexCount)
    stack: seq[int]

  template addVertex(vertex, corner: int) =
    let pointId = mesh.faces[corner].int
    result.add(pointId)
    data.valueToCorner.add(corner)
    data.vertexToValue[vertex] = data.valueCount
    inc data.valueCount

  for startFace in 0 ..< table.faceCount:
    let startCorner = startFace * 3
    if faceVisited[startFace] != 0:
      continue
    stack.setLen(0)
    stack.add(startCorner)
    let
      next = startCorner.nextCorner()
      prev = startCorner.previousCorner()
      nextVertex = table.vertex(next)
      prevVertex = table.vertex(prev)
    if nextVertex == InvalidVertex or prevVertex == InvalidVertex:
      raise newException(DracoError, "Invalid Draco traversal vertex")
    if vertexVisited[nextVertex] == 0:
      vertexVisited[nextVertex] = 1
      addVertex(nextVertex, next)
    if vertexVisited[prevVertex] == 0:
      vertexVisited[prevVertex] = 1
      addVertex(prevVertex, prev)
    while stack.len > 0:
      var corner = stack[^1]
      var faceId = corner.face()
      if corner == InvalidCorner or faceVisited[faceId] != 0:
        discard stack.pop()
        continue
      while true:
        faceVisited[faceId] = 1
        let vertex = table.vertex(corner)
        if vertex == InvalidVertex:
          raise newException(DracoError, "Invalid Draco traversal corner")
        if vertexVisited[vertex] == 0:
          let onBoundary = table.swingLeft(table.leftMostCorner(vertex)) < 0
          vertexVisited[vertex] = 1
          addVertex(vertex, corner)
          if not onBoundary:
            corner = table.opposite(corner.nextCorner())
            faceId = corner.face()
            continue
        let
          rightCorner = table.opposite(corner.nextCorner())
          leftCorner = table.opposite(corner.previousCorner())
          rightFace = rightCorner.face()
          leftFace = leftCorner.face()
          rightVisited =
            rightFace < 0 or faceVisited[rightFace] != 0
          leftVisited =
            leftFace < 0 or faceVisited[leftFace] != 0
        if rightVisited:
          if leftVisited:
            discard stack.pop()
            break
          corner = leftCorner
          faceId = leftFace
        else:
          if leftVisited:
            corner = rightCorner
            faceId = rightFace
          else:
            stack[^1] = leftCorner
            stack.add(rightCorner)
            break

proc generateSequence*(
  attr: AttributeCornerTable,
  base: CornerTable,
  mesh: DracoMesh,
  data: var EncodingData
): seq[int] =
  ## Generates attribute traversal point ids for seam connectivity.
  data.valueToCorner.setLen(0)
  data.valueCount = 0
  var table = CornerTable(
    faceCount: base.faceCount,
    cornerToVertex: attr.cornerToVertex,
    opposites: attr.effectiveOpposites,
    vertexCorners: attr.vertexLeftmost,
    vertexCount: attr.vertexParents.len
  )
  generateSequence(table, mesh, data)

proc applyPointMap*(
  attr: var DracoAttribute,
  table: CornerTable,
  mesh: DracoMesh,
  data: EncodingData
) =
  ## Builds the final point-to-attribute-value map.
  attr.identityMap = false
  attr.pointMap.setLen(mesh.pointCount)
  for ci in 0 ..< mesh.faces.len:
    let
      vert = table.vertex(ci)
      entry = data.vertexToValue[vert]
      pointId = mesh.faces[ci].int
    attr.pointMap[pointId] = entry

proc applyPointMap*(
  attr: var DracoAttribute,
  conn: AttributeCornerTable,
  mesh: DracoMesh,
  data: EncodingData
) =
  ## Builds a final point map for seam-split attributes.
  attr.identityMap = false
  attr.pointMap.setLen(mesh.pointCount)
  for ci in 0 ..< mesh.faces.len:
    let
      vert = conn.cornerToVertex[ci]
      entry = data.vertexToValue[vert]
      pointId = mesh.faces[ci].int
    attr.pointMap[pointId] = entry
