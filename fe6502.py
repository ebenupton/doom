"""Python wrapper for the 6502 DOOM front-end (doom_fe.bin).

Loads the assembled binary + WAD data into py65, runs the front-end for
a given player state, and returns the command list for the Python back-end.
"""
import os
from py65.devices.mpu6502 import MPU


# Memory map (must match doom_fe.asm)
ROM_WINDOW      = 0x8000
QSQ_BASE        = 0x5400
ROM_RECIP_BASE  = 0x4F7E
CODE_BASE       = 0x2640
CMD_BUFFER      = 0x0300
SPANS_BASE      = 0x20D0
ROMSEL          = 0xFE30

# ZP addresses
ZP_PX_INT = 0x10
ZP_PY_INT = 0x11
ZP_PX_LO  = 0x12
ZP_PY_LO  = 0x13
ZP_VZ_PS  = 0x14
ZP_ANGLE  = 0x15

# Layout offsets (stored in RAM, accessed from 6502 code)
LAYOUT_OFF_VERTS   = 0x02D8
LAYOUT_OFF_NODES   = 0x02DA
LAYOUT_OFF_SS      = 0x02DC
LAYOUT_OFF_SEG_HDR = 0x02DE
LAYOUT_N_NODES     = 0x02E0

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


def _parse_top_level_labels(asm_path):
    """Return top-level label names from the asm source (outside {} blocks)."""
    depth = 0
    labels = []
    with open(asm_path) as f:
        for line in f:
            # Strip comments
            if ';' in line:
                line = line[:line.index(';')]
            stripped = line.strip()
            if stripped == '{':
                depth += 1
                continue
            if stripped == '}':
                depth = max(0, depth - 1)
                continue
            if depth == 0 and stripped.startswith('.') and ' ' not in stripped and len(stripped) > 1:
                labels.append(stripped[1:])
    return labels


def _parse_listing_addrs(asm_path, beebasm_path=None):
    """Run beebasm -v and return {label: address}."""
    import subprocess
    if beebasm_path is None:
        beebasm_path = os.path.join(os.path.dirname(asm_path) or '.', 'beebasm')
    result = subprocess.run(
        [beebasm_path, '-i', asm_path, '-v'],
        capture_output=True, text=True, cwd=os.path.dirname(asm_path) or '.'
    )
    addrs = {}
    lines = result.stdout.split('\n')
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith('.') and ' ' not in stripped and len(stripped) > 1:
            name = stripped[1:]
            for j in range(i + 1, min(i + 3, len(lines))):
                nl = lines[j].strip()
                if nl and nl[0] in '0123456789ABCDEFabcdef':
                    parts = nl.split()
                    try:
                        addrs[name] = int(parts[0], 16)
                        break
                    except ValueError:
                        pass
    return addrs


def _build_pc_map(top_level_labels, label_addrs):
    """Build a 64KB array mapping PC → top-level function name."""
    # Pair each top-level label with its address, sort by address
    pairs = [(label_addrs[name], name) for name in top_level_labels if name in label_addrs]
    pairs.sort()
    pc_map = [''] * 0x10000
    for i, (addr, name) in enumerate(pairs):
        end = pairs[i + 1][0] if i + 1 < len(pairs) else 0x10000
        for pc in range(addr, min(end, 0x10000)):
            pc_map[pc] = name
    return pc_map, pairs


# Function categories for grouping the profile output
PROFILE_CATEGORIES = [
    ('math',       ['smul8x8', 'umul8x8', 'mul_s16_u8_s24', 'div16_8']),
    ('bsp',        ['bsp_traverse', 'point_on_side', 'get_child', 'has_any_gap',
                    'mul16x16']),
    ('view_xform', ['decompose_angle', 'compute_frac_rotation', 'to_view',
                    'rot_term', 'load_vertex']),
    ('near_clip',  ['near_clip']),
    ('projection', ['recip_and_project_x1', 'recip_and_project_x2', 'recip_lookup',
                    'compute_x_range']),
    ('bitmap',     ['has_gap', 'mark_solid', 'bit_masks']),
    ('heights',    ['read_seg_detail', 'project_y_all']),
    ('seg_emit',   ['emit_solid_cmd', 'emit_portal_cmd']),
    ('seg_ctrl',   ['render_seg', 'render_subsector']),
    ('setup',      ['entry', 'clr_bm', 'fp_bbox_visible', '_to_view',
                    '_bbox_screen_range']),
]


class PagedMemory(list):
    """64KB memory with BBC Micro sideways ROM banking at $8000-$BFFF
    and a magic line-draw peripheral at $FE20-$FE27.

    Write 8 bytes (x0_lo, x0_hi, y0_lo, y0_hi, x1_lo, x1_hi, y1_lo, y1_hi).
    The write to $FE27 (y1_hi) triggers a clipped line draw: the peripheral
    reads the current span state from RAM at SPANS_BASE, clips the line
    against every overlapping span (same Cyrus-Beck as Python draw_clipped),
    and records the output segments.
    """

    LINEDRAW_BASE = 0xFE20

    def __init__(self, rom_banks=None):
        super().__init__([0] * 65536)
        self.rom_banks = rom_banks or []
        self.current_bank = -1
        self._line_latch = [0] * 8   # x0_lo, x0_hi, y0_lo, y0_hi, ...
        self.drawn_lines = []         # list of (x0,y0,x1,y1) after clipping
        self._clips = None            # lazy FPClipSpans for clipping

    def __setitem__(self, key, value):
        super().__setitem__(key, value)
        if not isinstance(key, int):
            return
        if key == 0xFE30:
            bank = value & 0x0F
            if bank != self.current_bank and bank < len(self.rom_banks):
                self.current_bank = bank
                src = self.rom_banks[bank]
                super().__setitem__(slice(0x8000, 0x8000 + len(src)), list(src))
        elif 0xFE20 <= key <= 0xFE27:
            self._line_latch[key - 0xFE20] = value
            if key == 0xFE27:
                self._draw_clipped_line()

    def _s16(self, lo, hi):
        v = lo | (hi << 8)
        return v - 65536 if v >= 32768 else v

    def _draw_clipped_line(self):
        """Triggered on write to $FE27.  Read latched coords, clip against
        current span state in RAM, record output lines."""
        L = self._line_latch
        x0 = self._s16(L[0], L[1])
        y0 = self._s16(L[2], L[3])
        x1 = self._s16(L[4], L[5])
        y1 = self._s16(L[6], L[7])

        # Lazy-build a FPClipSpans from current RAM span state
        from wad_packed import read_all_spans
        from doom_wireframe import FPClipSpans
        clips = FPClipSpans()
        clips.spans = read_all_spans(self, SPANS_BASE)

        # Clip and collect output lines (same algorithm as draw_clipped)
        clips._clip_and_record(x0, y0, x1, y1, self.drawn_lines)


class Frontend6502:
    """Loads doom_fe.bin and WAD data into py65 for repeated execution."""

    def __init__(self, rom_banks, rom_recip, bbox_table, layout, binary_path=None):
        self.rom_banks = rom_banks
        self.rom_recip = rom_recip
        self.bbox_table = bbox_table
        self.layout = layout

        if binary_path is None:
            binary_path = os.path.join(os.path.dirname(__file__), 'doom_fe.bin')
        with open(binary_path, 'rb') as f:
            self.code = f.read()

        self.mpu = MPU()
        # Replace mpu.memory with PagedMemory
        paged = PagedMemory(rom_banks)
        self.mpu.memory = paged
        mem = self.mpu.memory

        # Load bank 0 initially
        mem[ROMSEL] = 0

        # Load code
        for i, b in enumerate(self.code):
            mem[CODE_BASE + i] = b

        # Load quarter-square tables at $0300-$06FF (page-aligned)
        sqr_lo, sqr_hi, sqr2_lo, sqr2_hi = _gen_quarter_square()
        for i in range(256):
            mem[QSQ_BASE + i] = sqr_lo[i]
            mem[QSQ_BASE + 0x100 + i] = sqr_hi[i]
            mem[QSQ_BASE + 0x200 + i] = sqr2_lo[i]
            mem[QSQ_BASE + 0x300 + i] = sqr2_hi[i]

        # Load recip/trig at $0700+
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

        # Visibility-span hooks: the 6502 front-end JSRs to fixed hook
        # addresses in $FE00..$FE0F to invoke Python FPClipSpans operations
        # running on its RAM.  Install the hook table and state.
        from spans6502 import install_hooks
        self._span_state, self._span_hooks = install_hooks(self.mpu, mem)

    def render_frame(self, player_x, player_y, angle_byte, floor_z=0,
                     map_center_x=1200, map_center_y=-3250, prescale=None,
                     aspect_num=6, aspect_den=5):
        """Run one frame of the front-end and return (commands, cycles)."""
        mem = self.mpu.memory

        # The current prescale must match whatever the ROM was packed with,
        # which in turn is driven by fp.PRESCALE.
        if prescale is None:
            import fp
            prescale = fp.PRESCALE

        # Set player state
        px_88 = int((player_x - map_center_x) * 256 / prescale)
        py_88 = int((player_y - map_center_y) * 256 / prescale)
        mem[ZP_PX_INT] = (px_88 >> 8) & 0xFF
        mem[ZP_PY_INT] = (py_88 >> 8) & 0xFF
        mem[ZP_PX_LO] = px_88 & 0xFF
        mem[ZP_PY_LO] = py_88 & 0xFF

        # Raw player position (s16, relative to map_center) — used by
        # point_on_side so the asm can match Python's raw-coord impl
        # exactly at any prescale.
        wx_rel = int(player_x - map_center_x)
        wy_rel = int(player_y - map_center_y)
        mem[0xC0] = wx_rel & 0xFF
        mem[0xC1] = (wx_rel >> 8) & 0xFF
        mem[0xC2] = wy_rel & 0xFF
        mem[0xC3] = (wy_rel >> 8) & 0xFF

        vz_ps = ((floor_z + 41) * aspect_num + aspect_den // 2) // (prescale * aspect_den)
        mem[ZP_VZ_PS] = vz_ps & 0xFF
        mem[ZP_ANGLE] = angle_byte & 0xFF

        # Initialise visibility-span state inline (no Python hook needed).
        # One full-screen span: count=1, xlo=0, xhi=0(=256), flat top=0, flat bot=159.
        from wad_packed import spans_init_full, SPAN_HDR
        spans_init_full(mem, SPANS_BASE, 256, 159)
        mem[SPANS_BASE + SPAN_HDR + 1] = 0  # xhi=256 stored as 0 (wrap)

        # Clear the line-draw peripheral's output buffer
        mem.drawn_lines = []

        # Run
        self.mpu.pc = CODE_BASE
        self.mpu.sp = 0xFF
        self.mpu.p = 0x30
        self.mpu.processorCycles = 0

        max_steps = 10_000_000
        mpu = self.mpu
        hook_table = self._span_hooks
        from spans6502 import _do_rts
        for _ in range(max_steps):
            pc = mpu.pc
            if pc == 0xFF00:
                break
            hook = hook_table.get(pc)
            if hook is not None:
                hook(mpu)
                _do_rts(mpu)
                continue
            mpu.step()

        cycles = self.mpu.processorCycles

        # Return the clipped lines drawn via the peripheral
        return mem.drawn_lines, cycles

    def _ensure_profile_map(self, asm_path=None):
        """Lazily build the PC → function name map from the asm source/listing."""
        if getattr(Frontend6502, '_pc_map', None) is not None:
            return
        if asm_path is None:
            asm_path = os.path.join(os.path.dirname(__file__) or '.', 'doom_fe.asm')
        top = _parse_top_level_labels(asm_path)
        addrs = _parse_listing_addrs(asm_path)
        pc_map, pairs = _build_pc_map(top, addrs)
        Frontend6502._pc_map = pc_map
        Frontend6502._label_pairs = pairs

    def profile_frame(self, player_x, player_y, angle_byte, floor_z=0,
                      map_center_x=1200, map_center_y=-3250, prescale=None,
                      aspect_num=6, aspect_den=5):
        """Run one frame with per-function cycle profiling.

        Returns (commands, total_cycles, profile) where profile is a list
        of (function_name, cycles) tuples sorted by cycle count descending.
        """
        self._ensure_profile_map()
        pc_map = Frontend6502._pc_map
        mem = self.mpu.memory

        if prescale is None:
            import fp
            prescale = fp.PRESCALE

        # Set player state (same as render_frame)
        px_88 = int((player_x - map_center_x) * 256 / prescale)
        py_88 = int((player_y - map_center_y) * 256 / prescale)
        mem[ZP_PX_INT] = (px_88 >> 8) & 0xFF
        mem[ZP_PY_INT] = (py_88 >> 8) & 0xFF
        mem[ZP_PX_LO] = px_88 & 0xFF
        mem[ZP_PY_LO] = py_88 & 0xFF
        wx_rel = int(player_x - map_center_x)
        wy_rel = int(player_y - map_center_y)
        mem[0xC0] = wx_rel & 0xFF
        mem[0xC1] = (wx_rel >> 8) & 0xFF
        mem[0xC2] = wy_rel & 0xFF
        mem[0xC3] = (wy_rel >> 8) & 0xFF
        vz_ps = ((floor_z + 41) * aspect_num + aspect_den // 2) // (prescale * aspect_den)
        mem[ZP_VZ_PS] = vz_ps & 0xFF
        mem[ZP_ANGLE] = angle_byte & 0xFF
        mem[CMD_BUFFER] = 0

        # Initialise visibility-span state inline (no Python hook needed).
        # One full-screen span: count=1, xlo=0, xhi=0(=256), flat top=0, flat bot=159.
        from wad_packed import spans_init_full, SPAN_HDR
        spans_init_full(mem, SPANS_BASE, 256, 159)
        mem[SPANS_BASE + SPAN_HDR + 1] = 0  # xhi=256 stored as 0 (wrap)

        # Run with PC sampling at every instruction
        mpu = self.mpu
        mpu.pc = CODE_BASE
        mpu.sp = 0xFF
        mpu.p = 0x30
        mpu.processorCycles = 0

        buckets = {}
        step = mpu.step
        prev_cycles = 0
        hook_table = self._span_hooks
        from spans6502 import _do_rts
        max_steps = 10_000_000
        for _ in range(max_steps):
            pc = mpu.pc
            if pc == 0xFF00:
                break
            hook = hook_table.get(pc)
            if hook is not None:
                hook(mpu)
                _do_rts(mpu)
                buckets['<span_hook>'] = buckets.get('<span_hook>', 0) + 1
                prev_cycles = mpu.processorCycles
                continue
            name = pc_map[pc] or '<unknown>'
            step()
            delta = mpu.processorCycles - prev_cycles
            buckets[name] = buckets.get(name, 0) + delta
            prev_cycles = mpu.processorCycles

        total_cycles = mpu.processorCycles

        # Parse commands (same as render_frame)
        commands = []
        addr = CMD_BUFFER
        cmd_limit = CMD_BUFFER + 880
        while addr < cmd_limit:
            t = mem[addr]
            if t == CMD_DONE:
                break
            elif t == CMD_ENDSS:
                commands.append(('E',))
                addr += 1
            elif t == CMD_SOLID:
                commands.append(('S',
                    _rd16(mem, addr + 1), _rd16(mem, addr + 3),
                    _rd16(mem, addr + 5), _rd16(mem, addr + 7),
                    _rd16(mem, addr + 9), _rd16(mem, addr + 11)))
                addr += 13
            elif t == CMD_PORTAL:
                flags = mem[addr + 13]
                commands.append(('P',
                    _rd16(mem, addr + 1), _rd16(mem, addr + 3),
                    _rd16(mem, addr + 5), _rd16(mem, addr + 7),
                    _rd16(mem, addr + 9), _rd16(mem, addr + 11),
                    bool(flags & 0x04), bool(flags & 0x08),
                    _rd16(mem, addr + 14), _rd16(mem, addr + 16),
                    _rd16(mem, addr + 18), _rd16(mem, addr + 20),
                    _rs8(mem, addr + 22), _rs8(mem, addr + 23),
                    _rs8(mem, addr + 24), _rs8(mem, addr + 25)))
                addr += 26
            else:
                break

        profile = sorted(buckets.items(), key=lambda kv: -kv[1])
        return commands, total_cycles, profile

    def render_frame_full(self, player_x, player_y, angle_byte, floor_z=0,
                          **kwargs):
        """Run the 6502 front-end, clip lines via Python, then rasterise
        through the NJ+Hamiltonian 6502 line-draw routine.

        Returns (surface, fe_cycles, raster_cycles) where surface is a
        256×160 pygame Surface with the fully-rendered wireframe.
        """
        from raster6502 import render_lines_6502
        from doom_wireframe import clip_and_draw_6502_lines, _prescale_height

        cmds, fe_cyc = self.render_frame(player_x, player_y, angle_byte,
                                         floor_z, **kwargs)
        vz_ps = _prescale_height(floor_z + 41)
        lines = clip_and_draw_6502_lines(cmds, vz_ps)
        surf, rast_cyc = render_lines_6502(lines)
        return surf, fe_cyc, rast_cyc


def format_profile(profile, total_cycles, categories=None):
    """Format a profile result as a text report.

    profile: list of (name, cycles) as returned by profile_frame
    total_cycles: total cycle count for percentage computation
    categories: optional list of (category_name, [function_names]) tuples
    """
    lines = []
    lines.append(f"Total: {total_cycles} cycles")
    lines.append("")

    # By category
    if categories is None:
        categories = PROFILE_CATEGORIES
    by_fn = dict(profile)
    seen = set()
    lines.append(f"{'Category':15} {'Cycles':>10}  {'%':>6}")
    lines.append("-" * 36)
    cat_totals = []
    for cat_name, fns in categories:
        total = sum(by_fn.get(fn, 0) for fn in fns)
        for fn in fns:
            seen.add(fn)
        cat_totals.append((cat_name, total))
    # Sort categories by cycles descending
    cat_totals.sort(key=lambda kv: -kv[1])
    for cat_name, total in cat_totals:
        pct = 100 * total / max(1, total_cycles)
        lines.append(f"{cat_name:15} {total:>10}  {pct:5.1f}%")
    # Uncategorised
    other = sum(c for n, c in profile if n not in seen)
    if other:
        lines.append(f"{'(other)':15} {other:>10}  {100*other/max(1,total_cycles):5.1f}%")

    lines.append("")
    lines.append(f"{'Function':25} {'Cycles':>10}  {'%':>6}")
    lines.append("-" * 46)
    for name, cyc in profile[:20]:
        pct = 100 * cyc / max(1, total_cycles)
        lines.append(f"{name:25} {cyc:>10}  {pct:5.1f}%")
    return '\n'.join(lines)
