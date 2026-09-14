import opengl, vmath

type TestFrame* = object
  framebuffer, color, depth: GLuint
  size: IVec2

proc bindFrame*(frame: TestFrame) =
  ## Uses an explicit drawable so hidden macOS windows need no backing store.
  glBindFramebuffer(GL_FRAMEBUFFER, frame.framebuffer)
  glViewport(0, 0, frame.size.x, frame.size.y)
  glReadBuffer(GL_COLOR_ATTACHMENT0)

proc newTestFrame*(size: IVec2): TestFrame =
  ## Allocates an exact-size RGBA8 and depth target for GPU assertions.
  result.size = size
  glGenFramebuffers(1, result.framebuffer.addr)
  glBindFramebuffer(GL_FRAMEBUFFER, result.framebuffer)
  for (buffer, attachment, format) in [
    (result.color.addr, GL_COLOR_ATTACHMENT0, GL_RGBA8),
    (result.depth.addr, GL_DEPTH_ATTACHMENT, GL_DEPTH_COMPONENT24)
  ]:
    glGenRenderbuffers(1, buffer)
    glBindRenderbuffer(GL_RENDERBUFFER, buffer[])
    glRenderbufferStorage(GL_RENDERBUFFER, format, size.x, size.y)
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, attachment,
      GL_RENDERBUFFER, buffer[])
  doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
  result.bindFrame()

proc destroy*(frame: var TestFrame) =
  ## Releases all attachments after the final pixel assertion.
  glDeleteRenderbuffers(1, frame.color.addr)
  glDeleteRenderbuffers(1, frame.depth.addr)
  glDeleteFramebuffers(1, frame.framebuffer.addr)
  frame = TestFrame()
