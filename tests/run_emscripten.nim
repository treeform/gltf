## Compiles and serves the Damaged Helmet Emscripten example.

import
  std/[browsers, os, osproc, strformat, strutils],
  mummy, mummy/routers

when not declared(Thread):
  import std/threads

const
  ExampleName = "emscripten_damaged_helmet"
  ModelName = "DamagedHelmet.glb"
  ServerHost = "127.0.0.1"
  ServerPortNumber = 8080
  ServerPort = Port(ServerPortNumber)

proc guessContentType(path: string): string =
  ## Returns a basic content type for static files.
  let ext = splitFile(path).ext.toLowerAscii()
  case ext
  of ".html":
    "text/html; charset=utf-8"
  of ".js":
    "text/javascript; charset=utf-8"
  of ".wasm":
    "application/wasm"
  of ".data":
    "application/octet-stream"
  of ".css":
    "text/css; charset=utf-8"
  of ".json":
    "application/json; charset=utf-8"
  of ".png":
    "image/png"
  of ".jpg", ".jpeg":
    "image/jpeg"
  of ".svg":
    "image/svg+xml; charset=utf-8"
  else:
    "application/octet-stream"

proc isSafeRelativePath(relativePath: string): bool =
  ## Returns true when a relative path does not escape the root.
  if relativePath.len == 0:
    return true
  if relativePath.startsWith('/'):
    return false
  if '\0' in relativePath:
    return false
  for part in relativePath.split('/'):
    if part == "..":
      return false
  true

proc defaultDamagedHelmetPath(rootDir: string): string =
  ## Returns the first sibling Damaged Helmet GLB path that exists.
  let candidates = [
    rootDir / ".." / "glTF-Sample-Assets" / "Models" /
      "DamagedHelmet" / "glTF-Binary" / ModelName,
    rootDir / ".." / ".." / "glTF-Sample-Assets" / "Models" /
      "DamagedHelmet" / "glTF-Binary" / ModelName,
    getCurrentDir() / "glTF-Sample-Assets" / "Models" /
      "DamagedHelmet" / "glTF-Binary" / ModelName
  ]
  for candidate in candidates:
    if fileExists(candidate):
      return candidate
  candidates[0]

proc stagedDamagedHelmetPath(rootDir: string): string =
  ## Returns the Emscripten preload path for the Damaged Helmet GLB.
  rootDir / "examples" / "data" / ModelName

proc stageDamagedHelmet(rootDir, sourcePath: string) =
  ## Copies the Damaged Helmet GLB into the Emscripten preload directory.
  if not fileExists(sourcePath):
    quit("Damaged Helmet GLB not found: " & sourcePath, 1)

  let stagedPath = stagedDamagedHelmetPath(rootDir)
  createDir(stagedPath.parentDir())
  if sourcePath.absolutePath() != stagedPath.absolutePath():
    copyFile(sourcePath, stagedPath)
  echo "Staged asset: ", stagedPath

proc compileExample(rootDir: string) =
  ## Compiles the Damaged Helmet Emscripten example.
  if findExe("emcc").len == 0:
    quit("emcc was not found on PATH. Install or activate Emscripten.", 1)

  setCurrentDir(rootDir)
  let
    nimFile = "examples" / (ExampleName & ".nim")
    command = "nim c -d:emscripten " & nimFile
  echo "Compiling: ", command
  let exitCode = execCmd(command)
  if exitCode != 0:
    quit(exitCode)

proc openExample() =
  ## Opens the generated example in the default browser.
  let url = fmt"http://{ServerHost}:{ServerPortNumber}/{ExampleName}.html"
  openDefaultBrowser(url)

proc serveThread(server: Server) =
  ## Runs the server loop in a worker thread.
  {.gcsafe.}:
    server.serve(ServerPort, ServerHost)

proc serveEmscriptenDir(emscriptenDir: string) =
  ## Serves the Emscripten output directory until Ctrl-C.
  var router: Router

  router.get("/", proc(request: Request) {.gcsafe.} =
    let body = fmt"""<!doctype html>
<html><body>
<h1>glTF Emscripten Test</h1>
<ul><li><a href="/{ExampleName}.html">{ExampleName}.html</a></li></ul>
</body></html>"""

    var headers: HttpHeaders
    headers["Content-Type"] = "text/html; charset=utf-8"
    request.respond(200, headers, body)
  )

  router.get("/**", proc(request: Request) {.gcsafe.} =
    var relativePath = request.path
    if relativePath.startsWith('/'):
      relativePath = relativePath[1 .. ^1]

    if not isSafeRelativePath(relativePath):
      request.respond(403, emptyHttpHeaders(), "Forbidden")
      return

    var filePath = emscriptenDir / relativePath
    if dirExists(filePath):
      filePath = filePath / "index.html"

    if not fileExists(filePath):
      request.respond(404, emptyHttpHeaders(), "Not found")
      return

    let body = readFile(filePath)
    var headers: HttpHeaders
    headers["Content-Type"] = guessContentType(filePath)
    request.respond(200, headers, body)
  )

  let server = newServer(router)
  echo fmt"Serving {emscriptenDir} at http://{ServerHost}:{ServerPortNumber}/"
  echo "Press Ctrl-C to stop."

  when compileOption("threads"):
    var serverWorker: Thread[Server]
    createThread(serverWorker, serveThread, server)
    server.waitUntilReady()
    openExample()
    joinThread(serverWorker)
  else:
    echo fmt"Open http://{ServerHost}:{ServerPortNumber}/{ExampleName}.html"
    server.serve(ServerPort, ServerHost)

proc run() =
  ## Stages assets, compiles the example, and serves the output.
  let
    startDir = getCurrentDir()
    rootDir = currentSourcePath().parentDir.parentDir
    params = commandLineParams()
    sourcePath =
      if params.len > 0:
        params[0]
      else:
        defaultDamagedHelmetPath(rootDir)
    emscriptenDir = rootDir / "examples" / "emscripten"
  defer:
    setCurrentDir(startDir)

  echo "=== glTF Emscripten Damaged Helmet ==="
  stageDamagedHelmet(rootDir, sourcePath)
  compileExample(rootDir)
  serveEmscriptenDir(emscriptenDir)

run()
