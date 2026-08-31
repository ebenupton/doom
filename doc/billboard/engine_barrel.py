"""The barrel art the engine ships TODAY, rebuilt from wad_packed.py's
tables and objects.s's integer ladder, for side-by-side comparison."""
_XI = {0:5,1:4,2:3,3:2,4:1,5:0,6:0,7:1,8:2,9:3,10:4,11:5}
_YI = {0:3,1:4,2:5,3:5,4:4,5:3,6:2,7:1,8:0,9:0,10:1,11:2}

def engine_ladder(H, k=23):
    a  = (H*k + 32) >> 6            # ROUNDED, per objects.s -- not H*k//64
    a2 = round(47*a/64); a3 = a - a2
    b  = (H+8) >> 4
    b2 = round(47*b/64); b3 = b - b2
    dy = H - 2*b
    w  = (9*a)//16                       # the hex LOD's half-width, 9a/16
    X  = [-a, -a2, -a3, a3, a2, a]
    Y  = [0, b-b2, b-b3, b+b3, b+b2, 2*b]
    Y += [v+dy for v in Y]
    return X, Y, w, a, b

def engine_oct(H):
    X,Y,w,a,b = engine_ladder(H)
    def ln(p,q,arm=False):
        P=(X[p[0]],Y[p[1]]); Q=(X[q[0]],Y[q[1]])
        if P[0]>Q[0]: P,Q = Q,P
        return (P,Q,'r' if arm else 'b')
    def edge(k,d=0,arm=False):
        j=(k+1)%12
        return ln((_XI[k],_YI[k]+d),(_XI[j],_YI[j]+d),arm)
    L  = [edge(k)     for k in (0,1,2,3,4)]      # near half of the lid
    L += [edge(k,6)   for k in (0,1,2,3,4)]      # near half of the base
    L += [ln((0,2),(0,9)), ln((5,2),(5,9))]      # sides
    L += [edge(k,0,True) for k in (6,7,8,9,10)]  # far half of the lid: ARMED
    return L

def engine_hex(H):
    X,Y,w,a,b = engine_ladder(H)
    # the engine reaches cx∓w as x indices 12/13 -- obj_X and obj_Y are
    # adjacent, so those land in obj_Y's two dead slots.  Pad to match.
    XX = X + [0.0]*6 + [-w, w]                   # indices 12, 13
    def h(p,q,arm=False):
        P=(XX[p[0]],Y[p[1]]); Q=(XX[q[0]],Y[q[1]])
        if P[0]>Q[0]: P,Q = Q,P
        return (P,Q,'r' if arm else 'b')
    L  = [h((0,3),(12,5)), h((12,5),(13,5)), h((13,5),(5,3))]
    L += [h((0,9),(12,11)), h((12,11),(13,11)), h((13,11),(5,9))]
    L += [h((0,3),(0,9)), h((5,3),(5,9))]
    L += [h((0,3),(12,0),True), h((12,0),(13,0),True), h((13,0),(5,3),True)]
    return L
