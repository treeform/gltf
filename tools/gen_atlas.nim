import silky

let builder = newAtlasBuilder(1024, 4)
builder.addDir("tools/theme/", "tools/theme/")
builder.addFont("tools/theme/IBMPlexSans.ttf", "H1", 28.0)
builder.addFont("tools/theme/IBMPlexSans.ttf", "Default", 18.0)
builder.write("tools/dist/atlas.png")
