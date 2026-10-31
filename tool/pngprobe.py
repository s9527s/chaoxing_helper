import struct
import sys
import zlib


def load_png(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    pos = 8
    idat = b''
    w = h = bitdepth = colortype = None
    while pos < len(data):
        length = struct.unpack('>I', data[pos:pos + 4])[0]
        ctype = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        if ctype == b'IHDR':
            w, h, bitdepth, colortype = struct.unpack('>IIBB', chunk[:10])
        elif ctype == b'IDAT':
            idat += chunk
        elif ctype == b'IEND':
            break
        pos += 12 + length
    raw = zlib.decompress(idat)
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colortype]
    assert bitdepth == 8, bitdepth
    stride = w * channels
    out = bytearray(h * stride)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if f == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif f == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                pa = abs(b - c)
                pb = abs(a - c)
                pc = abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, channels, bytes(out)


def bbox_of_color(path, predicate, y_min=0):
    w, h, ch, pixels = load_png(path)
    minx, miny, maxx, maxy = w, h, -1, -1
    count = 0
    for y in range(y_min, h):
        base = y * w * ch
        for x in range(w):
            i = base + x * ch
            r, g, b = pixels[i], pixels[i + 1], pixels[i + 2]
            if predicate(r, g, b):
                count += 1
                if x < minx:
                    minx = x
                if x > maxx:
                    maxx = x
                if y < miny:
                    miny = y
                if y > maxy:
                    maxy = y
    if maxx < 0:
        return None
    return (minx, miny, maxx, maxy, count)


if __name__ == '__main__':
    path = sys.argv[1]
    mode = sys.argv[2] if len(sys.argv) > 2 else 'blue'
    y_min = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    if mode == 'blue':
        pred = lambda r, g, b: b > 170 and r < 120 and g < 150 and b - r > 60
    elif mode == 'white':
        pred = lambda r, g, b: r > 245 and g > 245 and b > 245
    else:
        pred = lambda r, g, b: abs(r - int(mode[0:2], 16)) < 12 and abs(g - int(mode[2:4], 16)) < 12 and abs(b - int(mode[4:6], 16)) < 12
    print(path, mode, bbox_of_color(path, pred, y_min))
