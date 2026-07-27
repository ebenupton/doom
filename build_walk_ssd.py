#!/usr/bin/env python3
"""Build doom_walk.ssd — THE game disc, DUAL-MODE since 2026-07-21:
!BOOT is the Tube detector (tube/detect.asm); a 6502 copro gets the
Tube version (COPROT/HOSTT/CODE/DATA), a plain Model B + SWRAM chains
the banked WALK loader (machine-code ROMSEL boot via modelb_boot.asm),
walk_drv at $2000. Cursor keys: Left/Right turn, Up/Down move.

This file OWNS the banked side (banked_files()); the disc itself is
written by tube/build_tube_game.py, which main() delegates to — either
entry point produces the same single artifact."""
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
        disc[m+6] = ((ss>>8)&3) | (((load>>16)&3)<<2) | \
                    (((len(data)>>16)&3)<<4) | (((exe>>16)&3)<<6)
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


def _emit_variant_images():
    """Subprocess worker (--variant): build THIS process's DOOM_CPU
    variant end-to-end — engine link, engine_syms (symbol addresses
    DRIFT between the NMOS and C02 links, so WALKDRV must be
    re-assembled against each variant's map), driver, bank images —
    and write them to build/walk_{L0,C,L2,LOW}.bin for the parent."""
    import asmbuild
    c02 = 1 if os.environ.get('DOOM_CPU', '').lower() in ('65c02', 'c02', '1') else 0
    asmbuild.build_all(banked=1, c02=c02)
    asmbuild.gen_engine_syms()
    subprocess.run(['./beebasm', '-i', 'walk_drv.asm', '-D', 'BANKED=1'], check=True)
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
    for name, data in (('L0', L0), ('C', C), ('L2', L2), ('LOW', LOW)):
        with orig(f'build/walk_{name}.bin', 'wb') as f:
            f.write(data)
    import abi
    with orig('build/walk_SQRH.bin', 'wb') as f:
        f.write(bytes(anim_mem_sqrh()))


def anim_mem_sqrh():
    """The sqr HI pages (canonical generator — same bytes the flat
    harness seeds; banked home = $0200 since 2026-07-27)."""
    from span_clip_6502 import _gen_quarter_square
    sqr_l, sqr_h, sqr2_l, sqr2_h = _gen_quarter_square()
    return bytes(sqr_h) + bytes(sqr2_h)


def _banked_variant(c02):
    """Run the variant worker in a SUBPROCESS with DOOM_CPU set: the py65
    model, load_engine and asmbuild all key off that env at import time —
    flipping it in-process would silently re-link the wrong CPU (the same
    reason the tube builder sets 65c02 only in its own step)."""
    import sys
    env = dict(os.environ)
    if c02:
        env['DOOM_CPU'] = '65c02'
    else:
        env.pop('DOOM_CPU', None)
    subprocess.run([sys.executable, os.path.abspath(__file__), '--variant'],
                   env=env, check=True)
    out = []
    for name in ('L0', 'C', 'L2', 'LOW'):
        with builtins.open(f'build/walk_{name}.bin', 'rb') as f:
            out.append(f.read())
    return out


def banked_files():
    """Build the banked (plain Model B) side and return its DFS file list.
    The boot loader is named WALK here — the dual disc's !BOOT is the
    Tube detector, which chains *RUN WALK on a machine with no copro.
    WALK itself then CPU-probes (opcode &1A: INC A on a 65C02, NOP on
    NMOS) and loads LOWC/BANK1C instead of LOW/BANK1 on a C02 host —
    the L0/L2 banks are data-only and ship once (asserted below).
    MUST run with DOOM_CPU unset/NMOS: the banked build targets the
    host CPU per variant (the tube builder sets 65c02 only AFTER this)."""
    # (ptrtab asserts retired 2026-07-10: layout drift is gated by
    # doom_wireframe's layout.inc check on import)
    build_floor_grid()
    L0c, Cc, L2c, LOWc = _banked_variant(c02=1)      # C02 first: leave the
    L0, C, L2, LOW = _banked_variant(c02=0)          # NMOS artifacts (WALKDRV,
                                                     # engine_syms) as the
                                                     # repo's resting state
    assert L0c == L0 and L2c == L2, \
        'L0/L2 bank images differ between CPU variants — banks are data-only ' \
        '(code in banks is forbidden outside C); a CPU-dependent byte in ' \
        'L0/L2 means the variants need their own copies AND a loader change'
    subprocess.run(['./beebasm', '-i', 'modelb_boot.asm', '-D', 'BANKED=1'], check=True)
    BOOT = builtins.open('!BOOT', 'rb').read()
    import abi
    SQRH = LOW_sqrh = None
    # the HI pages live at $0200 in the model images; ship them as their
    # own file (staged $3000 by the boot, copied down post-OS)
    with builtins.open('build/walk_SQRH.bin', 'rb') as f:
        SQRH = f.read()
    return [
        ('WALK',  0x1900, 0x1900, BOOT),
        ('SQRH',  0x7000, 0x7000, SQRH),
        ('BANK0', 0x3000, 0x3000, L0),
        ('BANK1', 0x3000, 0x3000, C),
        ('BANK2', 0x3000, 0x3000, L2),
        ('LOW',   0x1C00, 0x1C00, LOW),
        ('BANK1C', 0x3000, 0x3000, Cc),
        ('LOWC',  0x1C00, 0x1C00, LOWc),
    ]


def main():
    import subprocess as sp, sys
    sp.run([sys.executable, 'tube/build_tube_game.py'], check=True)


if __name__ == '__main__':
    import sys
    if '--variant' in sys.argv:
        _emit_variant_images()
    else:
        main()
