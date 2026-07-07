#!/usr/bin/env python3
"""Play the integer Python DOOM E1M1 wireframe renderer.

Drives the pure-Python *fixed-point* renderer (`render_bsp_fp`) — the same
256x160 8-bit integer pipeline that is the ground truth for the 6502 port.
It is pixel-for-pixel identical to the 6502-coupled reference used in the
regression (`packed_render_bsp`), but ~100x faster because it doesn't run the
py65 6502 emulator per drawn line — so the frame rate stays high even from
viewpoints with long sightlines.

The 256x160 framebuffer is upscaled nearest-neighbour (blocky) to the window,
so what you see is the engine's real low-res output. The angle is quantised to
the engine's 256 directions (~1.4 deg each); position keeps 8.8 sub-unit
precision so motion stays smooth. Clipped seg fragments are drawn in per-frame
stable colours (the RNG is reseeded each frame).

Press M to toggle between this Python renderer and the *pure-6502* pipeline
(`bsp_render.bin` run in the py65 emulator, showing its real monochrome
framebuffer). It's the same engine, but emulating the chip is thousands of
times slower — fine for normal views (~35 fps), but heavy viewpoints can stall
for seconds (the HUD shows the simulated cycle count).

Controls
    W / Up        forward               A / D     strafe left / right
    S / Down      back                  Q / E     strafe left / right
    Left / Right  turn                  Shift     run
    M             Python / 6502 mode    Tab       mouse-look
    F1            toggle help           Esc       quit

Run:  python3 play.py        (needs DOOM1.WAD in this directory)
"""
import os, math, random
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
# Animated sectors (doors/lifts) on by default; DOOM_ANIM=0 to disable.
os.environ.setdefault('DOOM_ANIM', '1')
import pygame

# Importing the renderer loads DOOM1.WAD, builds the BSP, and sets the player
# start. It opens a 1x1 SDL window as a side effect; replaced below.
import doom_wireframe as dw
from endpoint_spans import EndpointClipSpans

if dw.ANIM_SECTORS:
    import anim_sectors as an
    an.install()          # visibility-lazy mover patching in the render paths
else:
    an = None

FB_W, FB_H = dw.FP_RENDER_W, dw.FP_RENDER_H    # 256 x 160 integer framebuffer
SCALE = 4
WIN_W, WIN_H = FB_W * SCALE, FB_H * SCALE       # 1024 x 640 window
BG = (8, 10, 16)
HUD = (255, 255, 0)
DIM = (120, 130, 140)

# Press M to toggle:
#   PYTHON  — render_bsp_fp, the pure-Python fixed-point reference (fast,
#             multi-colour clip fragments).
#   6502    — the full bsp_render.bin pipeline (BSP + transform + clip + raster)
#             run in the py65 emulator, displaying its real $5800 framebuffer
#             (monochrome). Same engine; ~thousands of times slower because it
#             simulates the chip — heavy views can stall for seconds.
_r6502 = None


def get_6502():
    """Lazily build the full-6502 renderer (loads bsp_render.bin + tables).
    Returns None if the build doesn't fit the flat harness (the DOOM_ANIM
    build's private VWH slots overflow the $E484 placement — engine-side
    relocation pending)."""
    global _r6502
    if _r6502 is None:
        from bsp_render_6502 import BspRender6502
        try:
            _r6502 = BspRender6502(
                dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
        except AssertionError as e:
            print(f'6502 mode unavailable: {e}')
            return None
        if an is not None:
            an.attach_6502(_r6502)   # mirror mover patches into py65 memory
    return _r6502


class FastFixedSpans(EndpointClipSpans):
    """Pure-Python integer reference clipper. The renderer passes a `roles`
    kwarg to draw_clipped (used by the 6502 records path); we accept and
    ignore it. Everything else is the unbiased EndpointClipSpans reference."""
    def draw_clipped(self, lines, color, surface, stats=None, roles=None):
        super().draw_clipped(lines, color, surface, stats)


def reset_frame_state():
    """The renderer accumulates BSP-trace bookkeeping into these module
    globals; clear them each frame so they don't grow without bound."""
    for k in dw.map_trace:
        if k == "vertex_muls":
            dw.map_trace[k] = {}
        elif k == "ss_order":
            dw.map_trace[k] = []
        else:
            dw.map_trace[k] = set()
    try:
        for i in range(len(dw.draw_stats)):
            dw.draw_stats[i] = 0
    except TypeError:
        pass


def render_frame(fb, px, py, angle_byte):
    """Render one integer-reference frame into the 256x160 surface `fb`."""
    random.seed(42)                       # stable per-frame seg-fragment colours
    dw.fp_module.mul_reset()
    px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)   # 8.8 sub-unit pos
    py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    vz_ps = dw._prescale_height(dw.player_floor(px, py) + 41)  # eye height
    ctx = dw.fp_view_context(px_88, py_88, dw.fp_sincos(angle_byte))
    ang_rad = angle_byte * 2 * math.pi / 256
    cos_f, sin_f = math.cos(ang_rad), math.sin(ang_rad)        # for bbox cull
    reset_frame_state()
    fb.fill(BG)
    dw.render_bsp_fp(len(dw.nodes) - 1, FastFixedSpans(), ctx, vz_ps,
                     int(px), int(py), cos_f, sin_f, fb,
                     [None] * len(dw.vertexes), [None] * len(dw.vwh_table))


def main():
    pygame.init()
    screen = pygame.display.set_mode((WIN_W, WIN_H))
    pygame.display.set_caption("DOOM E1M1 — integer Python wireframe (256x160)")
    dw.screen = screen
    # The renderer draws through pygame.draw.line; use the plain fast drawer
    # (not the main tool's cycle-counting wrapper).
    pygame.draw.line = dw._real_drawline

    clock = pygame.time.Clock()
    font = pygame.font.SysFont("monospace", 16)
    fb = pygame.Surface((FB_W, FB_H))

    px, py = float(dw.player_x), float(dw.player_y)
    angle = math.radians(dw.pangle)                 # smooth float angle
    MOVE = 300.0                                     # world units / second
    TURN = 2.6                                       # radians / second
    MOUSE_SENS = 0.0032
    mouse_look = False
    show_help = True
    mode = 'py'            # 'py' = pure Python fixed-point, '6502' = emulated chip

    running = True
    while running:
        dt = clock.tick(60) / 1000.0

        for ev in pygame.event.get():
            if ev.type == pygame.QUIT:
                running = False
            elif ev.type == pygame.KEYDOWN:
                if ev.key == pygame.K_ESCAPE:
                    running = False
                elif ev.key == pygame.K_TAB:
                    mouse_look = not mouse_look
                    pygame.mouse.set_visible(not mouse_look)
                    pygame.event.set_grab(mouse_look)
                elif ev.key == pygame.K_F1:
                    show_help = not show_help
                elif ev.key == pygame.K_m:
                    mode = '6502' if mode == 'py' else 'py'
                    if mode == '6502' and get_6502() is None:
                        mode = 'py'       # anim build doesn't fit flat yet
            elif ev.type == pygame.MOUSEMOTION and mouse_look:
                angle -= ev.rel[0] * MOUSE_SENS

        keys = pygame.key.get_pressed()
        run = keys[pygame.K_LSHIFT] or keys[pygame.K_RSHIFT]
        step = MOVE * (2.2 if run else 1.0) * dt
        turn = TURN * dt
        if keys[pygame.K_LEFT]:
            angle += turn
        if keys[pygame.K_RIGHT]:
            angle -= turn
        fwd = (1 if (keys[pygame.K_w] or keys[pygame.K_UP]) else 0) \
            - (1 if (keys[pygame.K_s] or keys[pygame.K_DOWN]) else 0)
        strafe = (1 if (keys[pygame.K_d] or keys[pygame.K_e]) else 0) \
               - (1 if (keys[pygame.K_a] or keys[pygame.K_q]) else 0)
        if fwd:
            px += math.cos(angle) * step * fwd
            py += math.sin(angle) * step * fwd
        if strafe:
            px += math.cos(angle - math.pi / 2) * step * strafe
            py += math.sin(angle - math.pi / 2) * step * strafe

        ab = dw.radians_to_byte(angle) & 0xFF        # quantise to 256 directions

        if an is not None:
            an.tick(dt)          # logical heights advance; tables patch lazily

        if mode == 'py':
            render_frame(fb, px, py, ab)             # pure-Python fixed-point
            detail = f"PYTHON  {len(dw.map_trace['segs_drawn'])} segs"
        else:
            if an is not None:
                an.flush_all()   # 6502 frames can't lazy-hook from python
            cyc = get_6502().render_frame(px, py, ab, dw.player_floor(px, py))
            get_6502().blit_framebuffer_to(fb)        # real $5800 framebuffer (mono)
            capped = "  CAPPED-incomplete" if cyc > 30_000_000 else ""
            detail = f"6502  {cyc:,} cyc/frame{capped}"

        # blocky nearest-neighbour upscale of the 256x160 framebuffer
        pygame.transform.scale(fb, (WIN_W, WIN_H), screen)

        screen.blit(font.render(
            f"[{mode.upper():5s}] {detail}", True, HUD), (6, 6))
        screen.blit(font.render(
            f"({px:.0f},{py:.0f})  byte-angle {ab:3d}   {clock.get_fps():4.0f} fps",
            True, HUD), (6, 26))
        if an is not None:
            screen.blit(font.render(an.hud_line(), True, DIM), (6, 46))
        if show_help:
            screen.blit(font.render(
                "WASD/arrows move · Q/E strafe · Shift run · M Python/6502 · "
                "Tab mouse-look · F1 help · Esc quit", True, DIM),
                (6, WIN_H - 24))

        pygame.display.flip()

    pygame.quit()


if __name__ == '__main__':
    main()
