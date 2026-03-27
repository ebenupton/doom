#!/usr/bin/env python3
"""DOOM E1M1 wireframe renderer — BSP front-to-back with per-column clip arrays."""

import struct, math, sys, pygame

# ── WAD parsing ──────────────────────────────────────────────────────────────

def load_wad(path):
    with open(path, "rb") as f:
        data = f.read()
    magic, numlumps, dirofs = struct.unpack_from("<4sII", data, 0)
    directory = []
    for i in range(numlumps):
        off = dirofs + i * 16
        fpos, size = struct.unpack_from("<II", data, off)
        name = data[off+8:off+16].split(b"\x00")[0].decode("ascii", "replace")
        directory.append((name, fpos, size))
    return data, directory

def find_map_lumps(directory, mapname):
    for i, (name, _, _) in enumerate(directory):
        if name == mapname:
            return {directory[i+j][0]: (directory[i+j][1], directory[i+j][2])
                    for j in range(1, 11)}
    sys.exit(f"Map {mapname} not found")

def parse_lump(data, lumps, name, fmt):
    pos, size = lumps[name]
    sz = struct.calcsize(fmt)
    return [struct.unpack_from(fmt, data, pos + i * sz) for i in range(size // sz)]

# ── Load E1M1 ────────────────────────────────────────────────────────────────

data, directory = load_wad("DOOM1.WAD")
lumps = find_map_lumps(directory, "E1M1")

vertexes  = parse_lump(data, lumps, "VERTEXES",  "<hh")
linedefs  = parse_lump(data, lumps, "LINEDEFS",  "<HHHHHHH")
sidedefs  = parse_lump(data, lumps, "SIDEDEFS",  "<hh8s8s8sH")
sectors   = parse_lump(data, lumps, "SECTORS",   "<hh8s8sHHH")
segs      = parse_lump(data, lumps, "SEGS",      "<HHhHHH")
ssectors  = parse_lump(data, lumps, "SSECTORS",  "<HH")
nodes     = parse_lump(data, lumps, "NODES",     "<hhhhhhhhhhhhHH")
things    = parse_lump(data, lumps, "THINGS",    "<hhHHH")

for t in things:
    if t[3] == 1:
        player_x, player_y, pangle = float(t[0]), float(t[1]), t[2]
        break

# ── Helpers ──────────────────────────────────────────────────────────────────

def seg_sectors(seg):
    ld = linedefs[seg[3]]
    right_side, left_side = ld[5], ld[6]
    if seg[4] == 0:
        front = sidedefs[right_side][5]
        back  = sidedefs[left_side][5] if left_side != 0xFFFF else None
    else:
        front = sidedefs[left_side][5] if left_side != 0xFFFF else sidedefs[right_side][5]
        back  = sidedefs[right_side][5] if left_side != 0xFFFF else None
    return front, back

NF_SUBSECTOR = 0x8000

def point_on_side(x, y, node):
    dx, dy = x - node[0], y - node[1]
    return 0 if (node[3] * dx - node[2] * dy) > 0 else 1

def find_subsector(x, y):
    nid = len(nodes) - 1
    while not (nid & NF_SUBSECTOR):
        node = nodes[nid]
        nid = node[12] if point_on_side(x, y, node) == 0 else node[13]
    return nid & 0x7FFF

def player_floor(x, y):
    ss = ssectors[find_subsector(x, y)]
    s = segs[ss[1]]
    ld = linedefs[s[3]]
    sd_idx = ld[5] if s[4] == 0 else ld[6]
    if sd_idx == 0xFFFF: sd_idx = ld[5]
    return sectors[sidedefs[sd_idx][5]][0]

# ── Per-column clip arrays and trapezoid line clipper ────────────────────────

WIDTH, HEIGHT = 960, 600
HFOV = math.pi / 2
FOCAL = (WIDTH / 2) / math.tan(HFOV / 2)
NEAR = 1.0

def clip_to_trap(x1, y1, x2, y2, xlo, xhi, ytl, ytr, ybl, ybr):
    """Clip line segment to trapezoid (Cyrus-Beck, 4 half-planes)."""
    dxs = xhi - xlo
    if dxs < 0.5:
        # Degenerate: single-column rect clip
        dx, dy = x2 - x1, y2 - y1
        xc = (xlo + xhi) * 0.5
        yt, yb = min(ytl, ytr), max(ybl, ybr)
        t0, t1 = 0.0, 1.0
        for p, q in ((-dx, x1-(xc-0.5)), (dx, (xc+0.5)-x1),
                     (-dy, y1-yt), (dy, yb-y1)):
            if abs(p) < 1e-10:
                if q < -1e-10: return None
            else:
                t = q / p
                if p < 0:
                    if t > t1: return None
                    t0 = max(t0, t)
                else:
                    if t < t0: return None
                    t1 = min(t1, t)
        if t0 > t1: return None
        return (x1+t0*dx, y1+t0*dy, x1+t1*dx, y1+t1*dy)
    dx, dy = x2 - x1, y2 - y1
    mt = (ytr - ytl) / dxs
    mb = (ybr - ybl) / dxs
    t0, t1 = 0.0, 1.0
    for p, q in (
        (-dx, x1 - xlo),
        ( dx, xhi - x1),
        (mt * dx - dy, y1 - ytl - mt * (x1 - xlo)),
        (dy - mb * dx, ybl + mb * (x1 - xlo) - y1),
    ):
        if abs(p) < 1e-10:
            if q < -1e-10:
                return None
        else:
            t = q / p
            if p < 0:
                if t > t1: return None
                t0 = max(t0, t)
            else:
                if t < t0: return None
                t1 = min(t1, t)
    if t0 > t1:
        return None
    return (x1 + t0 * dx, y1 + t0 * dy, x1 + t1 * dx, y1 + t1 * dy)


class ClipColumns:
    """Per-column ceiling/floor clip arrays — DOOM's ceilingclip/floorclip."""
    __slots__ = ("top", "bot", "alive")

    def __init__(self):
        self.top = [0.0] * WIDTH
        self.bot = [float(HEIGHT - 1)] * WIDTH
        self.alive = WIDTH

    def is_full(self):
        return self.alive <= 0

    def has_gap(self, lo, hi):
        lo = max(0, int(lo))
        hi = min(WIDTH - 1, int(hi))
        for x in range(lo, hi + 1):
            if self.top[x] < self.bot[x]:
                return True
        return False

    def mark_solid(self, lo, hi):
        lo = max(0, int(lo))
        hi = min(WIDTH - 1, int(hi))
        top, bot = self.top, self.bot
        for x in range(lo, hi + 1):
            if top[x] < bot[x]:
                self.alive -= 1
                top[x] = bot[x]

    def tighten(self, lo, hi, sx1, sx2, yt1, yt2, yb1, yb2):
        """Tighten top and bottom bounds across [lo, hi].

        New bounds are linear: yt1/yb1 at sx1, yt2/yb2 at sx2.
        Per column: top = max(top, new_top), bot = min(bot, new_bot).
        """
        lo = max(0, int(lo))
        hi = min(WIDTH - 1, int(hi))
        top, bot = self.top, self.bot
        dsx = sx2 - sx1
        if abs(dsx) < 0.5:
            yt = (yt1 + yt2) * 0.5
            yb = (yb1 + yb2) * 0.5
            for x in range(lo, hi + 1):
                if top[x] >= bot[x]:
                    continue
                if yt > top[x]: top[x] = yt
                if yb < bot[x]: bot[x] = yb
                if top[x] >= bot[x]: self.alive -= 1
        else:
            inv = 1.0 / dsx
            dyt = (yt2 - yt1) * inv
            dyb = (yb2 - yb1) * inv
            for x in range(lo, hi + 1):
                if top[x] >= bot[x]:
                    continue
                t = x - sx1
                yt = yt1 + dyt * t
                yb = yb1 + dyb * t
                if yt > top[x]: top[x] = yt
                if yb < bot[x]: bot[x] = yb
                if top[x] >= bot[x]: self.alive -= 1

    def draw_clipped(self, lines, color, surface):
        """Clip each line per-column, drawing only within alive bounds."""
        top, bot = self.top, self.bot
        for lx1, ly1, lx2, ly2 in lines:
            dx, dy = lx2 - lx1, ly2 - ly1
            xlo = max(0, int(min(lx1, lx2)))
            xhi = min(WIDTH - 1, int(max(lx1, lx2)))
            if abs(dx) < 0.5:
                # Vertical line — single column, exact clip
                ix = max(0, min(WIDTH - 1, int(lx1)))
                yt, yb = top[ix], bot[ix]
                if yt >= yb:
                    continue
                ya, ybb = min(ly1, ly2), max(ly1, ly2)
                ya = max(ya, yt)
                ybb = min(ybb, yb)
                if ya < ybb:
                    pygame.draw.line(surface, color,
                                     (ix, int(ya)), (ix, int(ybb)), 1)
            else:
                # Walk columns, collect visible segments as runs
                inv_dx = 1.0 / dx
                seg_start = None
                for x in range(xlo, xhi + 2):
                    if x <= xhi and top[x] < bot[x]:
                        t = (x - lx1) * inv_dx
                        y = ly1 + dy * t
                        if top[x] <= y <= bot[x]:
                            if seg_start is None:
                                seg_start = (x, y)
                            seg_end = (x, y)
                            continue
                    # End of a visible run — draw it
                    if seg_start is not None:
                        pygame.draw.line(surface, color,
                                         (seg_start[0], int(seg_start[1])),
                                         (seg_end[0], int(seg_end[1])), 1)
                        seg_start = None

# ── View-space transform ────────────────────────────────────────────────────

def to_view(wx, wy, vx, vy, cos_a, sin_a):
    dx, dy = wx - vx, wy - vy
    return dx * sin_a - dy * cos_a, dx * cos_a + dy * sin_a

def near_clip(vx1, vy1, vx2, vy2):
    if vy1 < NEAR and vy2 < NEAR:
        return None
    if vy1 >= NEAR and vy2 >= NEAR:
        return vx1, vy1, vx2, vy2
    t = (NEAR - vy1) / (vy2 - vy1)
    cx = vx1 + t * (vx2 - vx1)
    if vy1 < NEAR:
        return cx, NEAR, vx2, vy2
    return vx1, vy1, cx, NEAR

def bbox_visible(node, far_side, cos_a, sin_a, vx, vy):
    base = 4 + far_side * 4
    top, bot, left, right = node[base], node[base+1], node[base+2], node[base+3]
    if left <= vx <= right and bot <= vy <= top:
        return 0, WIDTH - 1
    pts = [to_view(wx, wy, vx, vy, cos_a, sin_a)
           for wx, wy in ((left, top), (right, top), (right, bot), (left, bot))]
    if all(p[1] < NEAR for p in pts):
        return None
    if any(p[1] < NEAR for p in pts):
        return 0, WIDTH - 1
    sxs = [WIDTH * 0.5 + p[0] * FOCAL / p[1] for p in pts]
    return int(min(sxs)), int(max(sxs))

# ── BSP rendering ────────────────────────────────────────────────────────────

GREEN = (0, 200, 0)

def render_bsp(nid, clips, cos_a, sin_a, vx, vy, vz, surface):
    if clips.is_full():
        return
    if nid & NF_SUBSECTOR:
        render_subsector(0 if nid == 0xFFFF else nid & 0x7FFF,
                         clips, cos_a, sin_a, vx, vy, vz, surface)
        return
    node = nodes[nid]
    side = point_on_side(vx, vy, node)
    ch = (node[12], node[13])
    render_bsp(ch[side], clips, cos_a, sin_a, vx, vy, vz, surface)
    if clips.is_full():
        return
    far = side ^ 1
    br = bbox_visible(node, far, cos_a, sin_a, vx, vy)
    if br is not None and clips.has_gap(br[0], br[1]):
        render_bsp(ch[far], clips, cos_a, sin_a, vx, vy, vz, surface)

def render_subsector(idx, clips, cos_a, sin_a, vx, vy, vz, surface):
    ssec = ssectors[idx]
    for si in range(ssec[1], ssec[1] + ssec[0]):
        render_seg(si, clips, cos_a, sin_a, vx, vy, vz, surface)
        if clips.is_full():
            return

def render_seg(si, clips, cos_a, sin_a, vx, vy, vz, surface):
    s = segs[si]
    v1, v2 = vertexes[s[0]], vertexes[s[1]]
    # Back-face test
    ld = linedefs[s[3]]
    lv1, lv2 = vertexes[ld[0]], vertexes[ld[1]]
    ldx, ldy = lv2[0] - lv1[0], lv2[1] - lv1[1]
    dot = ldy * (vx - lv1[0]) - ldx * (vy - lv1[1])
    if s[4] == 1:
        dot = -dot
    front_facing = dot > 0

    front_idx, back_idx = seg_sectors(s)
    if not front_facing:
        if back_idx is None:
            return
        front_idx, back_idx = back_idx, front_idx

    nc = near_clip(*to_view(v1[0], v1[1], vx, vy, cos_a, sin_a),
                   *to_view(v2[0], v2[1], vx, vy, cos_a, sin_a))
    if nc is None:
        return
    ex1, ey1, ex2, ey2 = nc

    half_w, half_h = WIDTH * 0.5, HEIGHT * 0.5
    f1, f2 = FOCAL / ey1, FOCAL / ey2
    sx1, sx2 = half_w + ex1 * f1, half_w + ex2 * f2
    x_lo, x_hi = int(min(sx1, sx2)), int(max(sx1, sx2))
    if not clips.has_gap(x_lo, x_hi):
        return

    front = sectors[front_idx]
    fh, ch = front[0], front[1]

    ft1, fb1 = half_h - (ch - vz) * f1, half_h - (fh - vz) * f1
    ft2, fb2 = half_h - (ch - vz) * f2, half_h - (fh - vz) * f2

    solid = back_idx is None
    back = sectors[back_idx] if back_idx is not None else None
    if back and (back[1] <= fh or back[0] >= ch):
        solid = True

    if back:
        bt1, bt2 = half_h - (back[1] - vz) * f1, half_h - (back[1] - vz) * f2
        bb1, bb2 = half_h - (back[0] - vz) * f1, half_h - (back[0] - vz) * f2

    # ── Draw ──

    if solid:
        clips.draw_clipped([
            (sx1, ft1, sx2, ft2), (sx1, fb1, sx2, fb2),
            (sx1, ft1, sx1, fb1), (sx2, ft2, sx2, fb2),
        ], GREEN, surface)
    elif back:
        if back[1] < ch:
            clips.draw_clipped([
                (sx1, ft1, sx2, ft2), (sx1, bt1, sx2, bt2),
                (sx1, ft1, sx1, bt1), (sx2, ft2, sx2, bt2),
            ], GREEN, surface)
        elif back[1] > ch:
            clips.draw_clipped([(sx1, ft1, sx2, ft2)], GREEN, surface)
        if back[0] > fh:
            clips.draw_clipped([
                (sx1, bb1, sx2, bb2), (sx1, fb1, sx2, fb2),
                (sx1, bb1, sx1, fb1), (sx2, bb2, sx2, fb2),
            ], GREEN, surface)
        elif back[0] < fh:
            clips.draw_clipped([(sx1, fb1, sx2, fb2)], GREEN, surface)

    # ── Update clip state ──

    if solid:
        clips.mark_solid(x_lo, x_hi)
    elif back:
        clips.tighten(x_lo, x_hi, sx1, sx2,
                       max(ft1, bt1), max(ft2, bt2),
                       min(fb1, bb1), min(fb2, bb2))

# ── Main loop ────────────────────────────────────────────────────────────────

sys.setrecursionlimit(10000)
pygame.init()
screen = pygame.display.set_mode((WIDTH, HEIGHT))
pygame.display.set_caption("DOOM E1M1 — Wireframe BSP")
clock = pygame.time.Clock()

angle = math.radians(pangle)
turn_speed = 2.5
move_speed = 300.0

running = True
while running:
    dt = clock.tick(60) / 1000.0
    for ev in pygame.event.get():
        if ev.type == pygame.QUIT:
            running = False
        if ev.type == pygame.KEYDOWN and ev.key == pygame.K_ESCAPE:
            running = False

    keys = pygame.key.get_pressed()
    if keys[pygame.K_LEFT]:  angle += turn_speed * dt
    if keys[pygame.K_RIGHT]: angle -= turn_speed * dt
    if keys[pygame.K_UP]:
        player_x += math.cos(angle) * move_speed * dt
        player_y += math.sin(angle) * move_speed * dt
    if keys[pygame.K_DOWN]:
        player_x -= math.cos(angle) * move_speed * dt
        player_y -= math.sin(angle) * move_speed * dt

    screen.fill((0, 0, 0))
    cos_a, sin_a = math.cos(angle), math.sin(angle)
    vz = player_floor(player_x, player_y) + 41.0
    render_bsp(len(nodes) - 1, ClipColumns(), cos_a, sin_a,
               player_x, player_y, vz, screen)
    pygame.display.flip()

pygame.quit()
