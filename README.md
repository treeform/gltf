# glTF Library and Viewer for Nim

## Introduction

I think glTF is one of the best 3D formats to appear in a long
time. Before glTF, the 3D format landscape was terrible. There were many
proprietary formats, all scattered across different tools and
engines. They supported different kinds of textures, and very few of
them were truly compatible with each other. Even if you could load a
format in one engine, it often still looked wrong.

The closest thing before glTF was COLLADA, which I used for a while.
But COLLADA often felt like an angry XML format with far too many ways
to do the same thing. Different files would often need slightly
different parsers, which made the whole ecosystem frustrating to work
with.

glTF changed that, especially for games. When it arrived during the
WebGL era, it felt like a godsend. It was easy to read, easy to parse,
and based on a clear standard. PBR also helped a lot. Physically based
rendering made the format much more universal, because you could load a
model in one viewer and expect it to look roughly the same in another,
as long as both supported PBR. The industry started converging on a
shared PBR standard, and that made a huge difference.

This project provides both a Nim library and a viewer for glTF. You can
use it in three main ways:

- Compile the viewer and use it to inspect glTF models.
- Use the library to load glTF data and work with it in your own code.
- Reuse parts of the renderer as a small 3D game engine of your own.

Many parts are still incomplete. Work is ongoing to support more of the
format and to make the PBR rendering match the glTF specification as
closely as possible.

This README will cover:

- What is currently supported.
- What is not yet supported.
- How to run the viewer and load many glTF file variations.
- How to use the library in your own engine to load and inspect data.
- How to load everything together to build a small game engine.

The examples here use the usual libraries I tend to use, such as
`windy` and `silky`, but you do not have to use those. You can plug the
loader into your own setup instead.
