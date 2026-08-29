#!/usr/bin/env python3
"""Map-wide visibility corpus: for every in-map pose (128-unit grid x 4
angles + the regression battery + heavy), float-render and record the set
of visited subsectors. Output: corpus.npz (poses, visited bool matrix)."""
import sys; sys.path.insert(0,'/Users/ebenupton/doom')
import os, math, random
os.chdir('/Users/ebenupton/doom')
os.environ['SDL_VIDEODRIVER']='dummy'; os.environ['PYGAME_HIDE_SUPPORT_PROMPT']='1'
import pygame; pygame.init(); pygame.display.set_mode((1,1))
import numpy as np
import doom_wireframe as dw
import compare_renders as C

poses=[]
for x in range(-768, 3809, 128):
    for y in range(-4864, -1535, 128):
        try:
            fl = dw.player_floor(x, y)
        except Exception:
            continue
        ssi = dw.find_subsector(x, y)
        # open-sector test: reject void/degenerate cells (ceil <= floor)
        ss = dw.ssectors[ssi]
        s = dw.segs[ss[1]]; ld = dw.linedefs[s[3]]
        sd = ld[5] if s[4]==0 else ld[6]
        if sd == 0xFFFF: sd = ld[5]
        sec = dw.sidedefs[sd][5]
        if dw.sectors[sec][1] - dw.sectors[sec][0] < 56:
            continue
        for ab in (1, 65, 129, 193):
            poses.append((x, y, ab))
for (px,py,ab) in C.POSITIONS:
    poses.append((px,py,ab))
poses.append((1133,-3242,144))
print(f'{len(poses)} poses', flush=True)

NSS=len(dw.ssectors)
vis=np.zeros((len(poses), NSS), dtype=bool)
surf=pygame.Surface((dw.SCREEN_W,dw.SCREEN_H))
for k,(px,py,ab) in enumerate(poses):
    random.seed(42)
    surf.fill((0,0,0))
    for key in dw.map_trace:
        dw.map_trace[key] = {} if key=='vertex_muls' else ([] if key=='ss_order' else set())
    ar=dw.byte_to_radians(ab)
    try:
        dw.render_bsp(len(dw.nodes)-1, dw.ClipSpans(), math.cos(ar), math.sin(ar),
                      px, py, dw.player_floor(px,py)+41.0, surf)
    except Exception:
        continue
    for ssi in dw.map_trace['subsectors']:
        if isinstance(ssi,int) and 0<=ssi<NSS: vis[k,ssi]=True
    if k%200==0: print(f'{k}/{len(poses)}', flush=True)
np.savez_compressed(sys.argv[1], poses=np.array(poses), vis=vis)
print('DONE', vis.shape, 'mean visited/pose', vis.sum(1).mean())
