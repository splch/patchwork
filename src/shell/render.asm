; Phase 3 shell rendering: dirty-list repaint, the live event board, the
; history-strip framebuffer, look-back page renders, and HUD text.
;
; Main-context code only. The kernel coroutine may be suspended mid-
; measurement at any point in here, so NOTHING in this file may touch kernel
; HRAM scratch (hTmp*, hQa, hRow, hIter*, hK, hP, hCoin, RNG state) or the
; kernel WRAM row buffers. Registers + shell WRAM only; the only kernel
; helpers called are pure LUT reads (BitmaskA).
;
; All VRAM traffic goes through the VBlank ISR: single tiles via the dirty
; ring (DirtyPush), bulk content via one job per frame (strip tile column or
; a region copy). Lattice cells are shadow-backed (SH_LATSH), so a full dirty
; ring degrades to a queued full blit instead of dropping content.

INCLUDE "hardware.inc"
INCLUDE "shell/shell.inc"

DEF PEND_LOOK EQU 1
DEF PEND_BLIT EQU 2
DEF PEND_CAT EQU 4
EXPORT PEND_LOOK, PEND_BLIT, PEND_CAT

SECTION "Shell render", ROM0

; --- dirty ring / lattice paints --------------------------------------------

; Push one VRAM write: DE = address, C = tile. Ring full -> queue a full
; lattice blit instead (lattice cells are shadow-backed; HUD pushes are
; ordered first in the frame so they never hit a full ring in practice).
; Clobbers AF, B, HL.
DirtyPush::
	ld a, [wDirtyHead]
	inc a
	and DIRTY_CAP - 1
	ld b, a                     ; b = next head
	ld a, [wDirtyTail]
	cp b
	jr z, .full
	ld a, [wDirtyHead]
	ld l, a
	add a
	add l                       ; head * 3
	add LOW(SH_DIRTY)
	ld l, a
	ld h, HIGH(SH_DIRTY)
	ld a, e
	ld [hli], a
	ld a, d
	ld [hli], a
	ld [hl], c
	ld a, b                     ; publish after the entry is complete
	ld [wDirtyHead], a
	ret
.full
	ld a, [wPend]
	or PEND_BLIT
	ld [wPend], a
	ret

; Paint lattice cell B with tile C: shadow write + dirty push. Clobbers all.
LatPaint::
	ld h, HIGH(SH_LATSH)
	ld l, b
	ld [hl], c
	ld a, [wPCellAddr]
	ld l, a
	ld a, [wPCellAddr + 1]
	ld h, a
	ld a, b
	add a                       ; cell * 2 (<= 242)
	jr nc, :+
	inc h
:
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hli]
	ld e, a
	ld a, [hl]
	ld d, a
	jr DirtyPush

; Restore lattice cell B to its LatBase tile. Clobbers all.
LatRestore::
	ld a, [wPLatBase]
	ld l, a
	ld a, [wPLatBase + 1]
	ld h, a
	ld a, b
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld c, [hl]
	jr LatPaint

; Repaint check A from the live board (quiet/lit by SH_LIVE bit). Clobbers all.
RepaintCheck::
	ld b, a                     ; b = check index
	ld a, [wPChkCell]
	ld l, a
	ld a, [wPChkCell + 1]
	ld h, a
	ld a, b
	add a
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hli]
	ld e, a                     ; e = cell
	ld a, [hl]
	and 3
	ld d, a                     ; d = flags (kind | boundary<<1)
	ld a, b
	srl a
	srl a
	srl a
	add LOW(SH_LIVE)
	ld l, a
	ld h, HIGH(SH_LIVE)
	ld a, b
	and 7
	call BitmaskA
	and [hl]
	ld hl, ChkQuietTile
	jr z, :+
	ld hl, ChkLitTile
:
	ld a, d
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hl]
	ld c, a                     ; tile
	ld b, e                     ; cell
	jp LatPaint

; XOR wToggled into the live board (no repaints; wToggled preserved).
; Clobbers AF, B, DE, HL.
ApplyToggleMask::
	ld hl, wToggled
	ld de, SH_LIVE
	ld b, 4
.x
	ld a, [de]
	xor [hl]
	ld [de], a
	inc e
	inc l
	dec b
	jr nz, .x
	ret

; Repaint every check whose bit is set in wToggled (destroys wToggled).
; Runs AFTER the bounded HUD pushes so a full dirty ring degrades to the
; shadow-backed full blit without starving the HUD. Clobbers all + wHudTmp.
PaintToggled::
	xor a
	ld [wHudTmp], a             ; byte index
.byte
	ld a, [wHudTmp]
	cp 4                        ; 4-byte masks (Act 2/3 boards reach 30 checks)
	ret z
	add LOW(wToggled)
	ld l, a
	ld h, HIGH(wToggled)
	ld a, [hl]
.bits
	and a
	jr z, .next
	ld l, a
	ld h, HIGH(LsbLUT)
	ld a, [hl]
	ld c, a                     ; bit index
	ld b, a
	call BitmaskA               ; a = 1 << bit
	cpl
	ld b, a                     ; ~mask
	ld a, [wHudTmp]
	add LOW(wToggled)
	ld l, a
	ld h, HIGH(wToggled)
	ld a, [hl]
	and b
	ld [hl], a                  ; clear the bit from the iterator copy
	push af
	ld a, [wHudTmp]
	add a
	add a
	add a
	add c                       ; check index = byte*8 + bit
	call RepaintCheck
	pop af
	jr .bits
.next
	ld a, [wHudTmp]
	inc a
	ld [wHudTmp], a
	jr .byte

; --- round consumption --------------------------------------------------------

; Consume round wCons: detector slot -> strip column + live-board toggle +
; HUD. Precondition (TryConsume): wVbJob == 0 and wPend == 0, so the strip
; job can be queued directly and the shadow is not mid-copy. Clobbers all.
ConsumeRound::
	call GameArrival            ; game: streak/unbanked before events land
	; wToggled = ring slot (3 bytes; slot 4th byte unused)
	ld a, [wCons]
	and ERING_MASK
	add a
	add a
	add LOW(ERING)
	ld l, a
	ld h, HIGH(ERING)
	ld de, wToggled
	ld b, 4                     ; full slot (4-byte det masks since Phase 8)
.cp
	ld a, [hli]
	ld [de], a
	inc e
	dec b
	jr nz, .cp
	call StripWrite             ; uses wToggled + wCons (shadow + job only)
	call ApplyToggleMask        ; live ^= toggled (no pushes yet)
	; advance the consumer (the engine producer throttles on this)
	ld a, [wCons]
	inc a
	ld [wCons], a
	; bounded HUD pushes first so a full ring never starves them
	call HudRound
	call HudEvt
	call PaintToggled           ; unbounded; degrades to the full blit
	; newest visible strip column at x = 158
	ld a, [wCons]
	dec a
	add a
	add 98                      ; (2*round - 158) mod 256
	ldh [hStripScx], a
	ld a, [SH_FRAMES]
	ld [wLastCons], a
	ld a, 1
	ld [wDidWork], a            ; grant the light kernel refill this frame
	jp GamePostConsume          ; game: heralds/verdict/cap/clock (no-op plain)

; Write round wCons's detector bits (wToggled) into the strip shadow as one
; column, then queue the strip job. Cell height is per-config (wStripH):
; Act 1 = 2px cells (24-check cap), Act 2/3 = 1px cells (30 checks in 4
; tile rows, leaving VRAM tiles 192+ for the extra art). Clobbers all + wHudTmp.
StripWrite::
	ld a, [wCons]
	and 3
	jr nz, .havecol
	; entering a new tile column: clear the shadow, latch the column
	ld hl, SH_STRIPSH
	ld a, [wStripRows]
	swap a                      ; * 16
	ld b, a
	xor a
.z
	ld [hli], a
	dec b
	jr nz, .z
	ld a, [wCons]
	srl a
	srl a
	and 31
	ld [wStripCol], a
.havecol
	; pixel mask = %11000000 >> (2 * (round & 3))
	ld a, [wCons]
	and 3
	add a
	ld b, a
	ld a, %11000000
	inc b
	dec b
	jr z, .maskok
.sh
	srl a
	dec b
	jr nz, .sh
.maskok
	ld [wHudTmp], a             ; column mask
	; tick line every 8 rounds: plane-0 only, full height (color 1)
	ld a, [wCons]
	and 7
	jr nz, .events
	ld a, [wStripRows]
	swap a
	srl a                       ; rows * 8 = plane-0 byte count
	ld b, a
	ld hl, SH_STRIPSH
.tick
	ld a, [wHudTmp]
	or [hl]
	ld [hl], a
	inc l
	inc l                       ; skip plane 1
	dec b
	jr nz, .tick
.events
	; each set detector bit k lights its cell in this round's 2px-wide
	; column: 2px cells = tile k>>2, pixel rows (k&3)*2 and +1; 1px cells =
	; tile k>>3, pixel row k&7. Both planes (color 3).
	xor a
	ld [wHudTmp + 1], a         ; byte index
.byte
	ld a, [wHudTmp + 1]
	cp 4                        ; 4-byte masks (Act 2/3 boards reach 30 checks)
	jr z, .queue
	add LOW(wToggled)
	ld l, a
	ld h, HIGH(wToggled)
	ld a, [hl]
	ld c, a                     ; c = remaining bits of this byte
.bits
	ld a, c
	and a
	jr z, .next
	ld l, a
	ld h, HIGH(LsbLUT)
	ld a, [hl]
	ld e, a                     ; bit index within byte
	ld b, a
	call BitmaskA
	cpl
	and c
	ld c, a                     ; clear from iterator
	ld a, [wHudTmp + 1]
	add a
	add a
	add a
	add e                       ; check index k
	ld e, a
	ld a, [wStripH]
	cp 1
	jr z, .h1
	; shadow offset = (k>>2)*16 + (k&3)*4
	ld a, e
	and %11111100
	add a
	add a                       ; (k & ~3) * 4 = (k>>2)*16
	ld l, a
	ld a, e
	and 3
	add a
	add a                       ; (k&3)*4
	add l
	add LOW(SH_STRIPSH)
	ld l, a
	ld h, HIGH(SH_STRIPSH)
	ld a, [wHudTmp]             ; column mask
	ld e, a
	REPT 4                      ; row0 p0, row0 p1, row1 p0, row1 p1
	ld a, e
	or [hl]
	ld [hl], a
	inc l
	ENDR
	jr .bits
.h1
	; shadow offset = (k>>3)*16 + (k&7)*2 (one pixel row, both planes)
	ld a, e
	and %11111000
	add a                       ; (k & ~7) * 2 = (k>>3)*16
	ld l, a
	ld a, e
	and 7
	add a                       ; (k&7)*2
	add l
	add LOW(SH_STRIPSH)
	ld l, a
	ld h, HIGH(SH_STRIPSH)
	ld a, [wHudTmp]
	or [hl]
	ld [hl], a
	inc l
	ld a, [wHudTmp]
	or [hl]
	ld [hl], a
	jr .bits
.next
	ld a, [wHudTmp + 1]
	inc a
	ld [wHudTmp + 1], a
	jr .byte
.queue
	; fall through
; Queue job 1: copy the strip shadow to VRAM tile column wStripCol.
; Precondition: wVbJob == 0. Clobbers AF, B.
QueueStrip::
	ld a, LOW(SH_STRIPSH)
	ld [wVbSrc], a
	ld a, HIGH(SH_STRIPSH)
	ld [wVbSrc + 1], a
	ld a, [wStripCol]
	swap a                      ; col*16: low nibble -> high
	ld b, a
	and $F0
	ld [wVbDst], a
	ld a, b
	and $0F
	add HIGH(STRIP_VRAM)
	ld [wVbDst + 1], a
	ld a, [wStripRows]
	ld [wVbRows], a
	ld a, 1
	ld [wVbJob], a
	ret

; --- look-back ------------------------------------------------------------------

; Render the look-back page for view round A (absolute round index) and queue
; the region copy to the look columns. Precondition: wVbJob == 0. Clobbers all.
LookRender::
	ld [wHudTmp], a             ; view round
	; LOOKSHADOW = LatBase
	ld a, [wPLatBase]
	ld l, a
	ld a, [wPLatBase + 1]
	ld h, a
	ld de, SH_LOOKSH
	ld a, [wNCells]
	ld b, a
.cp
	ld a, [hli]
	ld [de], a
	inc e
	dec b
	jr nz, .cp
	; hist = EDETHIST + (v mod 60)*4
	ld a, [wHudTmp]
.mod
	cp EDETHIST_MAX
	jr c, .in
	sub EDETHIST_MAX
	jr .mod
.in
	add a
	add a
	ld l, a
	ld h, HIGH(EDETHIST)
	; light the checks that fired in that round
	ld e, 0                     ; check base (byte*8)
	ld d, 4                     ; bytes (4-byte det masks since Phase 8)
.byte
	ld a, [hli]
	ld c, a
.bits
	ld a, c
	and a
	jr z, .next
	push hl
	ld l, a
	ld h, HIGH(LsbLUT)
	ld a, [hl]
	ld b, a                     ; bit
	call BitmaskA
	cpl
	and c
	ld c, a
	ld a, e
	add b                       ; check index
	call LookLight
	pop hl
	jr .bits
.next
	ld a, e
	add 8
	ld e, a
	dec d
	jr nz, .byte
	; queue region job: LOOKSHADOW -> look columns
	ld a, LOW(SH_LOOKSH)
	ld [wVbSrc], a
	ld a, HIGH(SH_LOOKSH)
	ld [wVbSrc + 1], a
	ld a, [wLiveBase]
	add GFX_LOOK_DX
	ld [wVbDst], a
	ld a, [wLiveBase + 1]
	adc 0
	ld [wVbDst + 1], a
	ld a, [wLatW]
	ld [wVbRows], a
	ld [wVbWidth], a
	ld a, 2
	ld [wVbJob], a
	ret

; Set LOOKSHADOW[cell of check A] = its lit tile. Clobbers AF, BC, HL
; (preserves DE, and C of the caller is reloaded there).
LookLight:
	push de
	ld b, a
	ld a, [wPChkCell]
	ld l, a
	ld a, [wPChkCell + 1]
	ld h, a
	ld a, b
	add a
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hli]
	ld e, a                     ; cell
	ld a, [hl]
	and 3
	add LOW(ChkLitTile)
	ld l, a
	ld a, HIGH(ChkLitTile)
	adc 0
	ld h, a
	ld a, [hl]
	ld d, a                     ; lit tile
	ld a, e
	add LOW(SH_LOOKSH)          ; NOT `ld l, e`: the shadow is page-offset
	ld l, a
	ld h, HIGH(SH_LOOKSH)       ; ($80 + cell <= $F8: no carry)
	ld [hl], d
	pop de
	ret

; Queue the full lattice blit (SH_LATSH -> live block). Precondition:
; wVbJob == 0. Clobbers AF.
QueueFullBlit::
	ld a, LOW(SH_LATSH)
	ld [wVbSrc], a
	ld a, HIGH(SH_LATSH)
	ld [wVbSrc + 1], a
	ld a, [wLiveBase]
	ld [wVbDst], a
	ld a, [wLiveBase + 1]
	ld [wVbDst + 1], a
	ld a, [wLatW]
	ld [wVbRows], a
	ld [wVbWidth], a
	ld a, 2
	ld [wVbJob], a
	ret

; --- HUD ------------------------------------------------------------------------

DEF HUD_MODE_ADDR   EQU MAP_WIN + 0 * 32
DEF HUD_RND_ADDR    EQU MAP_WIN + 3 * 32 + 1
DEF HUD_EVT_ADDR    EQU MAP_WIN + 5 * 32 + 1
DEF HUD_SEED_ADDR   EQU MAP_WIN + 7 * 32
DEF HUD_STAT_ADDR   EQU MAP_WIN + 8 * 32
DEF HUD_LOOK_ADDR   EQU MAP_WIN + 9 * 32
EXPORT HUD_MODE_ADDR, HUD_RND_ADDR, HUD_EVT_ADDR, HUD_SEED_ADDR
EXPORT HUD_STAT_ADDR, HUD_LOOK_ADDR

; Round counter: wCons as 3 decimal digits. Clobbers all + wHudTmp.
HudRound::
	ld a, [wCons]
	call Bin2Dec3
	ld de, HUD_RND_ADDR
	jp HudTmp3

; Event counter: SH_EVT = popcount(SH_LIVE), 2 digits. Clobbers all.
HudEvt::
	ld hl, SH_LIVE
	ld e, 0
	ld b, 4
	ld d, HIGH(PopcntLUT)
.pc
	ld a, [hl]
	push hl
	ld l, a
	ld h, d
	ld a, [hl]
	add e
	ld e, a
	pop hl
	inc l
	dec b
	jr nz, .pc
	ld a, e
	ld [SH_EVT], a
	call Bin2Dec3               ; hundreds unused (<= 24)
	ld a, [wHudTmp + 1]
	ld c, a
	ld de, HUD_EVT_ADDR
	call DirtyPush
	inc de
	ld a, [wHudTmp + 2]
	ld c, a
	jp DirtyPush

; Status field: A = 0 CAL / 1 RUN / 2 END. Clobbers all.
HudStatus::
	ld c, a                     ; status
	add a
	add c                       ; * 3
	ld hl, StatusText
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld de, HUD_STAT_ADDR
	ld b, 3
.s
	ld a, [hli]
	ld c, a
	push hl
	push bc
	call DirtyPush
	pop bc
	pop hl
	inc de
	dec b
	jr nz, .s
	ret

StatusText:
	db "CAL"
	db "RUN"
	db "END"

; Look-back HUD line: A = k (0 clears the line). Clobbers all.
HudLook::
	and a
	jr nz, .show
	ld de, HUD_LOOK_ADDR
	ld b, 7
.clr
	ld c, 0
	push bc
	call DirtyPush
	pop bc
	inc de
	dec b
	jr nz, .clr
	ret
.show
	push af
	ld hl, LookText
	ld de, HUD_LOOK_ADDR
	ld b, 6
.t
	ld a, [hli]
	ld c, a
	push hl
	push bc
	call DirtyPush
	pop bc
	pop hl
	inc de
	dec b
	jr nz, .t
	pop af
	add FONT_BASE               ; digit tile
	ld c, a
	jp DirtyPush

LookText:
	db "LOOK -"

; A -> wHudTmp+0/1/2 = hundreds/tens/ones as FONT tiles. Clobbers AF, B, HL.
Bin2Dec3::
	ld b, 0
.h
	cp 100
	jr c, .hdone
	sub 100
	inc b
	jr .h
.hdone
	ld h, a
	ld a, b
	add FONT_BASE
	ld [wHudTmp], a
	ld a, h
	ld b, 0
.t
	cp 10
	jr c, .tdone
	sub 10
	inc b
	jr .t
.tdone
	ld h, a
	ld a, b
	add FONT_BASE
	ld [wHudTmp + 1], a
	ld a, h
	add FONT_BASE
	ld [wHudTmp + 2], a
	ret

; Push wHudTmp[0..2] at DE. Clobbers all.
HudTmp3:
	ld a, [wHudTmp]
	ld c, a
	push de
	call DirtyPush
	pop de
	inc de
	ld a, [wHudTmp + 1]
	ld c, a
	push de
	call DirtyPush
	pop de
	inc de
	ld a, [wHudTmp + 2]
	ld c, a
	jp DirtyPush
