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
DRIVER_HOME = (0x5800, 0x6C00)  # COPROT in the FB region (engine never writes it)


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
    mem[0xA900:0xB600] = bytes(0xB600 - 0xA900)     # drop the NJ blob
    mem[0xA900:0xA900 + len(emit)] = emit
    for name, target in (('plot_h', 0xA910), ('plot_v', 0xA920)):
        a = fsym(name)
        mem[a] = 0x4C
        mem[a+1] = target & 0xFF
        mem[a+2] = target >> 8
        print(f"  poked {name} @ &{a:04X} -> JMP &{target:04X}")

    # ---- census: occupied runs -> DFS chunks ----
    # ZP/stack/driver home excluded; gaps under 64 bytes merge (fewer files
    # at the cost of shipping a few zeros).
    runs = []
    a = 0x0400
    while a < 0xF7F0:
        if mem[a]:
            s = a
            gap = 0
            while a < 0xF7F0 and gap < 64:
                gap = gap + 1 if not mem[a] else 0
                a += 1
            runs.append((s, a - gap - s))
        else:
            a += 1
    for s, l in runs:
        assert not (s < DRIVER_HOME[1] and s + l > DRIVER_HOME[0]), \
            f"census run &{s:04X}+{l} collides with the driver home"
    assert len(runs) <= 24, runs
    covered = lambda lo, hi: any(s <= lo and s + l >= hi for s, l in runs)
    assert covered(0xA900, 0xA900 + len(emit)), "emitters not fully shipped"
    print(f"  census: {len(runs)} runs, {sum(l for _, l in runs)} bytes")

    # ---- high table ($F800+): the client OS EXECUTES from $F9xx/$FBxx
    # during the cross-Tube loads, so anything living up there cannot be
    # DFS-loaded in place — it ships STAGED in the free FB region and the
    # driver copies it up once the client is dead (post RUN HOSTT).
    hi_runs = []
    a = 0xF800
    while a < 0xFFF8:
        if mem[a]:
            s = a; gap = 0
            while a < 0xFFF8 and gap < 64:
                gap = gap + 1 if not mem[a] else 0
                a += 1
            hi_runs.append((s, a - gap - s))
        else:
            a += 1
    assert len(hi_runs) <= 1, f"multiple high runs: {hi_runs} — extend the stager"
    HITAB_STAGE = 0x6400
    if hi_runs:
        hs, hl = hi_runs[0]
        assert HITAB_STAGE + hl <= 0x6C00, "high table too big for the stage"
        print(f"  high table &{hs:04X}+{hl} staged at &{HITAB_STAGE:04X}")
    else:
        hs, hl = 0xF800, 0

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
                     ('T_ANIM_ENABLE', 'ANIM_ENABLE')):
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
        f.write(f"HITAB_STAGE = &{HITAB_STAGE:04X}\n")
        f.write(f"HITAB_DST = &{hs:04X}\n")
        f.write(f"HITAB_LEN = &{hl:04X}\n")
    with open('tube/tube_loads.inc', 'w') as f:
        f.write("\\ GENERATED by tube/build_tube_game.py - DO NOT EDIT.\n")
        for i in range(len(runs)):
            f.write(f'    EQUS "LOAD D{i}"\n    EQUB 13\n')
        if hl:
            f.write('    EQUS "LOAD HITAB"\n    EQUB 13\n')
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
             ('COPROT', 0x05800, 0x05800, coprot),
             ('HOSTT', 0x31900, 0x31900, hostt)]
    for i, (s, l) in enumerate(runs):
        files.append((f'D{i}', s, s, bytes(mem[s:s+l])))
    if hl:
        files.append(('HITAB', HITAB_STAGE, HITAB_STAGE, bytes(mem[hs:hs+hl])))
    files += walk_files
    write_ssd(files, os.path.join(ROOT, 'doom_tube.ssd'))


if __name__ == '__main__':
    main()
