import os,sys
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
import doom_wireframe as dw
from bsp_render_6502 import BspRender6502
import compare_renders as C
px,py,ab=1056,-3616,137
pys=C.render_python(px,py,ab)
r=BspRender6502(dw.packed_layout,dw.packed_rom_main,dw.packed_rom_detail,dw.packed_bbox_table,dw.MAP_CENTER_X,dw.MAP_CENTER_Y,dw.PRESCALE)
ks,cyc=C.render_6502(r,px,py,ab)
diff=C.make_diff(pys,ks)
W,H=dw.FP_RENDER_W,dw.FP_RENDER_H
sheet=pygame.Surface((W*3+20,H)); sheet.fill((30,30,30))
sheet.blit(pys,(0,0)); sheet.blit(ks,(W+10,0)); sheet.blit(diff,(2*W+20,0))
pygame.image.save(pygame.transform.scale(sheet,((W*3+20)*3,H*3)),'rdiff.png')
# also count red(py-only) vs blue(6502-only)
import pygame.surfarray as sa
d=sa.array3d(diff)
red=((d[:,:,0]>200)&(d[:,:,2]<120)).sum(); blue=((d[:,:,2]>200)&(d[:,:,0]<120)).sum()
print(f"py-only(red, missing in 6502)={red}  6502-only(blue, extra)={blue}  cyc={cyc}")
