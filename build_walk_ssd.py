#!/usr/bin/env python3
"""Build doom_walk.ssd: an autobooting WALKABLE E1M1 wireframe for a plain
Model B + SWRAM (machine-code ROMSEL boot via modelb_boot.asm), with
walk_drv (keyboard-driven position/angle) overlaid at $2000 instead of the
spin driver. Cursor keys: Left/Right turn, Up/Down move forward/back."""
import os, subprocess, builtins
os.environ.setdefault('DOOM_ANIM', '1')     # animated doors/lifts on the disc
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import build_anim_ssd as anim
SECTOR = 256
TOTAL_SECTORS = 800


def write_ssd(files, path='doom_walk.ssd'):
    """Acorn DFS single-sided image, boot option 2 (*RUN !BOOT).
    (Inlined from the GC'd build_modelb_ssd.py, 2026-07-12.)"""
    disc = bytearray(TOTAL_SECTORS * SECTOR)
    disc[0:8] = b'DOOMB\x00\x00\x00'
    n = len(files); assert n <= 31
    disc[SECTOR + 5] = n * 8
    nxt = 2; secs = []
    for _, _, _, data in files:
        ns = (len(data) + SECTOR - 1) // SECTOR
        secs.append((nxt, ns)); nxt += ns
    total = nxt; assert total <= TOTAL_SECTORS, f"disc full {total}"
    disc[SECTOR + 6] = (2 << 4) | ((total >> 8) & 3)   # boot option 2 = *RUN
    disc[SECTOR + 7] = total & 0xFF
    for i, (name, load, exe, data) in enumerate(files):
        ss, _ = secs[i]; off = (i + 1) * 8
        disc[off:off+7] = name.encode().ljust(7, b' ')[:7]
        disc[off + 7] = ord('$')
        m = SECTOR + (i + 1) * 8
        disc[m+0] = load & 0xFF; disc[m+1] = (load >> 8) & 0xFF
        disc[m+2] = exe & 0xFF;  disc[m+3] = (exe >> 8) & 0xFF
        disc[m+4] = len(data) & 0xFF; disc[m+5] = (len(data) >> 8) & 0xFF
        disc[m+6] = (((exe>>16)&3)) | (((len(data)>>16)&3)<<2) | \
                    (((load>>16)&3)<<4) | (((ss>>8)&3)<<6)
        disc[m+7] = ss & 0xFF
        disc[ss*SECTOR: ss*SECTOR + len(data)] = data
    open(path, 'wb').write(disc)
    print(f"Built {path}: {n} files, {total}/{TOTAL_SECTORS} sectors")
    for i, (name, load, exe, data) in enumerate(files):
        print(f"  {name:7s} ${load:04X}  {len(data):>6} B  sec {secs[i][0]}")




def build_floor_grid():
    """36x22 grid of prescaled VZ (player_floor+41) at 128-unit cells over
    the walk clamp bounds; sampled from the Python float BSP."""
    import doom_wireframe as dw
    RAWX_MIN, RAWY_MIN = -1936, -1582
    COLS, ROWS, CELL = 36, 22, 128
    grid = bytearray(COLS * ROWS)
    fallback = dw._prescale_height(dw.player_floor(1056, -3616) + 41) & 0xFF
    for r in range(ROWS):
        for c in range(COLS):
            wx = dw.MAP_CENTER_X + RAWX_MIN + c * CELL + CELL // 2
            wy = dw.MAP_CENTER_Y + RAWY_MIN + r * CELL + CELL // 2
            try:
                grid[r * COLS + c] = dw._prescale_height(
                    dw.player_floor(wx, wy) + 41) & 0xFF
            except Exception:
                grid[r * COLS + c] = fallback
    open('FLOORGRD.bin', 'wb').write(bytes(grid))


def main():
    import asmbuild
    asmbuild.build_all(banked=1, c02=0)
    asmbuild.gen_engine_syms()
    # The drivers' ptrtab EQUBs are hardcoded window addresses — assert they
    # match the packed layout so a layout change can't ship a stale table.
    import doom_wireframe as dw
    lay = dw.packed_layout
    # (ptrtab asserts retired 2026-07-10: layout drift is gated by
    # doom_wireframe's layout.inc check on import)
    build_floor_grid()
    subprocess.run(['./beebasm', '-i', 'walk_drv.asm', '-D', 'BANKED=1'], check=True)
    subprocess.run(['./beebasm', '-i', 'modelb_boot.asm', '-D', 'BANKED=1'], check=True)
    orig = builtins.open
    def swap(path, *a, **k):
        if path == 'ANIMDRV':
            path = 'WALKDRV'
        return orig(path, *a, **k)
    builtins.open = swap
    try:
        L0, C, L2, LOW = anim.build_images()
    finally:
        builtins.open = orig
    BOOT = orig('!BOOT', 'rb').read()
    files = [
        ('!BOOT', 0x1900, 0x1900, BOOT),
        ('BANK0', 0x3000, 0x3000, L0),
        ('BANK1', 0x3000, 0x3000, C),
        ('BANK2', 0x3000, 0x3000, L2),
        ('LOW',   0x1B40, 0x1B40, LOW),
    ]
    write_ssd(files, path='doom_walk.ssd')


if __name__ == '__main__':
    main()
