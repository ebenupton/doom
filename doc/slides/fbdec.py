"""BBC mode-4 framebuffer bytes -> RGB image (phosphor styled)."""
from PIL import Image
W, H = 256, 160
def decode(fbbytes, fg=(96, 240, 150), bg=(9, 14, 11), alpha=False):
    """alpha=True leaves the unlit pixels transparent, so one frame can be
    drawn over another (e.g. a ghost of the finished frame underneath)."""
    if alpha:
        im = Image.new('RGBA', (W, H), (0, 0, 0, 0)); fg = fg + (255,)
    else:
        im = Image.new('RGB', (W, H), bg)
    px = im.load()
    for cy in range(20):
        for col in range(32):
            base = cy * 32 * 8 + col * 8
            for pr in range(8):
                y = cy * 8 + pr
                if y >= H: break
                b = fbbytes[base + pr]
                for bit in range(8):
                    if b & (0x80 >> bit):
                        px[col * 8 + bit, y] = fg
    return im
