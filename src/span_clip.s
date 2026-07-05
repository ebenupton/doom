; Auto-split into subsystem files — order matters (bytes are
; emitted in include order; segments are set inside the parts).
.include "zp.inc"
.include "clip/header.s"
.include "clip/arith.s"
.include "clip/pool.s"
.include "clip/interp.s"
.include "clip/mark_solid.s"
.include "clip/query.s"
.include "clip/dcl.s"
.include "clip/tfr.s"
.include "clip/plot_axis.s"
.include "clip/dcl_s16.s"
