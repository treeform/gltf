import
  gltf/draco/types

template expectDracoError*(body: untyped) =
  ## Runs a block and requires it to raise a DracoError.
  var raised = false
  try:
    body
  except DracoError:
    raised = true
  doAssert raised, "Expected DracoError"

proc approx*(a, b: float32, epsilon = 0.00001'f): bool =
  ## Returns true when two float32 values are close enough.
  abs(a - b) <= epsilon

proc approx*(
  a, b: array[3, float32],
  epsilon = 0.00001'f
): bool =
  ## Returns true when two float32 vectors are close enough.
  for i in 0 ..< 3:
    if not approx(a[i], b[i], epsilon):
      return false
  true
