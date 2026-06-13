#!/usr/bin/env python3
"""
Static inline patch driver for UnityFramework (KIOU 1.0.1 build 11).

Each PATCH entry replaces an entire 8-byte `LDR(B) Wn,[X0,#off]; RET` leaf
function with `MOV W0,#imm; RET`, forcing a deterministic constant return.

This is the JB-free equivalent of the per-hook MSHookFunction installs in
Sources/KiouEditor/Hook_*.m. iOS 18 CSM is happy because we ship a single
patched binary that gets re-signed end-to-end by Sideloadly + Developer
Program profile — no runtime page rewrites involved.
"""
from __future__ import annotations

import argparse
import os
import sys


def mov_w0_imm_ret(imm: int) -> bytes:
    """Encode `MOV W0, #imm` (MOVZ, LSL #0) + `RET` (8 bytes, little-endian)."""
    if not (0 <= imm <= 0xFFFF):
        raise ValueError(f"imm out of MOVZ 16-bit range: {imm}")
    movz = 0x52800000 | (imm << 5) | 0  # Rd = W0
    ret = 0xD65F03C0
    return movz.to_bytes(4, "little") + ret.to_bytes(4, "little")


def movz_w_imm(rd: int, imm: int) -> bytes:
    """Encode `MOVZ Wd, #imm, LSL #0` (4 bytes, little-endian).

    Used to short-circuit a `LDR(B) Wd, [Xn, #off]` field load with a literal,
    forcing downstream comparisons to take a chosen branch.
    """
    if not (0 <= rd < 32):
        raise ValueError(f"Rd out of range: {rd}")
    if not (0 <= imm <= 0xFFFF):
        raise ValueError(f"imm out of MOVZ 16-bit range: {imm}")
    insn = 0x52800000 | (imm << 5) | rd
    return insn.to_bytes(4, "little")


# ---------------------------------------------------------------------------
# Additional arm64 encoders used by CAVE_PATCHES.
#
# We deliberately keep these narrow — only the instruction shapes we actually
# emit in caves, with `assert`s for the operand ranges we care about. All
# encodings verified by round-trip against live UnityFramework bytes (e.g. the
# LDR W1,[X20,#0x18] at 0x5C25FEC and the CSET W8,NE at 0x5CEEDE8).
# ---------------------------------------------------------------------------

def ldr_w_imm(rt: int, rn: int, off: int) -> bytes:
    """Encode `LDR Wt, [Xn, #off]` (4 bytes). `off` is a byte offset, must be 4B-aligned."""
    if not (0 <= rt < 32 and 0 <= rn < 32):
        raise ValueError(f"register out of range: rt={rt} rn={rn}")
    if off < 0 or off % 4 != 0 or off > 0xFFF * 4:
        raise ValueError(f"LDR W off out of imm12*4 range: {off}")
    imm12 = off // 4
    insn = 0xB9400000 | (imm12 << 10) | (rn << 5) | rt
    return insn.to_bytes(4, "little")


def strb_w_imm(rt: int, rn: int, off: int) -> bytes:
    """Encode `STRB Wt, [Xn, #off]` (4 bytes). `off` is a byte offset in [0, 4095]."""
    if not (0 <= rt < 32 and 0 <= rn < 32):
        raise ValueError(f"register out of range: rt={rt} rn={rn}")
    if not (0 <= off <= 0xFFF):
        raise ValueError(f"STRB off out of imm12 range: {off}")
    insn = 0x39000000 | (off << 10) | (rn << 5) | rt
    return insn.to_bytes(4, "little")


def cmp_w_imm(rn: int, imm: int) -> bytes:
    """Encode `CMP Wn, #imm` (alias for SUBS WZR, Wn, #imm). 4 bytes; imm in [0, 4095]."""
    if not (0 <= rn < 32):
        raise ValueError(f"Rn out of range: {rn}")
    if not (0 <= imm <= 0xFFF):
        raise ValueError(f"CMP imm out of imm12 range: {imm}")
    insn = 0x7100001F | (imm << 10) | (rn << 5)
    return insn.to_bytes(4, "little")


_COND_CODES = {
    "EQ": 0, "NE": 1, "CS": 2, "CC": 3, "MI": 4, "PL": 5, "VS": 6, "VC": 7,
    "HI": 8, "LS": 9, "GE": 10, "LT": 11, "GT": 12, "LE": 13, "AL": 14, "NV": 15,
}


def cset_w_cond(rd: int, cond: str) -> bytes:
    """Encode `CSET Wd, <cond>` (alias for CSINC Wd, WZR, WZR, !cond). 4 bytes."""
    if not (0 <= rd < 32):
        raise ValueError(f"Rd out of range: {rd}")
    if cond not in _COND_CODES:
        raise ValueError(f"unknown condition: {cond}")
    c = _COND_CODES[cond] ^ 1  # CSET inverts
    insn = 0x1A9F07E0 | (c << 12) | rd
    return insn.to_bytes(4, "little")


def b_imm(src: int, dst: int) -> bytes:
    """Encode `B <dst>` placed at `src` (4 bytes). Both must be 4B-aligned and within ±128 MiB."""
    if src % 4 != 0 or dst % 4 != 0:
        raise ValueError(f"B requires 4B alignment: src=0x{src:X} dst=0x{dst:X}")
    delta = (dst - src) // 4
    if not (-(1 << 25) <= delta < (1 << 25)):
        raise ValueError(f"B out of range: src=0x{src:X} dst=0x{dst:X} delta={delta}")
    imm26 = delta & 0x3FFFFFF
    insn = 0x14000000 | imm26
    return insn.to_bytes(4, "little")


def bl_imm(src: int, dst: int) -> bytes:
    """Encode `BL <dst>` placed at `src` (4 bytes). Like `b_imm` but link-register variant."""
    if src % 4 != 0 or dst % 4 != 0:
        raise ValueError(f"BL requires 4B alignment: src=0x{src:X} dst=0x{dst:X}")
    delta = (dst - src) // 4
    if not (-(1 << 25) <= delta < (1 << 25)):
        raise ValueError(f"BL out of range: src=0x{src:X} dst=0x{dst:X} delta={delta}")
    imm26 = delta & 0x3FFFFFF
    insn = 0x94000000 | imm26
    return insn.to_bytes(4, "little")


def b_cond(src: int, dst: int, cond: str) -> bytes:
    """Encode `B.<cond> <dst>` at `src`. 4 bytes; range ±1 MiB (imm19)."""
    if src % 4 != 0 or dst % 4 != 0:
        raise ValueError(f"B.cond requires 4B alignment")
    if cond not in _COND_CODES:
        raise ValueError(f"unknown condition: {cond}")
    delta = (dst - src) // 4
    if not (-(1 << 18) <= delta < (1 << 18)):
        raise ValueError(f"B.cond out of range: delta={delta}")
    imm19 = delta & 0x7FFFF
    insn = 0x54000000 | (imm19 << 5) | _COND_CODES[cond]
    return insn.to_bytes(4, "little")


def br_x(rn: int) -> bytes:
    """Encode `BR Xn` (indirect jump). 4 bytes."""
    if not (0 <= rn < 32):
        raise ValueError(f"Rn out of range: {rn}")
    insn = 0xD61F0000 | (rn << 5)
    return insn.to_bytes(4, "little")


def ret_insn() -> bytes:
    """Encode `RET` (4 bytes)."""
    return (0xD65F03C0).to_bytes(4, "little")


def stp_pre_x(rt1: int, rt2: int, rn: int, off: int) -> bytes:
    """Encode `STP Xt1, Xt2, [Xn, #off]!` (pre-index, 64-bit pair). off in [-512, 504], 8B aligned."""
    if not (0 <= rt1 < 32 and 0 <= rt2 < 32 and 0 <= rn < 32):
        raise ValueError("register out of range")
    if off % 8 != 0 or not (-512 <= off <= 504):
        raise ValueError(f"STP off out of range: {off}")
    imm7 = (off // 8) & 0x7F
    insn = 0xA9800000 | (imm7 << 15) | (rt2 << 10) | (rn << 5) | rt1
    return insn.to_bytes(4, "little")


def stp_off_x(rt1: int, rt2: int, rn: int, off: int) -> bytes:
    """Encode `STP Xt1, Xt2, [Xn, #off]` (signed offset, no writeback)."""
    if not (0 <= rt1 < 32 and 0 <= rt2 < 32 and 0 <= rn < 32):
        raise ValueError("register out of range")
    if off % 8 != 0 or not (-512 <= off <= 504):
        raise ValueError(f"STP off out of range: {off}")
    imm7 = (off // 8) & 0x7F
    insn = 0xA9000000 | (imm7 << 15) | (rt2 << 10) | (rn << 5) | rt1
    return insn.to_bytes(4, "little")


def ldp_off_x(rt1: int, rt2: int, rn: int, off: int) -> bytes:
    """Encode `LDP Xt1, Xt2, [Xn, #off]` (signed offset, no writeback)."""
    if not (0 <= rt1 < 32 and 0 <= rt2 < 32 and 0 <= rn < 32):
        raise ValueError("register out of range")
    if off % 8 != 0 or not (-512 <= off <= 504):
        raise ValueError(f"LDP off out of range: {off}")
    imm7 = (off // 8) & 0x7F
    insn = 0xA9400000 | (imm7 << 15) | (rt2 << 10) | (rn << 5) | rt1
    return insn.to_bytes(4, "little")


def ldp_post_x(rt1: int, rt2: int, rn: int, off: int) -> bytes:
    """Encode `LDP Xt1, Xt2, [Xn], #off` (post-index)."""
    if not (0 <= rt1 < 32 and 0 <= rt2 < 32 and 0 <= rn < 32):
        raise ValueError("register out of range")
    if off % 8 != 0 or not (-512 <= off <= 504):
        raise ValueError(f"LDP off out of range: {off}")
    imm7 = (off // 8) & 0x7F
    insn = 0xA8C00000 | (imm7 << 15) | (rt2 << 10) | (rn << 5) | rt1
    return insn.to_bytes(4, "little")


def adrp(rd: int, src_va: int, dst_va: int) -> bytes:
    """Encode `ADRP Xd, page_of(dst)`. src_va is the address this insn lives at."""
    if not (0 <= rd < 32):
        raise ValueError(f"Rd out of range: {rd}")
    src_page = src_va & ~0xFFF
    dst_page = dst_va & ~0xFFF
    delta_pages = (dst_page - src_page) >> 12
    if not (-(1 << 20) <= delta_pages < (1 << 20)):
        raise ValueError(f"ADRP out of range: delta_pages={delta_pages}")
    imm21 = delta_pages & 0x1FFFFF
    immlo = imm21 & 3
    immhi = (imm21 >> 2) & 0x7FFFF
    insn = 0x90000000 | (immlo << 29) | (immhi << 5) | rd
    return insn.to_bytes(4, "little")


def add_x_imm(rd: int, rn: int, imm: int) -> bytes:
    """Encode `ADD Xd, Xn, #imm` (sf=1, 12-bit unsigned imm, no shift)."""
    if not (0 <= rd < 32 and 0 <= rn < 32):
        raise ValueError("register out of range")
    if not (0 <= imm <= 0xFFF):
        raise ValueError(f"ADD imm out of imm12 range: {imm}")
    insn = 0x91000000 | (imm << 10) | (rn << 5) | rd
    return insn.to_bytes(4, "little")


def ldr_x_imm(rt: int, rn: int, off: int) -> bytes:
    """Encode `LDR Xt, [Xn, #off]` (64-bit, byte-offset must be 8B aligned)."""
    if not (0 <= rt < 32 and 0 <= rn < 32):
        raise ValueError("register out of range")
    if off < 0 or off % 8 != 0 or off > 0xFFF * 8:
        raise ValueError(f"LDR X off out of imm12*8 range: {off}")
    imm12 = off // 8
    insn = 0xF9400000 | (imm12 << 10) | (rn << 5) | rt
    return insn.to_bytes(4, "little")


def mov_reg(rd: int, rm: int, sf: int = 1) -> bytes:
    """Encode `MOV Xd, Xm` (alias for ORR Xd, XZR, Xm). sf=1 for 64-bit, sf=0 for 32-bit."""
    if not (0 <= rd < 32 and 0 <= rm < 32):
        raise ValueError("register out of range")
    insn = (sf << 31) | 0x2A0003E0 | (rm << 16) | rd  # ORR Wd, WZR, Wm
    return insn.to_bytes(4, "little")


def str_w_imm(rt: int, rn: int, off: int) -> bytes:
    """Encode `STR Wt, [Xn, #off]` (32-bit store, byte off must be 4B aligned)."""
    if not (0 <= rt < 32 and 0 <= rn < 32):
        raise ValueError("register out of range")
    if off < 0 or off % 4 != 0 or off > 0xFFF * 4:
        raise ValueError(f"STR W off out of imm12*4 range: {off}")
    imm12 = off // 4
    insn = 0xB9000000 | (imm12 << 10) | (rn << 5) | rt
    return insn.to_bytes(4, "little")


def str_x_imm(rt: int, rn: int, off: int) -> bytes:
    """Encode `STR Xt, [Xn, #off]` (64-bit store, byte off must be 8B aligned)."""
    if not (0 <= rt < 32 and 0 <= rn < 32):
        raise ValueError("register out of range")
    if off < 0 or off % 8 != 0 or off > 0xFFF * 8:
        raise ValueError(f"STR X off out of imm12*8 range: {off}")
    imm12 = off // 8
    insn = 0xF9000000 | (imm12 << 10) | (rn << 5) | rt
    return insn.to_bytes(4, "little")


def add_x_reg(rd: int, rn: int, rm: int) -> bytes:
    """Encode `ADD Xd, Xn, Xm` (sf=1, register form, no shift). 4 bytes."""
    if not (0 <= rd < 32 and 0 <= rn < 32 and 0 <= rm < 32):
        raise ValueError("register out of range")
    insn = 0x8B000000 | (rm << 16) | (rn << 5) | rd
    return insn.to_bytes(4, "little")


def add_w_imm(rd: int, rn: int, imm: int) -> bytes:
    """Encode `ADD Wd, Wn, #imm` (sf=0, 12-bit imm)."""
    if not (0 <= rd < 32 and 0 <= rn < 32):
        raise ValueError("register out of range")
    if not (0 <= imm <= 0xFFF):
        raise ValueError(f"ADD imm out of imm12 range: {imm}")
    insn = 0x11000000 | (imm << 10) | (rn << 5) | rd
    return insn.to_bytes(4, "little")


def cbz_x(src: int, rt: int, dst: int) -> bytes:
    """Encode `CBZ Xt, <dst>`. Range ±1 MiB (imm19)."""
    if not (0 <= rt < 32):
        raise ValueError("Rt out of range")
    if src % 4 != 0 or dst % 4 != 0:
        raise ValueError("CBZ requires 4B alignment")
    delta = (dst - src) // 4
    if not (-(1 << 18) <= delta < (1 << 18)):
        raise ValueError(f"CBZ out of range: {delta}")
    imm19 = delta & 0x7FFFF
    insn = 0xB4000000 | (imm19 << 5) | rt
    return insn.to_bytes(4, "little")


def cbnz_x(src: int, rt: int, dst: int) -> bytes:
    """Encode `CBNZ Xt, <dst>`. Range ±1 MiB (imm19)."""
    if not (0 <= rt < 32):
        raise ValueError("Rt out of range")
    if src % 4 != 0 or dst % 4 != 0:
        raise ValueError("CBNZ requires 4B alignment")
    delta = (dst - src) // 4
    if not (-(1 << 18) <= delta < (1 << 18)):
        raise ValueError(f"CBNZ out of range: {delta}")
    imm19 = delta & 0x7FFFF
    insn = 0xB5000000 | (imm19 << 5) | rt
    return insn.to_bytes(4, "little")


def cbz_w(src: int, rt: int, dst: int) -> bytes:
    if not (0 <= rt < 32):
        raise ValueError("Rt out of range")
    delta = (dst - src) // 4
    if not (-(1 << 18) <= delta < (1 << 18)):
        raise ValueError(f"CBZ W out of range: {delta}")
    imm19 = delta & 0x7FFFF
    insn = 0x34000000 | (imm19 << 5) | rt
    return insn.to_bytes(4, "little")


def cbnz_w(src: int, rt: int, dst: int) -> bytes:
    if not (0 <= rt < 32):
        raise ValueError("Rt out of range")
    delta = (dst - src) // 4
    if not (-(1 << 18) <= delta < (1 << 18)):
        raise ValueError(f"CBNZ W out of range: {delta}")
    imm19 = delta & 0x7FFFF
    insn = 0x35000000 | (imm19 << 5) | rt
    return insn.to_bytes(4, "little")


def adrp_add_pair(src_va: int, rd: int, target_va: int) -> bytes:
    """Emit `ADRP Xd, page; ADD Xd, Xd, #lo12` to materialize the address of `target_va` in Xd.
    Two instructions, 8 bytes total."""
    out = bytearray()
    out += adrp(rd, src_va, target_va)
    lo12 = target_va & 0xFFF
    out += add_x_imm(rd, rd, lo12)
    return bytes(out)


def adrp_ldr_x_pair(src_va: int, rd_tmp: int, ptr_va: int) -> bytes:
    """Emit `ADRP Xd, page; LDR Xd, [Xd, #lo12]` to load the 8-byte value stored at ptr_va.
    Used for classref / selref / GOT entries. ptr_va must be 8-byte aligned."""
    if ptr_va % 8 != 0:
        raise ValueError(f"ptr_va not 8-aligned: 0x{ptr_va:X}")
    out = bytearray()
    out += adrp(rd_tmp, src_va, ptr_va)
    lo12 = ptr_va & 0xFFF
    out += ldr_x_imm(rd_tmp, rd_tmp, lo12)
    return bytes(out)


# ---------------------------------------------------------------------------
# Code cave region.
#
# `__TEXT,__oslogstring` ends at 0x8268023; the segment runs to 0x826C000 so
# there is a 0x3FDC-byte run of zeros after it that lives in the same r-x
# mapping as every other UnityFramework instruction. We carve cave payloads
# out of that range, 4-byte aligned (start = 0x8268024).
#
# Re-verify if you reach for a different Unity drop:
#   - tail of __oslogstring must remain all-zero (no new strings added)
#   - __TEXT segment maxprot must stay r-x (it normally does)
# Both invariants checked in `verify_cave_region()`.
#
# Payload addressing identity:
#   We allocate sequentially from CODE_CAVE_START in the order CAVE_PATCHES is
#   declared. So as long as the list order is stable, every payload lands at
#   the same VA on every run — a re-run of patch_unity.py against an already-
#   patched binary will see SKIP everywhere, just like for regular PATCHES.
# ---------------------------------------------------------------------------

CODE_CAVE_START = 0x8268024
CODE_CAVE_END   = 0x826C000  # exclusive
CODE_CAVE_SIZE  = CODE_CAVE_END - CODE_CAVE_START  # 0x3FDC = 16348 bytes


# Mirrors KIOU_SAFE_SKIN_ID in Sources/KiouEditor/Internal.h. Keep both in sync;
# this is the id we tell the server we picked.
KIOU_SAFE_SKIN_ID = 1

# The id we light up as "selected" in InternalMergeFrom-decoded lists. With the
# runtime tweak this is the user's last-tapped skin, persisted in NSUserDefaults.
# In the static-patch flow there is no user input, so we pin it to a single
# constant — change this to whatever skin you want to see as your character.
# Must fit a CMP Wn,#imm12 (i.e. <= 0xFFF = 4095). Set it equal to
# KIOU_SAFE_SKIN_ID to fall back to "show what the server says".
KIOU_DISPLAY_SKIN_ID = KIOU_SAFE_SKIN_ID


# (file_offset, expected_orig_8B, replacement_8B, label)
PATCHES = [
    (
        0x593E630,
        bytes.fromhex("0040 4039 c003 5fd6".replace(" ", "")),
        mov_w0_imm_ret(1),
        "ResolvedBeginnerSupport.get_Enabled -> true",
    ),
    (
        0x593E650,
        bytes.fromhex("0020 40b9 c003 5fd6".replace(" ", "")),
        mov_w0_imm_ret(16),
        "ResolvedBeginnerSupport.get_Depth -> 16",
    ),
    (
        0x585B25C,
        bytes.fromhex("0000 4139 c003 5fd6".replace(" ", "")),
        mov_w0_imm_ret(1),
        "KifuDetailModel.IsPremiumUser -> true",
    ),
    (
        0x5C00D88,
        bytes.fromhex("0080 4039 c003 5fd6".replace(" ", "")),
        mov_w0_imm_ret(1),
        "GetShogiHistoryDetailListReply.get_IsPremiumUser -> true",
    ),
    (
        0x584ADC0,
        bytes.fromhex("0070 4039 c003 5fd6".replace(" ", "")),
        mov_w0_imm_ret(0),
        "CharacterVoiceScrollerCellModel.get_IsLocked -> false",
    ),
    # ---- Voice unlock companion: pin CharacterStatus intimacy to max ----
    # Hook_SyncItemList used to write intimacyLevel=5 / isIntimacyAtMax=1 onto
    # every CharacterStatus element after the reply was decoded. Inline-patching
    # the corresponding getters achieves the same effect without touching the
    # decoder: every reader (CharacterVoicePlayer construction, cell badge
    # build, "親密度Xで解放" condition) now sees Level5 + atMax across the board.
    (
        0x5CEF4C8,
        bytes.fromhex("001c 40b9 c003 5fd6".replace(" ", "")),
        mov_w0_imm_ret(5),
        "CharacterStatus.get_IntimacyLevel -> 5",
    ),
    (
        0x5CEF558,
        bytes.fromhex("001c 4139 c003 5fd6".replace(" ", "")),
        mov_w0_imm_ret(1),
        "CharacterStatus.get_IsIntimacyAtMax -> true",
    ),
    # ---- BeginnerSupportEvaluator tuning via BeginnerSupportSettings getters --
    # Hook_AssistTune used to overwrite BSE's _analysisDepth (+0x18) and
    # _engineSkillLevel (+0x28) AFTER orig ctor ran, because the ctor copies
    # those values out of BeginnerSupportSettings (a ScriptableObject).
    # Inline-patching the Settings getters to return constants achieves the
    # same effect at the source: whether the engine reads through ctor copy or
    # re-reads later, both paths see depth=16 / skill=20.
    #
    # Both getters are >8 bytes (Unity adds a clamp/CSEL on top of the raw
    # field load), but the return path always lands on W0; overwriting the
    # first 8 bytes with MOV W0,#imm; RET short-circuits the clamp and the
    # remaining dead code never executes. Function boundary stays intact.
    # AnalysisDepth is the post-game review depth (used by the analysis
    # screen), NOT the in-game hint engine. Pinning it to 16 made every move
    # during a live match incur a deep search; pin it to 1 since the player
    # never runs the analysis flow anyway. Engine strength during play is
    # governed by EngineSkillLevel below.
    (
        0x597DEF4,
        bytes.fromhex("0818 40b9 1f05 0071".replace(" ", "")),
        mov_w0_imm_ret(1),
        "BeginnerSupportSettings.get_AnalysisDepth -> 1",
    ),
    (
        0x597DF48,
        bytes.fromhex("0830 40b9 007d a80a".replace(" ", "")),
        mov_w0_imm_ret(20),
        "BeginnerSupportSettings.get_EngineSkillLevel -> 20",
    ),
    # ---- Character ownership flags (CharacterStatus) ----
    # Hook_SyncItemList used to flip isContract_/isAcquired_/isContractAvailable_
    # on every CharacterStatus after the reply was decoded. Inline-patching the
    # getters covers every read path (UI gating, contract dialog visibility,
    # character grid acquire badge) without touching the decoder.
    (
        0x5CEF4D8,
        bytes.fromhex("0080 4039 c003 5fd6".replace(" ", "")),
        mov_w0_imm_ret(1),
        "CharacterStatus.get_IsContract -> true",
    ),
    (
        0x5CEF4F8,
        bytes.fromhex("00c0 4039 c003 5fd6".replace(" ", "")),
        mov_w0_imm_ret(1),
        "CharacterStatus.get_IsAcquired -> true",
    ),
    (
        0x5CEF548,
        bytes.fromhex("0018 4139 c003 5fd6".replace(" ", "")),
        mov_w0_imm_ret(1),
        "CharacterStatus.get_IsContractAvailable -> true",
    ),
    # ---- Force-enable in-match assist ----
    # The real gate on the in-match hint arrow is NOT ResolvedBeginnerSupport
    # (Hook_AssistEnable was a red herring — its getter is fully inlined and
    # was never reached); it is the per-player enableBeginnerSupport_ field
    # at ShogiMatchingPlayerStatus +0x68. Two cover patches:
    #
    # (a) Wire-level — InternalMergeFrom decoder @ 0x5B4CAEC.
    #     0x5B4CEBC: BL  <protobuf bool decoder>      ; W0 = decoded bit
    #     0x5B4CEC0: CMP W0, #0
    #     0x5B4CEC4: CSET W8, NE                      ; W8 = (W0 != 0)
    #     0x5B4CEC8: STRB W8, [X20, #0x68]            ; player.enableBS = W8
    #     CSET -> MOVZ W8,#1 forces the decoder to commit 1 regardless of the
    #     wire value, covering replies that include the field as false.
    #
    # (b) Reader-level — ShogiMatchingPlayerStatus.get_EnableBeginnerSupport.
    #     0x5B4BC74: LDRB W0, [X0, #0x68]; RET        (8-byte leaf getter)
    #     Patched to `MOV W0,#1; RET`. This is the patch that actually fixes
    #     "hint arrow doesn't show up": when the reply OMITS the proto3 bool
    #     entirely (its default = false, often dropped from wire), the
    #     decoder case in (a) never fires and +0x68 stays at the struct's
    #     zero-init value. Hook_MatchingPlayer.m used to patch +0x68 to 1
    #     after orig decode to cover that case; inline-patching the getter
    #     to return true achieves the same effect without touching the
    #     struct, so the value of +0x68 no longer matters to UI readers.
    #
    # Caveat (both patches): they affect every ShogiMatchingPlayerStatus, not
    # just self. Accepted since no known UI code path reads the opponent's
    # flag for display.
    (
        0x5B4CEC4,
        bytes.fromhex("e8 07 9f 1a"),    # CSET W8, NE
        bytes.fromhex("28 00 80 52"),    # MOVZ W8, #1
        "ShogiMatchingPlayerStatus.MergeFrom: enableBeginnerSupport <- 1",
    ),
    (
        0x5B4BC74,
        bytes.fromhex("00a0 4139 c003 5fd6".replace(" ", "")),
        mov_w0_imm_ret(1),
        "ShogiMatchingPlayerStatus.get_EnableBeginnerSupport -> true",
    ),
    # ---- BSE.EnsureInitializedLocked: NNUE hash 16 MB -> 256 MB ----
    # The retail path actually DOES call NativeSyncSession.SetHashSize — as a
    # tail call from EnsureInitializedLocked itself (Hook_AssistTune.m's
    # comment that "no retail path sets the hash" was wrong; orig was setting
    # 16 MB, and Hook_AssistTune.m was injecting a second call that overrode
    # it). The literal lives one instruction before the branch:
    #     0x597BBA8: MOVZ W1, #0x10             ; mb = 16
    #     0x597BBAC: MOVZ X2, #0                ; methodInfo = NULL
    #     0x597BBB0-8: epilogue
    #     0x597BBBC: B   SetHashSize @ 0x5D320E0
    # Bumping the literal to 256 MB reuses the existing call site, so no
    # extra hook or code cave is needed. 256 MB is one preset above the old
    # tweak default of 128 MB — generous on modern devices, still safe on
    # iPhone 11+.
    (
        0x597BBA8,
        bytes.fromhex("0102 8052"),       # MOVZ W1, #16
        movz_w_imm(rd=1, imm=256),        # MOVZ W1, #256
        "BSE.EnsureInitializedLocked: NNUE hash 16 MB -> 256 MB",
    ),
    # ---- Item ownership (SupplyStatus) ----
    # Hook_SyncItemList used to flip SupplyStatus.isAcquired_ and acquiredCount_
    # ON the wire (decode-time tamper) but only inside the decoration band
    # (icons/frames/titles/pieces/boards/bgm) to avoid disturbing currency or
    # character supplies. The "force-true everywhere" variant trades that
    # discipline for simplicity: every supply in every reply reads as acquired.
    # If a side effect shows up (currency display weirdness, etc.) revisit and
    # gate on supplyBand inside the decoder instead.
    (
        0x5B61914,
        bytes.fromhex("00c0 4039 c003 5fd6".replace(" ", "")),
        mov_w0_imm_ret(1),
        "SupplyStatus.get_IsAcquired -> true",
    ),
    # NOTE: SupplyStatus.get_AcquiredCount is intentionally left alone — the
    # decoration-band UI only branches on isAcquired, so forcing the count to
    # 1 was unnecessary and might affect currency / counter displays. Re-enable
    # the entry below if a future check actually needs it.
    # (
    #     0x5B61924,
    #     bytes.fromhex("0034 40b9 c003 5fd6".replace(" ", "")),
    #     mov_w0_imm_ret(1),
    #     "SupplyStatus.get_AcquiredCount -> 1",
    # ),
    # NOTE: SelectCharacterArgs.InternalWriteTo @ 0x5C25FEC was originally a
    # 4B strict patch that pinned W1=SAFE_ID before WriteInt32. It is now
    # handled by CAVE_PATCHES below ("save X and emit SAFE_ID") which
    # additionally persists the user's X to NSUserDefaults.
]


# ---------------------------------------------------------------------------
# Cave-based patches.
#
# When a logic change cannot fit in the 4/8-byte slot at the call site (e.g.
# we want "isSelected = (mstSkinId == Y)" but only a single instruction is
# locally free), we redirect that one instruction to a code cave in
# __TEXT,__oslogstring's tail zero-fill (see CODE_CAVE_START above).
#
# Each CAVE_PATCHES entry is:
#   (site_off, expected_orig_4B, build_payload, label)
#       site_off       — file offset of the single instruction we redirect
#       expected_orig  — its current 4-byte encoding, verified before write
#       build_payload  — callable(cave_va: int) -> bytes
#                        returns the instructions to place at `cave_va`. The
#                        last instruction is usually a `B` back to the next
#                        live instruction after `site_off`. Length must be a
#                        multiple of 4. The site is then patched to `B cave_va`.
#       label          — human-readable description
#
# Allocation is sequential and order-stable, so re-runs land cave bytes at
# identical addresses (the "already patched" SKIP path still works for both
# the site and the cave content).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# NSUserDefaults bridge: addresses harvested from the live UnityFramework.
#
# All of these are sections / symbols Unity already uses internally, so dyld
# binds them on load and we can reach them via ADRP+LDR without adding any
# new chained-fixup entries. Re-derive on each Unity rev:
#
#   _objc_msgSend stub        : __TEXT,__stubs slot whose indirect symbol == _objc_msgSend
#   classref NSString         : __DATA,__objc_classrefs entry binding to OBJC_CLASS_$_NSString
#   classref NSUserDefaults   : same, OBJC_CLASS_$_NSUserDefaults
#   selref standardUserDefaults / stringWithUTF8String: / setInteger:forKey: / integerForKey:
#                              : __DATA,__objc_selrefs entries whose rebase target
#                                points to the matching __TEXT,__objc_methname string
# ---------------------------------------------------------------------------

NSUD_OBJC_MSGSEND_STUB    = 0x71029B4
NSUD_CLASSREF_NSSTRING    = 0x896D140
NSUD_CLASSREF_NSUD        = 0x896D650
NSUD_SELREF_STD_UD        = 0x896A9F8   # standardUserDefaults
NSUD_SELREF_STR_UTF8      = 0x896AC18   # stringWithUTF8String:
NSUD_SELREF_SET_INT_KEY   = 0x8969FF0   # setInteger:forKey:
NSUD_SELREF_GET_INT_KEY   = 0x8968408   # integerForKey:

# Player-cave additions: NSString utility selrefs used by the match-screen
# avatar fixup. All harvested from Unity's existing selref table.
NSUD_SELREF_STR_CHARS_LEN = 0x896AC00   # stringWithCharacters:length:
NSUD_SELREF_IS_EQUAL_STR  = 0x8968578   # isEqualToString:
NSUD_SELREF_STRING_FOR_KEY = 0x896ABC8  # stringForKey: (NSUserDefaults)
NSUD_SELREF_SET_OBJ_KEY   = 0x896A1F0   # setObject:forKey:

# Keys under which the user's last-tapped (skin, char) pair is persisted.
# The skin key MUST match `kPersistedSelectionKey` in
# Sources/KiouEditor/Hook_SelectCharacter.m so the jailbroken Tweak and the
# static-patched IPA share state on the same device. The char key is unique
# to the static-patch flow — the tweak derives char from a lookup table; here
# we save it eagerly when the matching skin element is decoded.
NSUD_KEY_SKIN_CSTR = b"kiou_editor.persisted_skin_id\x00"
NSUD_KEY_CHAR_CSTR = b"kiou_editor.persisted_char_id\x00"

# Backwards-compat alias for sites that still reference the original name.
NSUD_KEY_CSTR = NSUD_KEY_SKIN_CSTR

# Key under which the self-player's UUID is cached for the match-screen cave.
# Mirrors `kSelfUserIdKey` in Sources/KiouEditor/Hook_MatchingPlayer.m so the
# jailbroken Tweak and the static-patched IPA share state on the same device.
NSUD_KEY_SELFID_CSTR = b"kiou_editor.self_user_id\x00"

# Sentinel userId used by the CPU opponent. We early-exit if the decoded
# userId equals this.
NSUD_CPU_USERID_CSTR = b"cpu\x00"


class CaveAssembler:
    """Tiny streaming assembler for code caves.

    Tracks the current VA inside the cave so emitters can compute PC-relative
    operands without manual bookkeeping. Labels are recorded as VAs and used
    by `patch_branch()` to back-fill conditional branches after the target's
    VA is known.

    Two-pass layout pattern (used by the NSUserDefaults caves):
      1. First pass: emit all instructions and the trailing data (e.g. key
         cstring). Record `label("data")` at the data's VA up front so emit
         helpers can refer to it.
      2. Second pass: walk pending branch fixups and overwrite the placeholders.

    Everything is little-endian arm64. No reordering, no relaxation.
    """

    def __init__(self, start_va: int):
        self.start = start_va
        self.buf = bytearray()
        self._fixups: list[tuple[int, int, str]] = []  # (off, src_va_at_emit, label)
        self._labels: dict[str, int] = {}

    # location helpers --------------------------------------------------------
    @property
    def va(self) -> int:
        return self.start + len(self.buf)

    def label(self, name: str, va: int | None = None) -> None:
        self._labels[name] = self.va if va is None else va

    # raw emit ----------------------------------------------------------------
    def emit(self, raw: bytes) -> None:
        if len(raw) % 4 != 0:
            raise ValueError(f"emit: not 4B aligned (len={len(raw)})")
        self.buf += raw

    def emit_data(self, raw: bytes) -> None:
        """Emit non-instruction bytes (e.g. cstrings); pads to 4B for alignment."""
        self.buf += raw
        while len(self.buf) % 4 != 0:
            self.buf += b"\x00"

    # instruction shorthands --------------------------------------------------
    def adrp_ldr_x(self, rd: int, ptr_va: int) -> None:
        self.emit(adrp_ldr_x_pair(self.va, rd, ptr_va))

    def adrp_add(self, rd: int, target_va: int) -> None:
        self.emit(adrp_add_pair(self.va, rd, target_va))

    def bl(self, target_va: int) -> None:
        self.emit(bl_imm(self.va, target_va))

    def b(self, target_va: int) -> None:
        self.emit(b_imm(self.va, target_va))

    def mov_xreg(self, rd: int, rm: int) -> None:
        self.emit(mov_reg(rd, rm, sf=1))

    def mov_wreg(self, rd: int, rm: int) -> None:
        self.emit(mov_reg(rd, rm, sf=0))

    def movz_w(self, rd: int, imm: int) -> None:
        self.emit(movz_w_imm(rd, imm))

    def ldr_w(self, rt: int, rn: int, off: int) -> None:
        self.emit(ldr_w_imm(rt, rn, off))

    def strb_w(self, rt: int, rn: int, off: int) -> None:
        self.emit(strb_w_imm(rt, rn, off))

    def cmp_w(self, rn: int, imm: int) -> None:
        self.emit(cmp_w_imm(rn, imm))

    def cset_w(self, rd: int, cond: str) -> None:
        self.emit(cset_w_cond(rd, cond))

    def stp_pre_x(self, rt1: int, rt2: int, rn: int, off: int) -> None:
        self.emit(stp_pre_x(rt1, rt2, rn, off))

    def stp_off_x(self, rt1: int, rt2: int, rn: int, off: int) -> None:
        self.emit(stp_off_x(rt1, rt2, rn, off))

    def ldp_off_x(self, rt1: int, rt2: int, rn: int, off: int) -> None:
        self.emit(ldp_off_x(rt1, rt2, rn, off))

    def ldp_post_x(self, rt1: int, rt2: int, rn: int, off: int) -> None:
        self.emit(ldp_post_x(rt1, rt2, rn, off))

    def raw_insn(self, word: int) -> None:
        self.emit(word.to_bytes(4, "little"))

    def str_w(self, rt: int, rn: int, off: int) -> None:
        self.emit(str_w_imm(rt, rn, off))

    def str_x(self, rt: int, rn: int, off: int) -> None:
        self.emit(str_x_imm(rt, rn, off))

    def add_xreg(self, rd: int, rn: int, rm: int) -> None:
        self.emit(add_x_reg(rd, rn, rm))

    def add_x(self, rd: int, rn: int, imm: int) -> None:
        self.emit(add_x_imm(rd, rn, imm))

    def add_w(self, rd: int, rn: int, imm: int) -> None:
        self.emit(add_w_imm(rd, rn, imm))

    def movn_w(self, rd: int, imm: int) -> None:
        """`MOVN Wd, #imm` (Wd = ~imm). With imm=0 produces 0xFFFFFFFF (= -1)."""
        if not (0 <= rd < 32):
            raise ValueError(f"Rd out of range: {rd}")
        if not (0 <= imm <= 0xFFFF):
            raise ValueError(f"MOVN imm out of imm16 range: {imm}")
        self.emit((0x12800000 | (imm << 5) | rd).to_bytes(4, "little"))

    def cmp_w_reg(self, rn: int, rm: int) -> None:
        """`CMP Wn, Wm` (SUBS WZR, Wn, Wm)."""
        if not (0 <= rn < 32 and 0 <= rm < 32):
            raise ValueError("register out of range")
        self.emit((0x6B000000 | (rm << 16) | (rn << 5) | 31).to_bytes(4, "little"))

    def ldrb_w(self, rt: int, rn: int, off: int) -> None:
        """`LDRB Wt, [Xn, #off]` (zero-extended byte load, imm12)."""
        if not (0 <= rt < 32 and 0 <= rn < 32):
            raise ValueError("register out of range")
        if not (0 <= off <= 0xFFF):
            raise ValueError(f"LDRB off out of imm12 range: {off}")
        self.emit((0x39400000 | (off << 10) | (rn << 5) | rt).to_bytes(4, "little"))

    # branches with deferred targets -----------------------------------------
    def b_cond_to(self, label: str, cond: str) -> None:
        off = len(self.buf)
        self.emit(b"\x00\x00\x00\x00")
        self._fixups.append((off, self.start + off, label))
        self._branch_kinds[off] = ("b_cond", cond)

    def b_to(self, label: str) -> None:
        off = len(self.buf)
        self.emit(b"\x00\x00\x00\x00")
        self._fixups.append((off, self.start + off, label))
        self._branch_kinds[off] = ("b",)

    def cbz_to(self, rt: int, label: str, sf: int = 1) -> None:
        off = len(self.buf)
        self.emit(b"\x00\x00\x00\x00")
        self._fixups.append((off, self.start + off, label))
        self._branch_kinds[off] = ("cbz", rt, sf)

    def cbnz_to(self, rt: int, label: str, sf: int = 1) -> None:
        off = len(self.buf)
        self.emit(b"\x00\x00\x00\x00")
        self._fixups.append((off, self.start + off, label))
        self._branch_kinds[off] = ("cbnz", rt, sf)

    _branch_kinds: dict  # set in __init__ override below

    def finalize(self) -> bytes:
        for off, src_va, label in self._fixups:
            if label not in self._labels:
                raise KeyError(f"unresolved label '{label}'")
            tgt = self._labels[label]
            kind, *info = self._branch_kinds[off]
            if kind == "b_cond":
                self.buf[off:off+4] = b_cond(src_va, tgt, info[0])
            elif kind == "b":
                self.buf[off:off+4] = b_imm(src_va, tgt)
            elif kind == "cbz":
                rt, sf = info
                self.buf[off:off+4] = (cbz_x if sf else cbz_w)(src_va, rt, tgt)
            elif kind == "cbnz":
                rt, sf = info
                self.buf[off:off+4] = (cbnz_x if sf else cbnz_w)(src_va, rt, tgt)
            else:
                raise AssertionError(f"unknown branch kind: {kind}")
        return bytes(self.buf)


# Hook the dict creation into __init__ without subclassing.
_old_init = CaveAssembler.__init__
def _init(self, start_va):
    _old_init(self, start_va)
    self._branch_kinds = {}
CaveAssembler.__init__ = _init


def _save_skin_id_payload(cave_va: int) -> bytes:
    """InternalWriteTo cave: persist user's chosen X, then force the wire to SAFE_ID.

    Replaces 0x5C25FEC (originally `LDR W1, [X20, #0x18]`). The serializer
    around 0x5C25FC0 emits the protobuf field-1 as:

        0x5C25FD4: LDR  W8, [X0, #0x18]    ; default-skip check
        0x5C25FD8: CBZ  W8, end
        0x5C25FDC: MOV  X0, X19            ; receiver = CodedOutputStream
        0x5C25FE0: MOVZ W1, #0x8           ; tag
        0x5C25FE4: MOVZ X2, #0
        0x5C25FE8: BL   <WriteRawTag>
        0x5C25FEC: LDR  W1, [X20, #0x18]   ; ← redirected to cave
        0x5C25FF0: MOV  X0, X19            ; receiver again (we replay this)
        0x5C25FF4: MOVZ X2, #0             ; replay
        0x5C25FF8: BL   <WriteInt32>       ; cave returns here with W1=SAFE_ID

    Cave plan:
      - save X19/20/21/22, FP/LR
      - W19 = user's X (live mstSkinId from +0x18)
      - if W19 == SAFE_ID  → skip persistence (no-op; protects against
        re-decoded "send 1" requests from clobbering the saved choice on
        subsequent launches)
      - else: [[NSUserDefaults standardUserDefaults]
                  setInteger:X forKey:@"kiou_editor.persisted_skin_id"]
      - restore, set W1 = SAFE_ID, replay 0x5C25FF0/4 instructions, B 0x5C25FF8
    """
    a = CaveAssembler(cave_va)

    # 1. prologue. 0x30 frame (must be 16-aligned), saves three pairs.
    a.stp_pre_x(29, 30, 31, -0x30)
    a.stp_off_x(19, 20, 31, 0x10)
    a.stp_off_x(21, 22, 31, 0x20)

    # 2. W19 = user's X from the still-live X20 (the args pointer).
    a.ldr_w(19, 20, 0x18)
    # X22 holds the original args ptr too in case anything below clobbers X20.
    a.mov_xreg(22, 20)

    # 3. if W19 == SAFE_ID, skip the persistence — see docstring rationale.
    a.cmp_w(19, KIOU_SAFE_SKIN_ID)
    a.b_cond_to("skip_save", "EQ")

    # 4. X20 = ud = [NSUserDefaults standardUserDefaults]
    a.adrp_ldr_x(0, NSUD_CLASSREF_NSUD)
    a.adrp_ldr_x(1, NSUD_SELREF_STD_UD)
    a.bl(NSUD_OBJC_MSGSEND_STUB)
    a.mov_xreg(20, 0)

    # 5. X21 = key = [NSString stringWithUTF8String:KEY_CSTR]
    #    The cstring lives at the end of the payload, label "key".
    a.adrp_ldr_x(0, NSUD_CLASSREF_NSSTRING)
    a.adrp_ldr_x(1, NSUD_SELREF_STR_UTF8)
    a.adrp_add(2, _key_cstring_va(cave_va))   # see below for the trick
    a.bl(NSUD_OBJC_MSGSEND_STUB)
    a.mov_xreg(21, 0)

    # 6. [ud setInteger:W19 forKey:X21]
    a.mov_xreg(0, 20)
    a.adrp_ldr_x(1, NSUD_SELREF_SET_INT_KEY)
    a.mov_wreg(2, 19)
    a.mov_xreg(3, 21)
    a.bl(NSUD_OBJC_MSGSEND_STUB)

    # 7. skip_save: epilogue
    a.label("skip_save")
    a.ldp_off_x(21, 22, 31, 0x20)
    a.ldp_off_x(19, 20, 31, 0x10)
    a.ldp_post_x(29, 30, 31, 0x30)

    # 8. W1 = SAFE_SKIN_ID. Replay the two insns at 0x5C25FF0/4 that the
    #    redirect overran (MOV X0,X19; MOVZ X2,#0), and branch to BL WriteInt32.
    a.movz_w(1, KIOU_SAFE_SKIN_ID)
    a.raw_insn(0xAA1303E0)   # MOV  X0, X19      (== orig 0x5C25FF0)
    a.raw_insn(0xD2800002)   # MOVZ X2, #0       (== orig 0x5C25FF4)
    a.b(0x5C25FF8)

    # 9. key cstring at the end. Must land at exactly _key_cstring_va(cave_va).
    cur = a.va
    expected = _key_cstring_va(cave_va)
    if cur != expected:
        raise AssertionError(
            f"_save_skin_id_payload: cstring VA drift "
            f"(emitted up to 0x{cur:X}, expected 0x{expected:X}). "
            f"Adjust _key_cstring_va()."
        )
    a.emit_data(NSUD_KEY_CSTR)

    return a.finalize()


# The cstring address is needed before the code that emits it. We pin it as a
# constant offset from cave_va. If the instruction count changes you must
# update _SAVE_PAYLOAD_INSN_COUNT below, and the assertion in
# `_save_skin_id_payload` will catch any drift.
_SAVE_PAYLOAD_INSN_COUNT = 34  # number of 4B instructions emitted before the cstring


def _key_cstring_va(cave_va: int) -> int:
    return cave_va + _SAVE_PAYLOAD_INSN_COUNT * 4


# ---------------------------------------------------------------------------
# Post-decode "lists fixup" cave routine.
#
# This is a shared subroutine the two reply trampolines call. It performs the
# same flag-move logic as the runtime tweak's `kiou_applyPersistedSelectionToLists`:
#
#   X = ud[skin_key]
#   if X == 0: return                             # no override active
#
#   walk updatedCharacterSkinList_:
#     find tgt = index where mstSkinId == X
#     find cur = index where isSelected == 1
#     if tgt found and tgt != cur:
#       cur.isSelected = 0
#       tgt.isSelected = 1
#       tgt.isAcquired = 1
#       char_target = tgt.mstCharacterId   # also drives the char list below
#
#   if char_target found, walk updatedCharacterList_:
#     find tgt = index where mstCharacterId == char_target
#     find cur = index where isSelected == 1
#     if tgt found and tgt != cur:
#       cur.isSelected = 0
#       tgt.isSelected = 1
#       tgt.isAcquired = 1   (CharacterStatus.isAcquired @+0x30)
#
# If the target id is not present in a given reply's list (e.g. a
# SelectCharacterReply that only carries the SAFE-skin diff), the list is left
# untouched — so the server's own state stays consistent and the client's
# integrity check doesn't fire.
#
# Calling convention (cave routine is hand-written, not C ABI):
#   X0 = reply pointer (this)
#   X1 = char_list field offset on `this` (e.g. 0x18 or 0x28)
#   X2 = skin_list field offset on `this` (e.g. 0x20 or 0x30)
#   Clobbers X0..X18 + sets W0..W18 to garbage. Preserves X19..X28.
#   Returns via RET; trampolines call it with BL.
#
# Layout in cave: emitted ONCE, both trampolines BL to its entry VA. The cstring
# lives at the end of the helper payload; trampolines do NOT need their own
# cstrings.
# ---------------------------------------------------------------------------

# RepeatedField object layout (Google.Protobuf for Unity il2cpp):
OFF_RF_ARRAY = 0x10
OFF_RF_COUNT = 0x18
# il2cpp managed array header byte offset to element[0]:
OFF_ARRAY_DATA = 0x20

# CharacterSkinStatus field offsets (from dump.cs / Hook_SelectCharacter.m).
OFF_SKIN_MST_SKIN_ID    = 0x18
OFF_SKIN_MST_CHAR_ID    = 0x1C
OFF_SKIN_IS_ACQUIRED    = 0x20
OFF_SKIN_IS_SELECTED    = 0x21

# CharacterStatus field offsets.
OFF_CHAR_MST_ID         = 0x18
OFF_CHAR_IS_ACQUIRED    = 0x30
OFF_CHAR_IS_SELECTED    = 0x45


def _apply_lists_fixup_payload(cave_va: int) -> bytes:
    """Build the shared lists-fixup helper. Hybrid flag-move + id-rewrite.

    Pseudocode:
        X = ud[skin_key];       if X == 0: return
        skin_rf = (RepField*)(this + skin_off);    if !skin_rf: return
        skin_arr = skin_rf->arr;  skin_count = skin_rf->count
        if skin_arr && skin_count > 0:
            cur, tgt = -1, -1
            for i: elem = skin_arr[OFF_ARRAY_DATA + i*8]
                if elem.mstSkinId == X: tgt=i, tgt_elem=elem
                if elem.isSelected:     cur=i, cur_elem=elem
            if tgt != -1:
                if cur != tgt:
                    if cur != -1: cur_elem.isSelected = 0
                    tgt_elem.isSelected = 1
                tgt_elem.isAcquired = 1
                char_target = tgt_elem.mstCharacterId
            elif cur != -1:
                # id rewrite: ride on the existing selected entry, retag it as X
                cur_elem.mstSkinId = X
                cur_elem.isAcquired = 1
                char_target = cur_elem.mstCharacterId
                # NOTE: in this branch the entry's mstCharacterId is whatever
                # the server returned (its real parent character), which is
                # the same character row the server has selected. That makes
                # the char-list pass a no-op (cur==tgt) and is correct.

        if char_target == 0: return
        char_rf = (RepField*)(this + char_off);    if !char_rf: return
        ...same hybrid pattern on the char list using char_target...

    Register usage during the loops:
        X19 = this, X20 = char_off, X21 = skin_off, X23 = ud (unused below)
        W22 = X (saved skin id), W28 = char_target
        X25 = RepField*, X26 = arr, W27 = count
        X8 = elem-slot ptr (arr + 0x20 + i*8 as we iterate)
        W11 = i, W9 = tgt_idx, W10 = cur_idx
        X12 = tgt_elem, X16 = cur_elem
        W13/14/15/X13 = scratch
    """
    a = CaveAssembler(cave_va)
    key_va = _apply_skin_key_va(cave_va)

    # ---- prologue: 0x60 frame, 6 callee pairs.
    a.stp_pre_x(29, 30, 31, -0x60)
    a.stp_off_x(19, 20, 31, 0x10)
    a.stp_off_x(21, 22, 31, 0x20)
    a.stp_off_x(23, 24, 31, 0x30)
    a.stp_off_x(25, 26, 31, 0x40)
    a.stp_off_x(27, 28, 31, 0x50)

    # X19 = this, X20 = char_off, X21 = skin_off.
    a.mov_xreg(19, 0)
    a.mov_xreg(20, 1)
    a.mov_xreg(21, 2)

    # ---- W22 = [[NSUserDefaults standardUserDefaults] integerForKey:KEY]
    a.adrp_ldr_x(0, NSUD_CLASSREF_NSUD)
    a.adrp_ldr_x(1, NSUD_SELREF_STD_UD)
    a.bl(NSUD_OBJC_MSGSEND_STUB)
    a.mov_xreg(23, 0)
    a.adrp_ldr_x(0, NSUD_CLASSREF_NSSTRING)
    a.adrp_ldr_x(1, NSUD_SELREF_STR_UTF8)
    a.adrp_add(2, key_va)
    a.bl(NSUD_OBJC_MSGSEND_STUB)
    a.mov_xreg(24, 0)
    a.mov_xreg(0, 23)
    a.adrp_ldr_x(1, NSUD_SELREF_GET_INT_KEY)
    a.mov_xreg(2, 24)
    a.bl(NSUD_OBJC_MSGSEND_STUB)
    a.mov_wreg(22, 0)
    a.cbz_to(22, "epilogue", sf=0)            # X == 0 → nothing to do

    # W28 = char_target; start as 0 so a missing skin list short-circuits the
    # char-list pass.
    a.movz_w(28, 0)

    # ====== SKIN LIST ======
    a.add_xreg(0, 19, 21)
    a.ldr_x_imm_dyn(25, 0, 0)                 # X25 = skin RepField*
    a.cbz_to(25, "skin_done")
    a.ldr_x_imm_dyn(26, 25, OFF_RF_ARRAY)
    a.ldr_w(27, 25, OFF_RF_COUNT)
    a.cbz_to(27, "skin_done", sf=0)
    a.cbz_to(26, "skin_done")

    # initialise loop state: tgt_idx=-1, cur_idx=-1, i=0
    a.movn_w(9, 0)                            # W9 = 0xFFFFFFFF (-1)
    a.movn_w(10, 0)
    a.movz_w(11, 0)
    a.add_x(8, 26, OFF_ARRAY_DATA)            # X8 = &arr[0]

    a.label("skin_loop")
    a.ldr_x_imm_dyn(13, 8, 0)                 # X13 = elem ptr
    a.cbz_to(13, "skin_next")
    a.ldr_w(14, 13, OFF_SKIN_MST_SKIN_ID)
    a.cmp_w_reg(14, 22)
    a.b_cond_to("skin_check_cur", "NE")
    a.mov_wreg(9, 11)                         # tgt_idx = i
    a.mov_xreg(12, 13)                        # tgt_elem
    a.label("skin_check_cur")
    a.ldrb_w(15, 13, OFF_SKIN_IS_SELECTED)
    a.cmp_w(15, 1)
    a.b_cond_to("skin_next", "NE")
    a.mov_wreg(10, 11)                        # cur_idx = i
    a.mov_xreg(16, 13)                        # cur_elem
    a.label("skin_next")
    a.add_x(8, 8, 8)
    a.add_w(11, 11, 1)
    a.cmp_w_reg(11, 27)
    a.b_cond_to("skin_loop", "LT")

    # ---- skin post-loop.
    # if tgt_idx >= 0: flag-move + record char_target = tgt_elem.mstCharId
    a.add_w(14, 9, 1)
    a.cbz_to(14, "skin_no_target", sf=0)      # W9 == -1 → no target

    # tgt_elem.isAcquired = 1
    a.movz_w(14, 1)
    a.strb_w(14, 12, OFF_SKIN_IS_ACQUIRED)
    # if cur_idx != tgt_idx: clear cur, set tgt
    a.cmp_w_reg(10, 9)
    a.b_cond_to("skin_record_char_tgt", "EQ")
    # if cur_idx != -1: cur_elem.isSelected = 0
    a.add_w(14, 10, 1)
    a.cbz_to(14, "skin_set_tgt", sf=0)
    a.strb_w(31, 16, OFF_SKIN_IS_SELECTED)    # STRB WZR -> 0
    a.label("skin_set_tgt")
    a.movz_w(14, 1)
    a.strb_w(14, 12, OFF_SKIN_IS_SELECTED)
    a.label("skin_record_char_tgt")
    a.ldr_w(28, 12, OFF_SKIN_MST_CHAR_ID)     # W28 = tgt.mstCharacterId
    a.b_to("skin_done")

    # ---- target not found: try id-rewrite on the cur entry.
    a.label("skin_no_target")
    a.add_w(14, 10, 1)
    a.cbz_to(14, "skin_done", sf=0)           # no cur either → leave list alone
    a.str_w(22, 16, OFF_SKIN_MST_SKIN_ID)     # cur.mstSkinId = X
    a.movz_w(14, 1)
    a.strb_w(14, 16, OFF_SKIN_IS_ACQUIRED)
    a.ldr_w(28, 16, OFF_SKIN_MST_CHAR_ID)     # W28 = cur.mstCharId (server's char)

    a.label("skin_done")

    # ====== CHAR LIST ======
    a.cbz_to(28, "epilogue", sf=0)            # char_target unknown → skip
    a.add_xreg(0, 19, 20)
    a.ldr_x_imm_dyn(25, 0, 0)
    a.cbz_to(25, "epilogue")
    a.ldr_x_imm_dyn(26, 25, OFF_RF_ARRAY)
    a.ldr_w(27, 25, OFF_RF_COUNT)
    a.cbz_to(27, "epilogue", sf=0)
    a.cbz_to(26, "epilogue")

    a.movn_w(9, 0)
    a.movn_w(10, 0)
    a.movz_w(11, 0)
    a.add_x(8, 26, OFF_ARRAY_DATA)

    a.label("char_loop")
    a.ldr_x_imm_dyn(13, 8, 0)
    a.cbz_to(13, "char_next")
    a.ldr_w(14, 13, OFF_CHAR_MST_ID)
    a.cmp_w_reg(14, 28)
    a.b_cond_to("char_check_cur", "NE")
    a.mov_wreg(9, 11)
    a.mov_xreg(12, 13)
    a.label("char_check_cur")
    a.ldrb_w(15, 13, OFF_CHAR_IS_SELECTED)
    a.cmp_w(15, 1)
    a.b_cond_to("char_next", "NE")
    a.mov_wreg(10, 11)
    a.mov_xreg(16, 13)
    a.label("char_next")
    a.add_x(8, 8, 8)
    a.add_w(11, 11, 1)
    a.cmp_w_reg(11, 27)
    a.b_cond_to("char_loop", "LT")

    a.add_w(14, 9, 1)
    a.cbz_to(14, "char_no_target", sf=0)

    a.movz_w(14, 1)
    a.strb_w(14, 12, OFF_CHAR_IS_ACQUIRED)
    a.cmp_w_reg(10, 9)
    a.b_cond_to("epilogue", "EQ")             # tgt already selected → done
    a.add_w(14, 10, 1)
    a.cbz_to(14, "char_set_tgt", sf=0)
    a.strb_w(31, 16, OFF_CHAR_IS_SELECTED)
    a.label("char_set_tgt")
    a.movz_w(14, 1)
    a.strb_w(14, 12, OFF_CHAR_IS_SELECTED)
    a.b_to("epilogue")

    a.label("char_no_target")
    a.add_w(14, 10, 1)
    a.cbz_to(14, "epilogue", sf=0)
    a.str_w(28, 16, OFF_CHAR_MST_ID)          # cur.mstCharId = char_target
    a.movz_w(14, 1)
    a.strb_w(14, 16, OFF_CHAR_IS_ACQUIRED)

    # ---- epilogue.
    a.label("epilogue")
    a.ldp_off_x(27, 28, 31, 0x50)
    a.ldp_off_x(25, 26, 31, 0x40)
    a.ldp_off_x(23, 24, 31, 0x30)
    a.ldp_off_x(21, 22, 31, 0x20)
    a.ldp_off_x(19, 20, 31, 0x10)
    a.ldp_post_x(29, 30, 31, 0x60)
    a.emit(ret_insn())

    # ---- cstring.
    cur = a.va
    if cur != key_va:
        raise AssertionError(
            f"_apply_lists_fixup_payload: cstring VA drift "
            f"(emitted up to 0x{cur:X}, expected 0x{key_va:X}). "
            f"Adjust _APPLY_PAYLOAD_INSN_COUNT to {(cur - cave_va) // 4}."
        )
    a.emit_data(NSUD_KEY_SKIN_CSTR)

    return a.finalize()


_APPLY_PAYLOAD_INSN_COUNT = 129  # tune via AssertionError


def _apply_skin_key_va(cave_va: int) -> int:
    return cave_va + _APPLY_PAYLOAD_INSN_COUNT * 4


# Convenience: the helper's entry VA is identical to its cave allocation start
# since the trampolines BL to address 0 of the payload.
_apply_lists_fixup_entry_va = None  # set at processing time


# Helper for the CaveAssembler — add a missing 64-bit LDR (we have a strict
# 8B aligned version, but we also need to load `*(X0)` with off=0 which is
# allowed by that encoder. So make a thin alias.)
def _ldr_x_imm_dyn_method(self, rt: int, rn: int, off: int) -> None:
    self.emit(ldr_x_imm(rt, rn, off))
CaveAssembler.ldr_x_imm_dyn = _ldr_x_imm_dyn_method


# ---------------------------------------------------------------------------
# Reply-specific trampolines.
# Each replaces ONE instruction at the function's natural epilogue start with
# `B <trampoline>`. The trampoline:
#   1. sets X0/X1/X2 from X20 (= this), char_off, skin_off
#   2. BL the shared helper
#   3. replays the original LDP × 6 epilogue instructions
#   4. RET
# ---------------------------------------------------------------------------

def _make_reply_trampoline(redirect_site: int, char_off: int, skin_off: int,
                           apply_entry_va_getter):
    """Returns a build_payload(cave_va) closure for this reply."""
    def build(cave_va: int) -> bytes:
        a = CaveAssembler(cave_va)
        # Call apply_lists_fixup(this=X20, char_off, skin_off).
        a.mov_xreg(0, 20)
        a.movz_w(1, char_off)                # W1 = char_off (max 0xFFF — OK for our offsets)
        a.movz_w(2, skin_off)
        a.bl(apply_entry_va_getter())
        # Replay the 6 LDP + RET epilogue (the redirect overran 1 insn, but the
        # ORIGINAL function's RET still lives at site+0x18; we instead execute
        # the whole epilogue locally and RET from here).
        # Epilogue insns from the redirect site onward:
        #   LDP X29,X30,[SP,#0x50]
        #   LDP X20,X19,[SP,#0x40]
        #   LDP X22,X21,[SP,#0x30]
        #   LDP X24,X23,[SP,#0x20]
        #   LDP X26,X25,[SP,#0x10]
        #   LDP X28,X27,[SP],#0x60
        #   RET
        a.ldp_off_x(29, 30, 31, 0x50)
        a.ldp_off_x(20, 19, 31, 0x40)
        a.ldp_off_x(22, 21, 31, 0x30)
        a.ldp_off_x(24, 23, 31, 0x20)
        a.ldp_off_x(26, 25, 31, 0x10)
        a.ldp_post_x(28, 27, 31, 0x60)
        a.emit(ret_insn())
        return a.finalize()
    return build


# These getters return the helper's entry VA. Populated when the helper is
# allocated; trampolines are emitted later in the same patch run.
_apply_helper_va_box = {"va": None}


def _apply_helper_entry_va():
    v = _apply_helper_va_box["va"]
    if v is None:
        raise RuntimeError("apply_lists_fixup helper not yet allocated")
    return v


# ---------------------------------------------------------------------------
# Match-screen avatar cave.
#
# Hooks ShogiMatchingPlayerStatus.InternalMergeFrom @ 0x5B4CAEC. The match
# server sends this DTO once per player when a match starts; it drives the
# avatar shown in the in-game scene. Without intervention the wire value is
# always KIOU_SAFE_SKIN_ID (=1) because that's what we send in
# SelectCharacter, so the user's selected skin is invisible during matches.
#
# Logic ported 1:1 from Sources/KiouEditor/Hook_MatchingPlayer.m:
#
#   - userId   = il2cpp string at this+0x18 → NSString (via
#                stringWithCharacters:length:)
#   - if userId empty or "cpu":         return (CPU opponent / placeholder)
#   - X        = ud["kiou_editor.persisted_skin_id"]
#   - if X == 0:                        return  (override not active)
#   - locked   = ud.stringForKey("kiou_editor.self_user_id")
#   - if locked: if userId != locked:   return  (this is opponent, leave alone)
#   - else (heuristic - first match after install):
#         curSkin = this->mstCharacterSkinId @+0x40
#         if curSkin != KIOU_SAFE_SKIN_ID: return  (not us)
#         ud.setObject(userId, forKey: "kiou_editor.self_user_id")
#   - this->mstCharacterSkinId = X
#   - this->mstCharacterId    = X        (Tweak's 1:1 mapping; works for KIOU's
#                                          current single-skin-per-character
#                                          layout, both ids stay equal)
#
# Redirect site: 0x5B4D108 (LDP X29,X30,[SP,#0x50] — first epilogue insn,
# same shape as the reply MergeFroms we already trampoline). The trampoline
# replays the 6 LDPs + RET locally.
# ---------------------------------------------------------------------------

OFF_MP_USER_ID         = 0x18
OFF_MP_MST_CHAR_ID     = 0x38
OFF_MP_MST_SKIN_ID     = 0x40

# il2cpp System.String layout (Mono-style, Unity il2cpp): header @0, header+0x10
# is the i32 length, header+0x14 starts the UTF-16 char array.
OFF_IL2CPP_STR_LENGTH  = 0x10
OFF_IL2CPP_STR_CHARS   = 0x14


def _player_avatar_payload(cave_va: int) -> bytes:
    """Build the match-screen player-avatar rewrite helper.

    Calling convention (called by `_player_avatar_trampoline`):
        X0 = this (ShogiMatchingPlayerStatus*)
        Clobbers X0..X18. Preserves X19..X28. Returns via RET.
    """
    a = CaveAssembler(cave_va)
    # Anchor cstring slots at the tail of the payload — VAs known up-front.
    skin_key_va = _player_skin_key_va(cave_va)
    selfid_key_va = _player_selfid_key_va(cave_va)
    cpu_userid_va = _player_cpu_userid_va(cave_va)

    # ---- prologue: 0x40 frame for FP/LR + 3 callee pairs (X19..X24).
    a.stp_pre_x(29, 30, 31, -0x40)
    a.stp_off_x(19, 20, 31, 0x10)
    a.stp_off_x(21, 22, 31, 0x20)
    a.stp_off_x(23, 24, 31, 0x30)

    # X19 = this.
    a.mov_xreg(19, 0)

    # ---- read il2cpp userId string → NSString in X20.
    # userIdPtr (X1) = [this + 0x18]
    a.ldr_x_imm_dyn(1, 19, OFF_MP_USER_ID)
    a.cbz_to(1, "epilogue")
    # len = [str + 0x10] (i32). If 0, skip.
    a.ldr_w(2, 1, OFF_IL2CPP_STR_LENGTH)
    a.cbz_to(2, "epilogue", sf=0)

    # X3 = &str+0x14 (UTF-16 chars). Stash chars ptr + length to scratch regs.
    a.add_x(21, 1, OFF_IL2CPP_STR_CHARS)      # X21 = chars ptr (callee-saved)
    a.mov_wreg(22, 2)                         # W22 = length (callee-saved)

    # X0 = [NSString stringWithCharacters:X21 length:W22]
    a.adrp_ldr_x(0, NSUD_CLASSREF_NSSTRING)
    a.adrp_ldr_x(1, NSUD_SELREF_STR_CHARS_LEN)
    a.mov_xreg(2, 21)
    # NSString length takes NSUInteger (X3), pass zero-extended.
    a.mov_xreg(3, 22)                          # NOTE: W22 already in low 32 of X22; MOV X3,X22 zero-extends
    a.bl(NSUD_OBJC_MSGSEND_STUB)
    a.mov_xreg(20, 0)                          # X20 = NSString *userId
    a.cbz_to(20, "epilogue")

    # ---- if userId == "cpu": skip.
    a.adrp_ldr_x(0, NSUD_CLASSREF_NSSTRING)
    a.adrp_ldr_x(1, NSUD_SELREF_STR_UTF8)
    a.adrp_add(2, cpu_userid_va)
    a.bl(NSUD_OBJC_MSGSEND_STUB)
    a.mov_xreg(2, 0)                           # X2 = NSString "cpu"
    a.mov_xreg(0, 20)
    a.adrp_ldr_x(1, NSUD_SELREF_IS_EQUAL_STR)
    a.bl(NSUD_OBJC_MSGSEND_STUB)
    a.cbnz_to(0, "epilogue", sf=0)             # equal → skip

    # ---- ud = standardUserDefaults, X23 = ud.
    a.adrp_ldr_x(0, NSUD_CLASSREF_NSUD)
    a.adrp_ldr_x(1, NSUD_SELREF_STD_UD)
    a.bl(NSUD_OBJC_MSGSEND_STUB)
    a.mov_xreg(23, 0)

    # ---- X = [ud integerForKey:skinKey]
    # skin key NSString
    a.adrp_ldr_x(0, NSUD_CLASSREF_NSSTRING)
    a.adrp_ldr_x(1, NSUD_SELREF_STR_UTF8)
    a.adrp_add(2, skin_key_va)
    a.bl(NSUD_OBJC_MSGSEND_STUB)
    a.mov_xreg(2, 0)
    a.mov_xreg(0, 23)
    a.adrp_ldr_x(1, NSUD_SELREF_GET_INT_KEY)
    a.bl(NSUD_OBJC_MSGSEND_STUB)
    a.mov_wreg(24, 0)                          # W24 = X
    a.cbz_to(24, "epilogue", sf=0)

    # ---- locked = [ud stringForKey:selfIdKey]
    a.adrp_ldr_x(0, NSUD_CLASSREF_NSSTRING)
    a.adrp_ldr_x(1, NSUD_SELREF_STR_UTF8)
    a.adrp_add(2, selfid_key_va)
    a.bl(NSUD_OBJC_MSGSEND_STUB)
    a.mov_xreg(2, 0)                           # X2 = selfid key NSString
    a.mov_xreg(0, 23)
    a.adrp_ldr_x(1, NSUD_SELREF_STRING_FOR_KEY)
    a.bl(NSUD_OBJC_MSGSEND_STUB)               # X0 = locked or nil

    # if locked: compare userId vs locked
    a.cbz_to(0, "heuristic")
    a.mov_xreg(2, 0)                           # X2 = locked
    a.mov_xreg(0, 20)
    a.adrp_ldr_x(1, NSUD_SELREF_IS_EQUAL_STR)
    a.bl(NSUD_OBJC_MSGSEND_STUB)
    a.cbz_to(0, "epilogue", sf=0)              # not self → done
    a.b_to("rewrite")

    # ---- heuristic: curSkin == 1 ?
    a.label("heuristic")
    a.ldr_w(0, 19, OFF_MP_MST_SKIN_ID)
    a.cmp_w(0, KIOU_SAFE_SKIN_ID)
    a.b_cond_to("epilogue", "NE")
    # Lock userId in: [ud setObject:userId forKey:selfIdKey]
    a.adrp_ldr_x(0, NSUD_CLASSREF_NSSTRING)
    a.adrp_ldr_x(1, NSUD_SELREF_STR_UTF8)
    a.adrp_add(2, selfid_key_va)
    a.bl(NSUD_OBJC_MSGSEND_STUB)
    a.mov_xreg(3, 0)                           # X3 = selfid key NSString (forKey arg)
    a.mov_xreg(0, 23)                          # receiver = ud
    a.adrp_ldr_x(1, NSUD_SELREF_SET_OBJ_KEY)
    a.mov_xreg(2, 20)                          # X2 = userId (value)
    a.bl(NSUD_OBJC_MSGSEND_STUB)

    # ---- rewrite: this.mstCharacterSkinId = X, this.mstCharacterId = X
    a.label("rewrite")
    a.str_w(24, 19, OFF_MP_MST_SKIN_ID)
    a.str_w(24, 19, OFF_MP_MST_CHAR_ID)

    # ---- epilogue
    a.label("epilogue")
    a.ldp_off_x(23, 24, 31, 0x30)
    a.ldp_off_x(21, 22, 31, 0x20)
    a.ldp_off_x(19, 20, 31, 0x10)
    a.ldp_post_x(29, 30, 31, 0x40)
    a.emit(ret_insn())

    # ---- tail: three cstrings.
    cur = a.va
    if cur != skin_key_va:
        raise AssertionError(
            f"_player_avatar_payload: skin_key drift "
            f"(emitted up to 0x{cur:X}, expected 0x{skin_key_va:X}). "
            f"Adjust _PLAYER_PAYLOAD_INSN_COUNT to {(cur - cave_va) // 4}."
        )
    a.emit_data(NSUD_KEY_SKIN_CSTR)
    if a.va != selfid_key_va:
        raise AssertionError(
            f"_player_avatar_payload: selfid_key drift "
            f"({a.va:X} != {selfid_key_va:X})"
        )
    a.emit_data(NSUD_KEY_SELFID_CSTR)
    if a.va != cpu_userid_va:
        raise AssertionError(
            f"_player_avatar_payload: cpu_userid drift "
            f"({a.va:X} != {cpu_userid_va:X})"
        )
    a.emit_data(NSUD_CPU_USERID_CSTR)

    return a.finalize()


_PLAYER_PAYLOAD_INSN_COUNT = 96  # tune on first AssertionError


def _player_skin_key_va(cave_va: int) -> int:
    return cave_va + _PLAYER_PAYLOAD_INSN_COUNT * 4


def _player_selfid_key_va(cave_va: int) -> int:
    base = _player_skin_key_va(cave_va) + len(NSUD_KEY_SKIN_CSTR)
    return (base + 3) & ~3


def _player_cpu_userid_va(cave_va: int) -> int:
    base = _player_selfid_key_va(cave_va) + len(NSUD_KEY_SELFID_CSTR)
    return (base + 3) & ~3


# Entry VA box for the player cave (set when CAVE_PATCHES entry is processed,
# so the trampoline can BL it). Mirrors the apply-helper pattern.
_player_helper_va_box = {"va": None}


def _player_helper_entry_va():
    v = _player_helper_va_box["va"]
    if v is None:
        raise RuntimeError("player avatar helper not yet allocated")
    return v


def _player_avatar_trampoline(redirect_site: int):
    """Closure builder for the player-cave trampoline. Same shape as the
    reply trampolines: set X0=this (= X20), BL helper, replay 6 LDPs + RET."""
    def build(cave_va: int) -> bytes:
        a = CaveAssembler(cave_va)
        a.mov_xreg(0, 20)
        a.bl(_player_helper_entry_va())
        a.ldp_off_x(29, 30, 31, 0x50)
        a.ldp_off_x(20, 19, 31, 0x40)
        a.ldp_off_x(22, 21, 31, 0x30)
        a.ldp_off_x(24, 23, 31, 0x20)
        a.ldp_off_x(26, 25, 31, 0x10)
        a.ldp_post_x(28, 27, 31, 0x60)
        a.emit(ret_insn())
        return a.finalize()
    return build


CAVE_PATCHES = [
    # Order matters: cave allocator is sequential. The helper MUST be emitted
    # before the trampolines so its entry VA is known when they're built.
    (
        0x5C25FEC,
        bytes.fromhex("811a40b9"),   # LDR W1, [X20, #0x18]
        _save_skin_id_payload,
        "SelectCharacterArgs.InternalWriteTo: persist user X, emit SAFE_ID on the wire",
    ),
    # Helper cave: not redirected from any site (site_off=None handled below).
    # We re-use the (site, expected, build, label) shape with site_off=None as
    # the marker for "helper-only" entries — patch_unity.py main loop checks.
    (
        None,
        None,
        _apply_lists_fixup_payload,
        "<helper> apply_lists_fixup: shared post-decode lists fixup",
    ),
    (
        0x5C26F68,
        bytes.fromhex("fd7b45a9"),   # LDP X29,X30,[SP,#0x50] — first insn of epilogue (little-endian)
        _make_reply_trampoline(0x5C26F68, char_off=0x18, skin_off=0x20,
                               apply_entry_va_getter=_apply_helper_entry_va),
        "SelectCharacterReply.InternalMergeFrom: post-decode lists fixup",
    ),
    (
        0x5C372E8,
        bytes.fromhex("fd7b45a9"),   # LDP X29,X30,[SP,#0x50] — first insn of epilogue (little-endian)
        _make_reply_trampoline(0x5C372E8, char_off=0x28, skin_off=0x30,
                               apply_entry_va_getter=_apply_helper_entry_va),
        "SyncItemListReply.InternalMergeFrom: post-decode lists fixup",
    ),
    # Player-avatar helper (helper-only, BL'd by the matching-player trampoline).
    (
        None,
        None,
        _player_avatar_payload,
        "<helper> player avatar: rewrite self mstCharacterSkinId/Id on match",
    ),
    # Matching-player trampoline: epilogue redirect site is identical in shape
    # to the reply MergeFroms (LDP X29,X30,[SP,#0x50] starting the 6-LDP unwind).
    (
        0x5B4D108,
        bytes.fromhex("fd7b45a9"),
        _player_avatar_trampoline(0x5B4D108),
        "ShogiMatchingPlayerStatus.InternalMergeFrom: self avatar fixup",
    ),
]


def _guess_app_info_plist(target: str) -> str | None:
    """If `target` is a UnityFramework Mach-O inside a KIOU.app bundle, return the
    path to the bundle's Info.plist. Returns None if the layout doesn't match."""
    p = os.path.realpath(target)
    # Walk up looking for a *.app directory.
    cur = os.path.dirname(p)
    for _ in range(6):
        if cur.endswith(".app") and os.path.isdir(cur):
            candidate = os.path.join(cur, "Info.plist")
            if os.path.isfile(candidate):
                return candidate
            return None
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="UnityFramework inline patcher")
    parser.add_argument("target", help="Path to UnityFramework Mach-O")
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="Read each offset and report match/mismatch without writing.",
    )
    parser.add_argument(
        "--stamp-plist",
        metavar="PATH",
        default="auto",
        help="Path to the KIOU.app Info.plist to version-stamp after patching. "
             "Default 'auto' walks up from <target> to find KIOU.app/Info.plist. "
             "Pass 'none' to skip stamping.",
    )
    args = parser.parse_args()

    if not os.path.isfile(args.target):
        print(f"error: not a file: {args.target}", file=sys.stderr)
        return 2

    mode = "rb" if args.verify_only else "r+b"
    with open(args.target, mode) as f:
        failures = 0
        for off, expected, new, label in PATCHES:
            if len(new) != len(expected):
                raise AssertionError(
                    f"patch length mismatch for {label}: "
                    f"expected={len(expected)} new={len(new)}"
                )
            f.seek(off)
            cur = f.read(len(expected))
            tag = f"[{off:#x}] {label}"
            if cur == new:
                print(f"  SKIP  {tag} (already patched)")
                continue
            if cur != expected:
                failures += 1
                print(
                    f"  FAIL  {tag}\n"
                    f"        expected {expected.hex()}\n"
                    f"        got      {cur.hex()}"
                )
                continue
            if args.verify_only:
                print(f"  OK    {tag} (orig matches; would patch)")
            else:
                f.seek(off)
                f.write(new)
                print(f"  PATCH {tag}")

        # -------------------------------------------------------------------
        # Cave-based patches: redirect a single site instruction to a payload
        # we lay out in __TEXT,__oslogstring's tail zero-fill.
        # -------------------------------------------------------------------
        cave_cursor = CODE_CAVE_START
        for site_off, expected, build_payload, label in CAVE_PATCHES:
            # "Helper-only" entries: site_off=None means the cave is a
            # subroutine that other caves BL into. We allocate it in the cave
            # but don't redirect any site instruction.
            helper_only = site_off is None
            if not helper_only and len(expected) != 4:
                raise AssertionError(
                    f"cave-patch site must be one 4B insn: {label}"
                )

            # Helper-only entries publish their entry VA before computing the
            # payload — trampolines that come later in this list close over
            # this box and read it when their build_payload runs.
            # Helpers are identified by the callable object itself so we can
            # route to the right box without parsing labels.
            if helper_only:
                if build_payload is _apply_lists_fixup_payload:
                    _apply_helper_va_box["va"] = cave_cursor
                elif build_payload is _player_avatar_payload:
                    _player_helper_va_box["va"] = cave_cursor
                else:
                    raise AssertionError(
                        f"helper-only cave entry has no known VA box: {label}"
                    )

            # Compute the payload at its allocated cave VA. Allocation order
            # is the list order, so the same input -> same cave VAs every run.
            payload = build_payload(cave_cursor)
            if len(payload) % 4 != 0:
                raise AssertionError(
                    f"cave payload not 4B-aligned for {label}: len={len(payload)}"
                )
            if cave_cursor + len(payload) > CODE_CAVE_END:
                print(
                    f"  FAIL  cave overflow for {label}: "
                    f"need 0x{len(payload):X} B at 0x{cave_cursor:X}, "
                    f"only 0x{CODE_CAVE_END - cave_cursor:X} B remain",
                    file=sys.stderr,
                )
                failures += 1
                continue

            if helper_only:
                tag = f"[helper @ 0x{cave_cursor:X}] {label}  ({len(payload)} B)"
                # No site to verify; just check whether the cave area already
                # holds this exact payload (idempotency) or is virgin.
                f.seek(cave_cursor)
                cur_cave = f.read(len(payload))
                if cur_cave == payload:
                    print(f"  SKIP  {tag} (already present)")
                    cave_cursor += len(payload)
                    continue
                if cur_cave != b"\x00" * len(payload):
                    failures += 1
                    print(
                        f"  FAIL  {tag}\n"
                        f"        cave was not zero-fill nor the matching payload "
                        f"(first 16 B: {cur_cave[:16].hex()})"
                    )
                    continue
                if args.verify_only:
                    print(f"  OK    {tag} (cave is zero-fill; would emit)")
                else:
                    f.seek(cave_cursor)
                    f.write(payload)
                    print(f"  PATCH {tag}")
                cave_cursor += len(payload)
                continue

            site_patch = b_imm(site_off, cave_cursor)
            tag = f"[{site_off:#x}] {label}  (cave @ 0x{cave_cursor:X}, {len(payload)} B)"

            # Read current site + current cave contents and classify.
            f.seek(site_off)
            cur_site = f.read(4)
            f.seek(cave_cursor)
            cur_cave = f.read(len(payload))

            already = (cur_site == site_patch and cur_cave == payload)
            virgin = (cur_site == expected and cur_cave == b"\x00" * len(payload))

            if already:
                print(f"  SKIP  {tag} (already patched)")
                cave_cursor += len(payload)
                continue
            if not virgin:
                failures += 1
                detail = []
                if cur_site != expected and cur_site != site_patch:
                    detail.append(
                        f"site expected {expected.hex()} or {site_patch.hex()}, "
                        f"got {cur_site.hex()}"
                    )
                if cur_cave != b"\x00" * len(payload) and cur_cave != payload:
                    detail.append(
                        f"cave was not zero-fill nor the matching payload "
                        f"(first 16 B: {cur_cave[:16].hex()})"
                    )
                print(f"  FAIL  {tag}\n        " + "\n        ".join(detail))
                continue

            if args.verify_only:
                print(f"  OK    {tag} (orig matches; would patch)")
            else:
                # Write cave payload first, then redirect the site. This
                # avoids any window where the site jumps into uninitialized
                # cave bytes if the process were interrupted mid-write.
                f.seek(cave_cursor)
                f.write(payload)
                f.seek(site_off)
                f.write(site_patch)
                print(f"  PATCH {tag}")
            cave_cursor += len(payload)

        if failures:
            print(f"\n{failures} mismatch(es) — aborting.", file=sys.stderr)
            return 1

    # ------------------------------------------------------------------
    # Version-stamp the bundle's Info.plist so a patched install is
    # visually distinguishable from a stock one. Tag-from is wired to
    # *this* script so the stamp flips whenever the patch logic changes.
    # ------------------------------------------------------------------
    if args.stamp_plist == "none":
        pass
    else:
        if args.stamp_plist == "auto":
            plist_path = _guess_app_info_plist(args.target)
            if not plist_path:
                print(
                    "  WARN  --stamp-plist=auto: could not locate KIOU.app/Info.plist "
                    f"from target={args.target}; skipping stamp",
                    file=sys.stderr,
                )
                plist_path = None
        else:
            plist_path = args.stamp_plist
            if not os.path.isfile(plist_path):
                print(f"  FAIL  --stamp-plist={plist_path}: not a file", file=sys.stderr)
                return 1

        if plist_path:
            # Re-exec stamp_version.py in-process. It's a sibling script;
            # importing it would also work but a subprocess keeps argument
            # parsing isolated and the script self-contained.
            import subprocess
            stamp_script = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        "stamp_version.py")
            cmd = [sys.executable, stamp_script, plist_path,
                   "--tag-from", os.path.abspath(__file__)]
            if args.verify_only:
                cmd.append("--verify-only")
            sys.stdout.flush()
            sys.stderr.flush()
            rc = subprocess.call(cmd, stdout=sys.stdout, stderr=sys.stderr)
            if rc != 0:
                print(f"  FAIL  stamp_version.py exited {rc}", file=sys.stderr)
                return rc

    print("\nAll patches applied." if not args.verify_only else "\nVerify pass complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
