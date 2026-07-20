; Angle unit — one translation unit, split by subsystem (was slope_div.s).
; Order matters: bytes are emitted in include order (segments are set
; inside the parts).
;   header_div.s  jump table, workspace equates, slope_div
;   bca.s         bbox_check_angle — angle-space bbox visibility (original,
;                 cache-off path; bca_check_op dispatches here)
;   rcache.s      rotation-coherence psi cache: per-frame classifier,
;                 cached check path, RCACHE data map (RCCODE when banked)
.include "ang/header_div.s"
.include "ang/bca.s"
