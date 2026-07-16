; Angle unit — one translation unit, split by subsystem (was slope_div.s).
; Order matters: bytes are emitted in include order (segments are set
; inside the parts).
;   header_div.s  jump table, workspace equates, slope_div
;   bca.s         bbox_check_angle — angle-space bbox visibility (original,
;                 cache-off path; bca_check_op dispatches here)
;   rcache.s      rotation-coherence psi cache: per-frame classifier,
;                 cached check path, RCACHE data map (RCCODE when banked)
;   corner_phi.s  box_classify + corner_phi/point_to_angle + cp_havepsi
.include "ang/header_div.s"
.include "ang/bca.s"
.include "ang/rcache.s"
.include "ang/corner_phi.s"
