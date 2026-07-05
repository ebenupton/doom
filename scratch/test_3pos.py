import os
os.environ.setdefault('SDL_VIDEODRIVER','dummy'); os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT','1')
import pygame; pygame.init()
exec(open('test_phi_guard.py').read().split('POS=[')[0])  # reuse render/corner/disp/guarded
for (px,py,ab) in [(1354,-3748,95),(955,-3735,222),(893,-3218,123)]:
    t=corner(px,py,ab); ng=render(px,py,ab,False); g=render(px,py,ab,True)
    print(f"({px},{py},{ab}): noguard={disp(ng,t):4d}  guard={disp(g,t):4d}  ({'guard-CAUSED' if disp(ng,t)<=2 else 'pre-existing'})")
