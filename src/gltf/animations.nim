import
  std/math,
  vmath,
  common, models

proc resetToBase*(node: Node) =
  ## Reset the node and its children to the original transform.
  if node == nil:
    return
  node.visible = node.baseVisible
  node.pos = node.basePos
  node.rot = node.baseRot
  node.scale = node.baseScale
  for child in node.nodes:
    child.resetToBase()

proc cubicSplineFloat(
  v0, outTangent, v1, inTangent, u, dt: float32
): float32 =
  ## Evaluates one scalar cubic spline segment.
  let
    u2 = u * u
    u3 = u2 * u
    m0 = outTangent * dt
    m1 = inTangent * dt
  (2 * u3 - 3 * u2 + 1) * v0 +
  (u3 - 2 * u2 + u) * m0 +
  (-2 * u3 + 3 * u2) * v1 +
  (u3 - u2) * m1

proc cubicSplineVec3(
  v0, outTangent, v1, inTangent: Vec3,
  u, dt: float32
): Vec3 =
  ## Evaluates one vec3 cubic spline segment.
  let
    u2 = u * u
    u3 = u2 * u
    m0 = outTangent * dt
    m1 = inTangent * dt
  (2 * u3 - 3 * u2 + 1) * v0 +
  (u3 - 2 * u2 + u) * m0 +
  (-2 * u3 + 3 * u2) * v1 +
  (u3 - u2) * m1

proc cubicSplineQuat(
  v0, outTangent, v1, inTangent: Quat,
  u, dt: float32
): Quat =
  ## Evaluates one quaternion cubic spline segment.
  let
    u2 = u * u
    u3 = u2 * u
    m0 = outTangent * dt
    m1 = inTangent * dt
    q =
      (2 * u3 - 3 * u2 + 1) * v0 +
      (u3 - 2 * u2 + u) * m0 +
      (-2 * u3 + 3 * u2) * v1 +
      (u3 - u2) * m1
  q.normalize()

proc quatSlerp(a, b: Quat, u: float32): Quat =
  ## Spherically interpolates between quaternions.
  var
    qa = a.normalize()
    qb = b.normalize()
    d = qa.x * qb.x + qa.y * qb.y + qa.z * qb.z + qa.w * qb.w
  if d < 0:
    qb = qb * -1
    d = -d
  if d > 0.9995:
    return (qa + (qb - qa) * u).normalize()
  let
    theta0 = arccos(d)
    theta = u * theta0
    sinTheta = sin(theta)
    sinTheta0 = sin(theta0)
    scaleA = cos(theta) - d * sinTheta / sinTheta0
    scaleB = sinTheta / sinTheta0
  (qa * scaleA + qb * scaleB).normalize()

proc sampleSpan(times: seq[float32], t: float32): (int, int, float32) =
  ## Finds the keyframe span and interpolation factor.
  if times.len == 0:
    return (-1, -1, 0)
  if t <= times[0]:
    return (0, 0, 0)
  if t >= times[^1]:
    return (times.high, times.high, 0)
  for i in 0 ..< times.len - 1:
    let
      t0 = times[i]
      t1 = times[i + 1]
    if t <= t1:
      let u =
        if t1 > t0:
          (t - t0) / (t1 - t0)
        else:
          0
      return (i, i + 1, u)
  (times.high, times.high, 0)

proc sampleFloat(
  interpolation: AnimInterpolation,
  times, values, inTangents, outTangents: seq[float32],
  t: float32
): float32 =
  ## Samples a scalar animation track at a time.
  if values.len == 0 or times.len == 0:
    return 0
  let (i0, i1, u) = sampleSpan(times, t)
  if i0 < 0:
    return 0
  if i0 == i1:
    return values[i0]
  case interpolation
  of aiStep:
    values[i0]
  of aiLinear:
    values[i0] * (1 - u) + values[i1] * u
  of aiCubicSpline:
    cubicSplineFloat(
      values[i0],
      outTangents[i0],
      values[i1],
      inTangents[i1],
      u,
      times[i1] - times[i0]
    )

proc sampleVec3(
  interpolation: AnimInterpolation,
  times: seq[float32],
  values, inTangents, outTangents: seq[Vec3],
  t: float32
): Vec3 =
  ## Samples a vec3 animation track at a time.
  if values.len == 0 or times.len == 0:
    return vec3(0, 0, 0)
  let (i0, i1, u) = sampleSpan(times, t)
  if i0 < 0:
    return vec3(0, 0, 0)
  if i0 == i1:
    return values[i0]
  case interpolation
  of aiStep:
    values[i0]
  of aiLinear:
    values[i0] * (1 - u) + values[i1] * u
  of aiCubicSpline:
    cubicSplineVec3(
      values[i0],
      outTangents[i0],
      values[i1],
      inTangents[i1],
      u,
      times[i1] - times[i0]
    )

proc sampleQuat(
  interpolation: AnimInterpolation,
  times: seq[float32],
  values, inTangents, outTangents: seq[Quat],
  t: float32
): Quat =
  ## Samples a quaternion animation track at a time.
  if values.len == 0 or times.len == 0:
    return quat(0, 0, 0, 1)
  let (i0, i1, u) = sampleSpan(times, t)
  if i0 < 0:
    return quat(0, 0, 0, 1)
  if i0 == i1:
    return values[i0].normalize()
  case interpolation
  of aiStep:
    values[i0].normalize()
  of aiLinear:
    quatSlerp(values[i0], values[i1], u)
  of aiCubicSpline:
    cubicSplineQuat(
      values[i0],
      outTangents[i0],
      values[i1],
      inTangents[i1],
      u,
      times[i1] - times[i0]
    )

proc sampleWeights(
  interpolation: AnimInterpolation,
  times: seq[float32],
  values, inTangents, outTangents: seq[seq[float32]],
  t: float32
): seq[float32] =
  ## Samples one morph weight frame at a time.
  if values.len == 0 or times.len == 0:
    return
  let (i0, i1, u) = sampleSpan(times, t)
  if i0 < 0:
    return
  if i0 == i1:
    return values[i0]
  result.setLen(values[i0].len)
  case interpolation
  of aiStep:
    result = values[i0]
  of aiLinear:
    for i in 0 ..< result.len:
      result[i] = values[i0][i] * (1 - u) + values[i1][i] * u
  of aiCubicSpline:
    let dt = times[i1] - times[i0]
    for i in 0 ..< result.len:
      result[i] = cubicSplineFloat(
        values[i0][i],
        outTangents[i0][i],
        values[i1][i],
        inTangents[i1][i],
        u,
        dt
      )

proc applyMorphs(node: Node) =
  ## Applies morph targets to a node mesh on the CPU.
  if node == nil:
    return
  if node.mesh != nil and node.morphWeights.len > 0:
    for primitive in node.mesh.primitives:
      primitive.points = primitive.basePoints
      primitive.normals = primitive.baseNormals
      primitive.tangents = primitive.baseTangents
      for i, target in primitive.morphTargets:
        let weight =
          if i < node.morphWeights.len:
            node.morphWeights[i]
          else:
            0.0
        if weight == 0:
          continue
        if target.positionDeltas.len == primitive.points.len:
          for j in 0 ..< primitive.points.len:
            primitive.points[j] += target.positionDeltas[j] * weight
        if target.normalDeltas.len == primitive.normals.len:
          for j in 0 ..< primitive.normals.len:
            primitive.normals[j] += target.normalDeltas[j] * weight
        if target.tangentDeltas.len > 0 and
          target.tangentDeltas.len == primitive.tangents.len:
          for j in 0 ..< primitive.tangents.len:
            primitive.tangents[j].x += target.tangentDeltas[j].x * weight
            primitive.tangents[j].y += target.tangentDeltas[j].y * weight
            primitive.tangents[j].z += target.tangentDeltas[j].z * weight
      if primitive.normals.len > 0:
        for normal in mitems(primitive.normals):
          normal = normal.normalize()
      if primitive.tangents.len > 0:
        for tangent in mitems(primitive.tangents):
          let dir = vec3(tangent.x, tangent.y, tangent.z).normalize()
          tangent.x = dir.x
          tangent.y = dir.y
          tangent.z = dir.z
  for child in node.nodes:
    child.applyMorphs()

proc applyClipAt*(clip: AnimationClip, time: float32) =
  ## Applies an animation clip at a time.
  if clip.channels.len == 0:
    return
  let t =
    if clip.duration > 0:
      let wrapped = time mod clip.duration
      if wrapped == 0 and time > 0:
        clip.duration
      else:
        wrapped
    else:
      time
  for ch in clip.channels:
    case ch.path
    of AnimTranslation:
      if ch.valuesVec3.len > 0:
        ch.target.pos = sampleVec3(
          ch.interpolation,
          ch.times,
          ch.valuesVec3,
          ch.inTangentsVec3,
          ch.outTangentsVec3,
          t
        )
    of AnimScale:
      if ch.valuesVec3.len > 0:
        ch.target.scale = sampleVec3(
          ch.interpolation,
          ch.times,
          ch.valuesVec3,
          ch.inTangentsVec3,
          ch.outTangentsVec3,
          t
        )
    of AnimRotation:
      if ch.valuesQuat.len > 0:
        ch.target.rot = sampleQuat(
          ch.interpolation,
          ch.times,
          ch.valuesQuat,
          ch.inTangentsQuat,
          ch.outTangentsQuat,
          t
        )
    of AnimVisibility:
      if ch.valuesFloat.len > 0:
        ch.target.visible = sampleFloat(
          ch.interpolation,
          ch.times,
          ch.valuesFloat,
          ch.inTangentsFloat,
          ch.outTangentsFloat,
          t
        ) >= 0.5
    of AnimWeights:
      if ch.valuesWeights.len > 0:
        ch.target.morphWeights = sampleWeights(
          ch.interpolation,
          ch.times,
          ch.valuesWeights,
          ch.inTangentsWeights,
          ch.outTangentsWeights,
          t
        )

proc updateAnimation*(node: Node, dt: float32) =
  ## Advances and applies active animation clips.
  if node == nil:
    return
  node.resetToBase()
  if node.animations.len == 0:
    return

  node.animTime += dt
  if node.activeClips.len > 0:
    for clipIdx in node.activeClips:
      if clipIdx >= 0 and clipIdx < node.animations.len:
        applyClipAt(node.animations[clipIdx], node.animTime)
  node.applyMorphs()
  node.updateOnGpu()
