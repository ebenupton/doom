#!/usr/bin/env python3
"""Build doom_tube.ssd — the Tube (6502 second processor) game disc.

The parasite runs the FLAT engine build VERBATIM: this script constructs
the full py65 64K image exactly as the regression harness does
(BspRender6502.__init__: engine link + tables + packed E1M1), then makes
exactly three surgical changes:
  - the NJ rasteriser blob at $A900 is replaced by the Tube emitters
    (tube/emit.asm) — dcl's des_diag JMP $A900 needs no patch at all;
  - plot_h and plot_v entries are poked to JMP $A910/$A920 (the h/v
    emitters). Everything else is byte-identical to the flat build.
The occupied regions are chunked into DFS data files that the copro
bootstrap (tube/tubedrv.asm) *LOADs across the Tube via the parasite OS
before killing the host OS with its raw RUN HOSTT.

Files: !BOOT (tube/detect.asm), COPROT (tubedrv: bootstrap + driver +
tables), HOSTT (tube/hostg.asm: carousel + plot_h/v + real NJ), D0..Dn
(parasite image chunks).
"""
import os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.chdir(ROOT)
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')

SECTOR = 256
TOTAL_SECTORS = 800
SPAWN_X, SPAWN_Y = 1056, -3616
SPAWN_ANGIDX = 16               # angle byte 64, walk_drv's spawn facing
DRIVER_HOME = (0xEA00, 0xF800)  # COPROT in the FB region (engine never writes it)


def write_ssd(files, path):
    disc = bytearray(TOTAL_SECTORS * SECTOR)
    disc[0:8] = b'DOOMTB\x00\x00'
    n = len(files); assert n <= 31, n
    disc[SECTOR + 5] = n * 8
    nxt = 2; secs = []
    for _, _, _, data in files:
        ns = (len(data) + SECTOR - 1) // SECTOR
        secs.append((nxt, ns)); nxt += ns
    total = nxt; assert total <= TOTAL_SECTORS
    disc[SECTOR + 6] = (2 << 4) | ((total >> 8) & 3)
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
        print(f"  {name:7s} &{load:05X}  {len(data):>5} B  sec {secs[i][0]}")


def asm(src, out):
    subprocess.run([os.path.join(ROOT, 'beebasm'), '-i', src],
                   cwd=ROOT, check=True)
    with open(os.path.join(ROOT, out), 'rb') as f:
        data = f.read()
    os.remove(os.path.join(ROOT, out))
    return data


def main():
    import pygame; pygame.init()
    import doom_wireframe as dw
    from bsp_render_6502 import BspRender6502
    import symmap, abi
    import build_anim_ssd as anim
    import build_walk_ssd as walkbuild

    def fsym(name):
        return symmap.sym(name)          # flat build (banked=0 default)

    # ---- full parasite image, exactly the regression harness's memory ----
    r = BspRender6502(dw.packed_layout, dw.packed_rom_main,
                      dw.packed_rom_detail, dw.packed_bbox_table,
                      dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    mem = bytearray(r.sc.mpu.memory[0:0x10000])

    # ---- the three surgical changes ----
    emit = asm('tube/emit.asm', 'EMIT')
    mem[0x6200:0x6B00] = bytes(0x6B00 - 0x6200)     # drop the NJ blob
    mem[0x6200:0x6200 + len(emit)] = emit
    for name, target in (('plot_h', 0x6210), ('plot_v', 0x6220)):
        a = fsym(name)
        mem[a] = 0x4C
        mem[a+1] = target & 0xFF
        mem[a+2] = target >> 8
        print(f"  poked {name} @ &{a:04X} -> JMP &{target:04X}")

    # ---- TWO LOADS (Eben's spec): CODE = engine + NJ/emitters,
    # DATA = level + tables (+anim/sincos). The 2026-07-21 map makes both
    # contiguous; the cache block is runtime-only and never shipped.
    CODE_LO, CODE_HI = 0x1C00, 0x6B00   # sqr tables ride in the CODE file
    DATA_LO, DATA_HI = 0x8600, 0xEA00
    # guard: nothing nonzero outside the shipped spans + runtime regions
    for a in range(0x0400, 0xF7F0):
        if mem[a] and not (CODE_LO <= a < CODE_HI or DATA_LO <= a < DATA_HI
                           or 0x0400 <= a < 0x2000 or 0x6B00 <= a < 0x8600):
            raise AssertionError(f"unshipped nonzero byte at &{a:04X}")
    # (high check: VATOX now ends at $E701 — nothing above $E9FF but FB)
    for a in range(0xEA00, 0xF7F0):
        assert not mem[a], f"nonzero in FB region &{a:04X}"

    runs = []                              # (census retired: two spans)

    # ---- generated includes: engine syms + spawn, load list ----
    px88 = int((SPAWN_X - dw.MAP_CENTER_X) * 256 / dw.PRESCALE) & 0xFFFFFF
    py88 = int((SPAWN_Y - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE) & 0xFFFFFF
    vz = dw._prescale_height(dw.player_floor(SPAWN_X, SPAWN_Y) + 41) & 0xFF
    with open('tube/tube_syms.inc', 'w') as f:
        f.write("\\ GENERATED by tube/build_tube_game.py - DO NOT EDIT.\n")
        for t, s in (('T_VIEW_SETUP', 'br_view_setup'),
                     ('T_SPAN_INIT', 'span_init'),
                     ('T_RENDER_FRAME', 'br_render_frame'),
                     ('T_TAIL_POSTRC', 'bca_tail_postrc'),
                     ('T_BOX_CLASSIFY', 'box_classify'),
                     ('T_ANIM_INIT', 'anim_init'),
                     ('T_ANIM_TICK', 'anim_tick'),
                     ('T_ANIM_ENABLE', 'ANIM_ENABLE'),
                     ('T_CPM_KDXH', 'CPM_KDXH')):
            f.write(f"{t} = &{fsym(s):04X}\n")
        f.write(f"T_RCACHE_STATE = &{0xF100:04X}\n")
        f.write(f"T_RCACHE_LEN = &{abi.RCACHE_STATE_LEN & 0xFF:02X}\n")
        f.write(f"T_VXC_STATE = &{abi.VXC_STATE:04X}\n")
        f.write(f"T_VXC_LEN = &{abi.VXC_STATE_LEN:02X}\n")
        f.write(f"T_VXC_ENABLE = &{abi.VXC_ENABLE:04X}\n")
        f.write(f"T_CPM_BASE = &5500\n")
        f.write(f"T_BCA_AB = &{fsym('bca_ab'):04X}\n")
        f.write(f"SPAWN_ANGIDX = {SPAWN_ANGIDX}\n")
        f.write(f"SPAWN_PXF = &{px88 & 0xFF:02X}\n")
        f.write(f"SPAWN_PXL = &{(px88 >> 8) & 0xFF:02X}\n")
        f.write(f"SPAWN_PXH = &{(px88 >> 16) & 0xFF:02X}\n")
        f.write(f"SPAWN_PYF = &{py88 & 0xFF:02X}\n")
        f.write(f"SPAWN_PYL = &{(py88 >> 8) & 0xFF:02X}\n")
        f.write(f"SPAWN_PYH = &{(py88 >> 16) & 0xFF:02X}\n")
        f.write(f"SPAWN_VZ = &{vz:02X}\n")

    with open('tube/tube_loads.inc', 'w') as f:
        f.write("\\ GENERATED by tube/build_tube_game.py - DO NOT EDIT.\n")
        f.write('    EQUS "LOAD CODE"\n    EQUB 13\n')
        f.write('    EQUS "LOAD DATA"\n    EQUB 13\n')
        f.write("    EQUB 0\n")

    # ---- driver tables ----
    open('SINCOS.bin', 'wb').write(anim.sincos_table())
    walkbuild.build_floor_grid()            # writes FLOORGRD.bin

    # ---- assemble the three programs ----
    detect = asm('tube/detect.asm', 'DETECT')
    coprot = asm('tube/tubedrv.asm', 'COPROT')
    hostt = asm('tube/hostg.asm', 'HOSTT')

    # ---- the regular (no-tube) game rides along: files lifted from
    # doom_walk.ssd (its !BOOT loader becomes WALK; detect chains it) ----
    walk = open(os.path.join(ROOT, 'doom_walk.ssd'), 'rb').read()
    nfiles = walk[0x105] // 8
    walk_files = []
    for i in range(nfiles):
        off = (i + 1) * 8
        name = walk[off:off+7].decode().rstrip()
        m = 0x100 + (i + 1) * 8
        load = walk[m] | (walk[m+1] << 8) | (((walk[m+6] >> 2) & 3) << 16)
        exe = walk[m+2] | (walk[m+3] << 8) | (((walk[m+6] >> 6) & 3) << 16)
        ln = walk[m+4] | (walk[m+5] << 8) | (((walk[m+6] >> 4) & 3) << 16)
        sec = walk[m+7] | ((walk[m+6] & 3) << 8)
        data = walk[sec*256: sec*256 + ln]
        walk_files.append(('WALK' if name == '!BOOT' else name, load, exe, data))
    files = [('!BOOT', 0x30900, 0x30900, detect),
             ('COPROT', 0x0EA00, 0x0EA00, coprot),
             ('HOSTT', 0x31900, 0x31900, hostt),
             ('CODE', CODE_LO, CODE_LO, bytes(mem[CODE_LO:CODE_HI])),
             ('DATA', DATA_LO, DATA_LO, bytes(mem[DATA_LO:DATA_HI]))]
    files += walk_files
    write_ssd(files, os.path.join(ROOT, 'doom_tube.ssd'))


if __name__ == '__main__':
    main()
