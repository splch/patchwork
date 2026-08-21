; Phase 3 shell ISRs. Only the shell enables IME (testbench paths poll with
; IME off), so these vectors are shell-exclusive; the timer vector ($0050,
; timing.asm) keeps its own IE mask.
;
; VBlank owns every VRAM/OAM write in shell mode: OAM DMA, per-frame raster
; registers, the dirty-ring drain, and at most ONE bulk job per frame (strip
; tile column, or a <=6-row slice of a region copy). Bulk work is sized to
; finish inside VBlank; the dirty drain runs only on job-free frames so the
; ISR never reaches a mode-3 window.
;
; STAT = two LYC splits per frame: line 88 parks the window (WX >= 167, the
; Pan Docs-sanctioned vertical split) and resets SCX for the label row;
; line 95 loads the history strip's scroll for lines 96+ (the label row's
; last line is font padding, so the early SCX change is invisible).

INCLUDE "hardware.inc"
INCLUDE "shell/shell.inc"

SECTION "VBlank vector", ROM0[$0040]
	jp ShellVBlank

SECTION "STAT vector", ROM0[$0048]
	jp ShellStat

SECTION "Shell ISRs", ROM0

ShellVBlank:
	push af
	push bc
	push de
	push hl
	call hDmaStub               ; OAM DMA first (must finish inside VBlank)
	; raster registers for the new frame (hWx: wide Act 2/3 boards move the
	; window right - per-config since Phase 7.5)
	ldh a, [hScxLat]
	ldh [rSCX], a
	ldh a, [hWx]
	ldh [rWX], a
	ld a, LYC_PARK
	ldh [rLYC], a
	xor a
	ldh [hStatStage], a
	; frame counter
	ld hl, SH_FRAMES
	inc [hl]
	jr nz, :+
	ld hl, SH_FRAMES + 1
	inc [hl]
:
	; one bulk job per frame + a small dirty drain (4 after a job, 8 free:
	; the ring must drain even when consume-paced strip jobs run every frame)
	ld a, [wVbJob]
	and a
	jp z, .nojob
	cp 1
	jp z, .strip
	cp 3
	jp z, .pal
	; --- region copy: <= 6 rows of wVbWidth bytes, dest stride 32 ---
	ld a, [wVbSrc]
	ld l, a
	ld a, [wVbSrc + 1]
	ld h, a
	ld a, [wVbDst]
	ld e, a
	ld a, [wVbDst + 1]
	ld d, a
	ld a, [wVbRows]
	cp 6
	jr c, :+
	ld a, 6
:
	ld b, a                     ; rows this frame
	ld c, a                     ; (kept: rows done)
.rrow
	push bc
	ld a, [wVbWidth]
	ld b, a
.rbyte
	ld a, [hli]
	ld [de], a
	inc de                      ; 16-bit: a dest row may cross $xxFF
	dec b
	jr nz, .rbyte
	; dest += 32 - width
	ld a, [wVbWidth]
	cpl
	inc a                       ; -width
	add 32
	add e
	ld e, a
	jr nc, :+
	inc d
:
	pop bc
	dec b
	jr nz, .rrow
	; writeback: src advanced in HL, dest in DE, rows -= done
	ld a, l
	ld [wVbSrc], a
	ld a, h
	ld [wVbSrc + 1], a
	ld a, e
	ld [wVbDst], a
	ld a, d
	ld [wVbDst + 1], a
	ld a, [wVbRows]
	sub c
	ld [wVbRows], a
	jr nz, :+
	ld [wVbJob], a              ; a = 0: job complete
:
	ld c, 4
	jp .drain
.strip
	; --- strip tile column: wVbRows tiles of 16 B, dest stride 512 ---
	ld a, [wVbSrc]
	ld l, a
	ld a, [wVbSrc + 1]
	ld h, a
	ld a, [wVbDst]
	ld e, a
	ld a, [wVbDst + 1]
	ld d, a
	ld a, [wVbRows]
	ld b, a
.srow
	REPT 16
	ld a, [hli]
	ld [de], a
	inc de                      ; 16-bit: strip runs can end on $xxFF
	ENDR
	; dest += 512 - 16
	ld a, e
	add LOW(512 - 16)
	ld e, a
	ld a, d
	adc HIGH(512 - 16)
	ld d, a
	dec b
	jr nz, .srow
	xor a
	ld [wVbJob], a
	ld c, 4
	jr .drain
.pal
	; --- palette load (Phase 9.5 mood wash): 64 B WPAL_STAGE -> BGPD.
	; Runs at VBlank start (palette RAM is mode-3-gated); ~280 M-cycles.
	; WRAM-only source per the ISR banking rule.
	ld a, $80
	ldh [rBGPI], a
	ld hl, WPAL_STAGE
	ld b, 64
	ld c, LOW(rBGPD)
.ploop
	ld a, [hli]
	ldh [c], a
	dec b
	jr nz, .ploop
	xor a
	ld [wVbJob], a
	ld c, 4
	jp .drain
.nojob
	ld c, 8
.drain
	; --- dirty ring: up to C entries of (addr lo, hi, tile) ---
	ld a, [wDirtyTail]
	ld b, a
.dloop
	ld a, [wDirtyHead]
	cp b
	jr z, .dend
	ld a, b
	add a
	add b                       ; tail * 3
	add LOW(SH_DIRTY)
	ld l, a
	ld h, HIGH(SH_DIRTY)        ; ring fits one page ($C9A0 + 96)
	ld a, [hli]
	ld e, a
	ld a, [hli]
	ld d, a
	ld a, [hl]
	ld [de], a
	ld a, b
	inc a
	and DIRTY_CAP - 1
	ld b, a
	dec c
	jr nz, .dloop
.dend
	ld a, b
	ld [wDirtyTail], a
.vdone
	ld a, 1
	ldh [hVsync], a
	pop hl
	pop de
	pop bc
	pop af
	reti

ShellStat:
	push af
	ldh a, [hStatStage]
	and a
	jr nz, .s1
	ld a, 167                   ; park the window below the lattice
	ldh [rWX], a
	xor a
	ldh [rSCX], a               ; label row at SCX 0
	ldh a, [hLycStrip]          ; per-config since Phase 7.5
	ldh [rLYC], a
	ld a, 1
	ldh [hStatStage], a
	pop af
	reti
.s1
	ldh a, [hStripScx]          ; history strip scroll (lines 96+)
	ldh [rSCX], a
	pop af
	reti

; OAM DMA routine template, copied to hDmaStub at shell init (the CPU may
; only execute from HRAM while DMA runs).
DmaStubRom::
	ld a, HIGH(SH_OAM)
	ldh [rDMA], a
	ld a, 40
.wait
	dec a
	jr nz, .wait
	ret
DEF DMA_STUB_LEN EQU @ - DmaStubRom
EXPORT DMA_STUB_LEN
