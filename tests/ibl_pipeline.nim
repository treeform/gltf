## Render known HDR values through the real GPU presentation pass. Contrasting
## tone flags on the two rows also catches a vertically flipped flag lookup.
import opengl, windy, vmath, chroma, gltf/backends/opengl/ibl

let window = newWindow("IBL pipeline test", ivec2(4, 2), visible = false)
makeContextCurrent(window)
loadExtensions()
var target: HdrTarget
let colors = [[0.04'f, 0.04'f, 0.04'f, 1.0'f],
  [0.18'f, 0.18'f, 0.18'f, 1.0'f], [1.0'f, 1.0'f, 1.0'f, 1.0'f],
  [4.0'f, 0.2'f, 0.05'f, 1.0'f]]
let linearExpected = [[59, 59, 59], [117, 117, 117], [255, 255, 255], [255, 123, 65]]
let neutralExpected = [
  [[17, 17, 17], [65, 65, 65], [179, 179, 179], [250, 111, 100]],
  [[31, 31, 31], [104, 104, 104], [239, 239, 239], [253, 155, 149]],
  [[59, 59, 59], [152, 152, 152], [250, 250, 250], [254, 191, 188]]]
for iteration, exposure in [0.5'f, 1.0'f, 2.0'f]:
  target.beginHdr(ivec2(4, 2), color(0, 0, 0, 1))
  glEnable(GL_SCISSOR_TEST)
  for y in 0 ..< 2:
    for x in 0 ..< 4:
      glScissor(x.GLint, y.GLint, 1, 1)
      var rgba = colors[x]
      var flags = [uint32(y + 1), 0'u32, 0'u32, 0'u32]
      glClearBufferfv(GL_COLOR, 0, rgba[0].addr)
      glClearBufferuiv(GL_COLOR, 1, flags[0].addr)
  glDisable(GL_SCISSOR_TEST)
  target.endHdr(exposure)
  var pixels: array[4 * 2 * 4, uint8]
  glReadBuffer(GL_BACK)
  glReadPixels(0, 0, 4, 2, GL_RGBA, GL_UNSIGNED_BYTE, pixels[0].addr)
  for y in 0 ..< 2:
    for x in 0 ..< 4:
      for channel in 0 ..< 3:
        let expected = if y == 0: linearExpected[x][channel]
          else: neutralExpected[iteration][x][channel]
        let actual = pixels[(y * 4 + x) * 4 + channel].int
        doAssert abs(actual - expected) <= 1,
          "HDR transfer mismatch at " & $x & "," & $y & ": " & $actual & " expected " & $expected
  doAssert glGetError() == GL_NO_ERROR
target.destroy()
echo "HDR GPU pipeline: neutral highlights, exposure, gamma and per-pixel flags passed"
