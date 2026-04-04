"""Python wrapper for the 6502 DOOM front-end (doom_fe.bin).

Loads the assembled binary + WAD data into py65, runs the front-end for
a given player state, and returns the command list for the Python back-end.
"""
import os
from py65.devices.mpu6502 import MPU


# Memory map (must match doom_fe.asm)
ROM_MAIN_BASE   = 0x2000
ROM_DETAIL_BASE = 0x6000
QSQ_BASE        = 0xA000
ROM_RECIP_BASE  = 0xA400
CODE_BASE       = 0xC000
CMD_BUFFER      = 0x0300

# ZP addresses
ZP_PX_INT = 0x10
ZP_PY_INT = 0x11
ZP_PX_LO  = 0x12
ZP_PY_LO  = 0x13
ZP_VZ_PS  = 0x14
ZP_ANGLE  = 0x15

# Layout offsets (stored in RAM, accessed from 6502 code)
LAYOUT_OFF_VERTS   = 0x0BF0
LAYOUT_OFF_NODES   = 0x0BF2
LAYOUT_OFF_SS      = 0x0BF4
LAYOUT_OFF_SEG_HDR = 0x0BF6
LAYOUT_N_NODES     = 0x0BF8

# Command types
CMD_DONE  = 0x00
CMD_SOLID = 0x53  # 'S'
CMD_PORTAL = 0x50  # 'P'
CMD_ENDSS = 0x45  # 'E'


def _gen_quarter_square():
    """Generate the quarter-square tables."""
    sqr_lo = bytearray(256)
    sqr_hi = bytearray(256)
    sqr2_lo = bytearray(256)
    sqr2_hi = bytearray(256)
    for n in range(256):
        v = (n * n) >> 2
        sqr_lo[n] = v & 0xFF
        sqr_hi[n] = (v >> 8) & 0xFF
    for n in range(256):
        v = ((n + 256) * (n + 256)) >> 2
        sqr2_lo[n] = v & 0xFF
        sqr2_hi[n] = (v >> 8) & 0xFF
    return sqr_lo, sqr_hi, sqr2_lo, sqr2_hi


def _rd16(mem, addr):
    v = mem[addr] | (mem[addr + 1] << 8)
    return v - 65536 if v >= 32768 else v


def _rs8(mem, addr):
    v = mem[addr]
    return v - 256 if v >= 128 else v


class Frontend6502:
    """Loads doom_fe.bin and WAD data into py65 for repeated execution."""

    def __init__(self, rom_main, rom_detail, rom_recip, layout, binary_path=None):
        self.rom_main = rom_main
        self.rom_detail = rom_detail
        self.rom_recip = rom_recip
        self.layout = layout

        if binary_path is None:
            binary_path = os.path.join(os.path.dirname(__file__), 'doom_fe.bin')
        with open(binary_path, 'rb') as f:
            self.code = f.read()

        self.mpu = MPU()
        mem = self.mpu.memory

        # Load code
        for i, b in enumerate(self.code):
            mem[CODE_BASE + i] = b

        # Load quarter-square tables
        sqr_lo, sqr_hi, sqr2_lo, sqr2_hi = _gen_quarter_square()
        for i in range(256):
            mem[QSQ_BASE + i] = sqr_lo[i]
            mem[QSQ_BASE + 0x100 + i] = sqr_hi[i]
            mem[QSQ_BASE + 0x200 + i] = sqr2_lo[i]
            mem[QSQ_BASE + 0x300 + i] = sqr2_hi[i]

        # Load ROM data
        for i, b in enumerate(rom_main):
            mem[ROM_MAIN_BASE + i] = b
        for i, b in enumerate(rom_detail):
            mem[ROM_DETAIL_BASE + i] = b
        for i, b in enumerate(rom_recip):
            mem[ROM_RECIP_BASE + i] = b

        # Layout offsets
        for addr, key in [
            (LAYOUT_OFF_VERTS, 'off_verts'),
            (LAYOUT_OFF_NODES, 'off_nodes'),
            (LAYOUT_OFF_SS, 'off_ss'),
            (LAYOUT_OFF_SEG_HDR, 'off_seg_hdr'),
        ]:
            v = layout[key]
            mem[addr] = v & 0xFF
            mem[addr + 1] = (v >> 8) & 0xFF
        v = layout['n_nodes']
        mem[LAYOUT_N_NODES] = v & 0xFF
        mem[LAYOUT_N_NODES + 1] = (v >> 8) & 0xFF

        # BRK handler: JMP $FF00 (halt loop)
        mem[0xFF00] = 0x4C
        mem[0xFF01] = 0x00
        mem[0xFF02] = 0xFF
        mem[0xFFFE] = 0x00  # BRK vector lo
        mem[0xFFFF] = 0xFF  # BRK vector hi

    def render_frame(self, player_x, player_y, angle_byte, floor_z=0,
                     map_center_x=1200, map_center_y=-3250, prescale=8,
                     aspect_num=6, aspect_den=5):
        """Run one frame of the front-end and return (commands, cycles)."""
        mem = self.mpu.memory

        # Set player state
        px_88 = int((player_x - map_center_x) * 256 / prescale)
        py_88 = int((player_y - map_center_y) * 256 / prescale)
        mem[ZP_PX_INT] = (px_88 >> 8) & 0xFF
        mem[ZP_PY_INT] = (py_88 >> 8) & 0xFF
        mem[ZP_PX_LO] = px_88 & 0xFF
        mem[ZP_PY_LO] = py_88 & 0xFF

        vz_ps = ((floor_z + 41) * aspect_num + aspect_den // 2) // (prescale * aspect_den)
        mem[ZP_VZ_PS] = vz_ps & 0xFF
        mem[ZP_ANGLE] = angle_byte & 0xFF

        # Clear command buffer (just the first byte is enough — terminator)
        mem[CMD_BUFFER] = 0

        # Run
        self.mpu.pc = CODE_BASE
        self.mpu.sp = 0xFF
        self.mpu.p = 0x30
        self.mpu.processorCycles = 0

        max_steps = 10_000_000
        for _ in range(max_steps):
            if self.mpu.pc == 0xFF00:
                break
            self.mpu.step()

        cycles = self.mpu.processorCycles

        # Parse commands
        commands = []
        addr = CMD_BUFFER
        while addr < 0x0F00:
            t = mem[addr]
            if t == CMD_DONE:
                break
            elif t == CMD_ENDSS:
                commands.append(('E',))
                addr += 1
            elif t == CMD_SOLID:
                commands.append(('S',
                    _rd16(mem, addr + 1),  # sx1
                    _rd16(mem, addr + 3),  # sx2
                    _rd16(mem, addr + 5),  # ft1
                    _rd16(mem, addr + 7),  # fb1
                    _rd16(mem, addr + 9),  # ft2
                    _rd16(mem, addr + 11), # fb2
                ))
                addr += 13
            elif t == CMD_PORTAL:
                flags = mem[addr + 13]
                commands.append(('P',
                    _rd16(mem, addr + 1),
                    _rd16(mem, addr + 3),
                    _rd16(mem, addr + 5),
                    _rd16(mem, addr + 7),
                    _rd16(mem, addr + 9),
                    _rd16(mem, addr + 11),
                    bool(flags & 0x04),  # need_bt
                    bool(flags & 0x08),  # need_bb
                    _rd16(mem, addr + 14),  # bt1
                    _rd16(mem, addr + 16),  # bt2
                    _rd16(mem, addr + 18),  # bb1
                    _rd16(mem, addr + 20),  # bb2
                    _rs8(mem, addr + 22),   # bch
                    _rs8(mem, addr + 23),   # bfh
                    _rs8(mem, addr + 24),   # ch
                    _rs8(mem, addr + 25),   # fh
                ))
                addr += 26
            else:
                break

        return commands, cycles
