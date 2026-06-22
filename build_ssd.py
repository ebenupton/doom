#!/usr/bin/env python3
"""Build doom_e1m1.ssd disc image from assembled components."""
import os, struct
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
from fe6502 import _gen_quarter_square

SECTOR_SIZE = 256
TRACKS = 80
SECTORS_PER_TRACK = 10
TOTAL_SECTORS = TRACKS * SECTORS_PER_TRACK
SSD_SIZE = TOTAL_SECTORS * SECTOR_SIZE

def build_ssd(output_path='doom_e1m1.ssd'):
    # Collect all files for the disc
    files = []

    # 1. !BOOT (loader) — load at $0900, exec at $0900
    loader_bin = open('doom_loader.bin', 'rb').read()
    files.append(('!BOOT', 0x0900, 0x0900, loader_bin))

    # 2. BANK0 — rom_banks[0], load at $3000
    files.append(('BANK0', 0x3000, 0x3000, bytes(dw.packed_rom_banks[0])))

    # 3. BANK1 — rom_banks[1], load at $3000
    files.append(('BANK1', 0x3000, 0x3000, bytes(dw.packed_rom_banks[1])))

    # 4. BANK2 — rom_banks[2], load at $3000
    files.append(('BANK2', 0x3000, 0x3000, bytes(dw.packed_rom_banks[2])))

    # 5. CODE — doom_fe.bin, load at $22D2
    code_bin = open('doom_fe.bin', 'rb').read()
    files.append(('CODE', 0x22D2, 0x22D2, code_bin))

    # 6. RECIP — reciprocal + sin/cos tables, load at $4F7E
    files.append(('RECIP', 0x4F7E, 0x4F7E, bytes(dw.packed_rom_recip)))

    # 7. QSQ — quarter-square tables, load at $5400
    sqr_lo, sqr_hi, sqr2_lo, sqr2_hi = _gen_quarter_square()
    qsq = bytes(sqr_lo) + bytes(sqr_hi) + bytes(sqr2_lo) + bytes(sqr2_hi)
    files.append(('QSQ', 0x5400, 0x5400, qsq))

    # Build DFS disc image
    disc = bytearray(SSD_SIZE)

    # DFS catalogue: sector 0 (filenames) and sector 1 (metadata)
    # Files are stored in reverse order in the catalogue
    n_files = len(files)
    assert n_files <= 31, "DFS supports max 31 files"

    # Sector 0: Title (12 bytes) + filenames (8 bytes each, up to 31)
    # Bytes 0-7: Title (padded with spaces/nulls)
    title = b'DOOM\x00\x00\x00\x00'
    disc[0:8] = title

    # Sector 1: bytes 0-3: title continued, byte 4: write count,
    # byte 5: n_files * 8, bytes 6-7: boot option + sector count
    disc[SECTOR_SIZE + 0:SECTOR_SIZE + 4] = b'\x00\x00\x00\x00'
    disc[SECTOR_SIZE + 4] = 0  # write/cycle count
    disc[SECTOR_SIZE + 5] = n_files * 8

    # Calculate file positions on disc (starting from sector 2)
    next_sector = 2
    file_sectors = []
    for name, load, exec_addr, data in files:
        n_sectors = (len(data) + SECTOR_SIZE - 1) // SECTOR_SIZE
        file_sectors.append((next_sector, n_sectors))
        next_sector += n_sectors

    total_sectors = next_sector
    assert total_sectors <= TOTAL_SECTORS, f"Disc full: {total_sectors} > {TOTAL_SECTORS}"

    # Boot option: 2 = *RUN !BOOT (bits 4-5 of sector 1 byte 6)
    # Sector count high bits in bits 0-1 of byte 6
    boot_opt = 2  # *RUN
    sec_hi = (total_sectors >> 8) & 0x03
    disc[SECTOR_SIZE + 6] = (boot_opt << 4) | sec_hi
    disc[SECTOR_SIZE + 7] = total_sectors & 0xFF

    # Write file entries (in reverse order in catalogue)
    for i, (name, load, exec_addr, data) in enumerate(files):
        start_sec, n_sec = file_sectors[i]

        # Sector 0: filename entry at offset (i+1)*8
        # 7 chars filename padded with spaces, byte 7 = directory | top bits
        fname = name.encode('ascii')[:7].ljust(7, b' ')
        cat_off = (i + 1) * 8  # entries start at offset 8 (after title)
        disc[cat_off:cat_off + 7] = fname
        # Byte 7: directory char (top bit = locked flag). '$' = default dir
        disc[cat_off + 7] = ord('$')

        # Sector 1: metadata at offset (i+1)*8
        meta_off = SECTOR_SIZE + (i + 1) * 8
        disc[meta_off + 0] = load & 0xFF
        disc[meta_off + 1] = (load >> 8) & 0xFF
        disc[meta_off + 2] = exec_addr & 0xFF
        disc[meta_off + 3] = (exec_addr >> 8) & 0xFF
        disc[meta_off + 4] = len(data) & 0xFF
        disc[meta_off + 5] = (len(data) >> 8) & 0xFF
        # Byte 6: bits 1-0 = exec addr bits 17-16
        #          bits 3-2 = length bits 17-16
        #          bits 5-4 = load addr bits 17-16
        #          bits 7-6 = start sector bits 9-8
        extra = ((exec_addr >> 16) & 0x03) | \
                (((len(data) >> 16) & 0x03) << 2) | \
                (((load >> 16) & 0x03) << 4) | \
                (((start_sec >> 8) & 0x03) << 6)
        disc[meta_off + 6] = extra
        disc[meta_off + 7] = start_sec & 0xFF

        # Write file data
        data_off = start_sec * SECTOR_SIZE
        disc[data_off:data_off + len(data)] = data

    with open(output_path, 'wb') as f:
        f.write(disc)

    print(f"Built {output_path}: {SSD_SIZE} bytes")
    print(f"  Files: {n_files}, Sectors used: {total_sectors}/{TOTAL_SECTORS}")
    for i, (name, load, exec_addr, data) in enumerate(files):
        start_sec, n_sec = file_sectors[i]
        print(f"  {name:8s} ${load:04X}  {len(data):>6,} B  sec {start_sec}-{start_sec+n_sec-1}")

if __name__ == '__main__':
    # First assemble the loader
    import subprocess
    subprocess.run(['./beebasm', '-D', 'BANKED=0', '-i', 'doom_loader.asm', '-o', 'doom_loader.bin'], check=True)
    build_ssd()
