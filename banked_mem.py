"""Sideways-RAM ($FE30) banking model for the py65 flat-memory harness.

py65's MPU.memory is a plain 65536-element list; the CPU reads via memory[addr]
and writes via memory[addr]=v. We model BBC sideways RAM by overriding ONLY
__setitem__: a write to ROMSEL ($FE30) swaps the active 16K bank in/out of the
flat $8000-$BFFF window. Reads (the hot path) use the unmodified list, so the
window always physically holds the currently-paged bank's bytes — fast.

Semantics mirror the spike-confirmed hardware:
  STA $FE30 with bank b -> $8000-$BFFF maps bank b (if b is a defined RAM bank).
Switching away saves the window back to the old bank; switching in loads the new.

Usage:
    mem = BankedMemory([0]*65536)
    mpu.memory = mem
    mem.define_bank(4, l0_image)   # 16K image, padded
    mem.define_bank(5, l1_image)
    mem.define_bank(6, bankc_image)
    # 6502 code does STA $FE30 to page; or pre-select:
    mem.select(6)
"""

WINDOW_LO = 0x8000
WINDOW_HI = 0xC000          # exclusive
WINDOW_SZ = WINDOW_HI - WINDOW_LO   # 16384
ROMSEL = 0xFE30


class BankedMemory(list):
    def __init__(self, *args):
        super().__init__(*args)
        self._banks = {}        # bank_num -> bytearray(16384)
        self._cur = None        # currently-paged bank (None = none of ours)

    def define_bank(self, num, image=None):
        """Register a 16K RAM bank, optionally seeded with `image` bytes."""
        buf = bytearray(WINDOW_SZ)
        if image:
            n = min(len(image), WINDOW_SZ)
            buf[:n] = bytes(image[:n])
        self._banks[num] = buf

    def select(self, num):
        """Page bank `num` into the window (same effect as STA $FE30)."""
        self._switch(num)
        list.__setitem__(self, ROMSEL, num & 0xFF)

    def _switch(self, num):
        if num == self._cur:
            return
        # save current window contents back to the outgoing bank
        if self._cur is not None and self._cur in self._banks:
            self._banks[self._cur][:] = super().__getitem__(slice(WINDOW_LO, WINDOW_HI))
        self._cur = num
        if num in self._banks:
            # load incoming bank into the window
            super().__setitem__(slice(WINDOW_LO, WINDOW_HI), list(self._banks[num]))

    def __setitem__(self, i, v):
        if isinstance(i, int):
            if i == ROMSEL:
                self._switch(v & 0x0F)
                list.__setitem__(self, i, v & 0xFF)
                return
            list.__setitem__(self, i, v)
        else:
            list.__setitem__(self, i, v)

    def current_bank(self):
        return self._cur
