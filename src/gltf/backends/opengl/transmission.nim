## Same-frame background snapshot for screen-space glTF transmission.
## Match the pinned Sample Renderer: 1024-square, RGBA8, 4x MSAA, mipmapped.
import std/math, opengl, chroma

const TransmissionSize* = 1024

type TransmissionTarget* = object
  texture*: GLuint
  framebuffer, multisampleFramebuffer, colorBuffer, depthBuffer: GLuint
  previousDraw, previousRead: GLint
  previousViewport: array[4, GLint]
  active: bool

proc restore*(target: var TransmissionTarget) =
  if not target.active: return
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, target.previousDraw.GLuint)
  glBindFramebuffer(GL_READ_FRAMEBUFFER, target.previousRead.GLuint)
  glViewport(target.previousViewport[0], target.previousViewport[1],
    target.previousViewport[2], target.previousViewport[3])
  target.active = false

proc destroy*(target: var TransmissionTarget) =
  target.restore()
  if target.texture != 0: glDeleteTextures(1, target.texture.addr)
  if target.framebuffer != 0: glDeleteFramebuffers(1, target.framebuffer.addr)
  if target.multisampleFramebuffer != 0:
    glDeleteFramebuffers(1, target.multisampleFramebuffer.addr)
  if target.colorBuffer != 0: glDeleteRenderbuffers(1, target.colorBuffer.addr)
  if target.depthBuffer != 0: glDeleteRenderbuffers(1, target.depthBuffer.addr)
  target = TransmissionTarget()

proc beginBackground*(target: var TransmissionTarget, background: Color) =
  doAssert not target.active
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, target.previousDraw.addr)
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, target.previousRead.addr)
  glGetIntegerv(GL_VIEWPORT, target.previousViewport[0].addr)
  target.active = true
  try:
    if target.texture == 0:
      glGenFramebuffers(1, target.framebuffer.addr)
      glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffer)
      glGenTextures(1, target.texture.addr)
      glBindTexture(GL_TEXTURE_2D, target.texture)
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, TransmissionSize,
        TransmissionSize, 0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR.GLint)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST.GLint)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
        GL_TEXTURE_2D, target.texture, 0)
      if glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE:
        raise newException(ValueError, "Incomplete transmission resolve framebuffer")

      var maxSamples: GLint
      glGetIntegerv(GL_MAX_SAMPLES, maxSamples.addr)
      let samples = min(4, maxSamples)
      glGenFramebuffers(1, target.multisampleFramebuffer.addr)
      glBindFramebuffer(GL_FRAMEBUFFER, target.multisampleFramebuffer)
      for (buffer, attachment, format) in [
          (target.colorBuffer.addr, GL_COLOR_ATTACHMENT0, GL_RGBA8),
          (target.depthBuffer.addr, GL_DEPTH_ATTACHMENT, GL_DEPTH_COMPONENT24)]:
        glGenRenderbuffers(1, buffer)
        glBindRenderbuffer(GL_RENDERBUFFER, buffer[])
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, samples, format,
          TransmissionSize, TransmissionSize)
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, attachment, GL_RENDERBUFFER, buffer[])
      glBindRenderbuffer(GL_RENDERBUFFER, 0)
      if glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE:
        raise newException(ValueError, "Incomplete transmission multisample framebuffer")
    glBindFramebuffer(GL_FRAMEBUFFER, target.multisampleFramebuffer)
    glViewport(0, 0, TransmissionSize, TransmissionSize)
    glDepthMask(GL_TRUE)
    var
      clear = [pow(background.r, 2.2'f), pow(background.g, 2.2'f),
        pow(background.b, 2.2'f), pow(background.a, 2.2'f)]
      depth = 1.0'f
    glClearBufferfv(GL_COLOR, 0, clear[0].addr)
    glClearBufferfv(GL_DEPTH, 0, depth.addr)
  except:
    target.destroy()
    raise

proc resolveBackground*(target: var TransmissionTarget) =
  doAssert target.active
  try:
    glBindFramebuffer(GL_READ_FRAMEBUFFER, target.multisampleFramebuffer)
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, target.framebuffer)
    glBlitFramebuffer(0, 0, TransmissionSize, TransmissionSize,
      0, 0, TransmissionSize, TransmissionSize, GL_COLOR_BUFFER_BIT, GL_NEAREST.GLenum)
    glBindTexture(GL_TEXTURE_2D, target.texture)
    glGenerateMipmap(GL_TEXTURE_2D)
  finally:
    target.restore()
