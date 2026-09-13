# MikkTSpace

`mikktspace.c` and `mikktspace.h` are unmodified canonical sources from
https://github.com/mmikk/MikkTSpace at commit
`3e895b49d05ea07e4c2133156cfa94369e19e409`.

Copyright 2011 Morten S. Mikkelsen. The permissive zlib-style license is retained
at the top of both files. `bridge.c` is this library's adapter for packed Nim
vertex arrays. These files compile with the application; no extra runtime or
shared library installation is required.

The glTF reader calls MikkTSpace for primitives without authored tangents,
using the same base-pose positions, normals and UV set 0 as the pinned Khronos
renderer. MikkTSpace emits one tangent/sign per triangle corner. The Nim wrapper
duplicates vertices only when those results disagree for a shared index,
remapping all vertex attributes and morph targets together.

The adapter negates MikkTSpace's orientation sign, matching the Khronos
renderer’s conversion to glTF texture coordinates. The shader then reconstructs
`bitangent = tangent.w * cross(normal, tangent.xyz)`. Authored glTF tangents
already use that convention and are never negated by the importer.
