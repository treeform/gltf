from PIL import Image
import pathlib, struct, zlib

out = pathlib.Path(__file__).parent
out.mkdir(parents=True, exist_ok=True)
image = Image.new('RGBA', (5, 1))
image.putdata([(64, 128, 192, alpha) for alpha in [0, 1, 64, 128, 255]])
image.save(out / 'rgba.png')
image.save(out / 'lossless.webp', lossless=True, exact=True)
image.save(out / 'lossy.webp', quality=100, exact=True)
image.convert('RGB').save(out / 'rgb.jpg', quality=100, subsampling=0)
palette = Image.new('P', (2, 1))
palette.putpalette([0, 255, 0, 64, 128, 192] + [0] * 762)
palette.putdata([0, 1])
palette.save(out / 'palette.png', transparency=bytes([0, 128]))
ga = Image.new('LA', (2, 1))
ga.putdata([(128, 0), (192, 64)])
ga.save(out / 'gray_alpha.png')
def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
rgba16 = b'\0' + struct.pack('>8H', 0x1234, 0xabcd, 0x5678, 0, 0xffff, 0x8000, 0x4000, 0x8000)
png16 = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 1, 16, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rgba16)) + chunk(b'IEND', b'')
(out / 'rgba16.png').write_bytes(png16)
for name in ['lossless.webp', 'lossy.webp', 'rgb.jpg']:
    decoded = Image.open(out / name).convert('RGBA')
    (out / (name + '.rgba')).write_bytes(decoded.tobytes())
print('Generated small PNG/JPEG/WebP fixtures with known straight-alpha pixels.')
