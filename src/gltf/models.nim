type
  Primitive* = object
    name*: string

  Mesh* = object
    name*: string
    primitives*: seq[Primitive]

  Node* = object
    name*: string
    mesh*: int
    children*: seq[int]

  Scene* = object
    name*: string
    nodes*: seq[int]

  Document* = object
    scenes*: seq[Scene]
    nodes*: seq[Node]
    meshes*: seq[Mesh]
