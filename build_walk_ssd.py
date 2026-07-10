#!/usr/bin/env python3
"""Build doom_walk.ssd: an autobooting WALKABLE E1M1 wireframe for a plain
Model B + SWRAM (same machine-code ROMSEL boot as doom_modelb.ssd), with
walk_drv (keyboard-driven position/angle) overlaid at $3C00 instead of the
spin driver. Cursor keys: Left/Right turn, Up/Down move forward/back."""
import os, subprocess, builtins
os.environ.setdefault('DOOM_ANIM', '1')     # animated doors/lifts on the disc
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import build_anim_ssd as anim
import build_modelb_ssd as modelb


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
    modelb.write_ssd(files, path='doom_walk.ssd')


if __name__ == '__main__':
    main()
