; Phase 9: FLEX 127 - "this Game Boy is holding a 127-qubit stabilizer
; state" (PLAN sec 0), and you are looking at the actual bits.
;
; A fully self-contained stride-32 mini-kernel: two 4064-byte planes fill
; WRAM end to end (X column of qubit q at $C000 + q*32, Z at $D000 + q*32;
; rows 0..126 destabilizers, 127..253 stabilizers, LSB-first per byte), the
; phase vector R lives in HRAM, and SP relocates into HRAM because the Z
; plane rises to within a few bytes of the natural stack. The demo builds
; the 127-qubit GHZ state (H 0, then a CNOT chain) with full phase
; bookkeeping, then lets the player MEASURE it qubit by qubit - the first
; press runs a real generic random collapse (the same CHP update the kernel
; does, reimplemented at stride 32), the rest read out determinate k=1.
; tests/test_rom_phase9.py diffs the planes and R against refsim
; Tableau(127) bit for bit, before and after each measurement.
;
; HARD RULES while the planes are live (annihilated WRAM):
; - no SfxPlay/CdxSet/Bin2Dec3/Dec5Write/MusService/mailbox access - their
;   state bytes are tableau columns now. The CDX_FLEX unlock is earned into
;   fEarn and applied by FlexRestore (main.asm) after SaveLoad rebuilds the
;   WRAM mirrors from SRAM.
; - the only kernel helpers called are RngSeed/RngBit (the $FF90 RNG block
;   is preserved), BitmaskA, and the ROM0 LUTs - nothing that touches
;   kernel WRAM scratch or hQa-family HRAM beyond the documented reuse.
; - collapse needs NO row buffers: TBUF ($CFE0, the X-plane spare) snapshots
;   the target-row mask, row p is read LIVE column-wise everywhere (it is
;   provably unmodified until its final rewrite - its own TBUF bit is
;   cleared), and per-target G-sums walk the columns through GLut exactly
;   like the kernel's k=2 path.
;
; Display: VRAM tiles 64-255 are a 192-tile framebuffer (the font in tiles
; 0-63 survives); each framebuffer tile shows 8 plane bytes duplicated onto
; both bitplanes, so the screen IS the raw column-major tableau: one page =
; 1536 plane bytes = 48 qubit columns. SELECT flips X/Z, UP/DOWN pages
; (0..2), A measures the next qubit, B exits (FlexRestore + MenuDraw).

INCLUDE "hardware.inc"
INCLUDE "shell/shell.inc"

DEF FLEX_N     EQU 127
DEF FLEX_PAGEB EQU 1536         ; plane bytes per view page
DEF FLEX_PLANEB EQU FLEX_N * 32 ; 4064

SECTION "Flex demo", ROMX, BANK[20]

FlexRun::
	; seed FIRST (the mailbox bytes become plane bits shortly)
	ld a, [MBOX_SEED_LO]
	ld e, a
	ld a, [MBOX_SEED_HI]
	ld d, a
	call RngSeed
	; save the daily-seed pin across the WRAM wipe
	ld a, [$DD35]               ; wSeedSet (menu.asm)
	ldh [fSeedSet], a
	ld a, [$DD36]
	ldh [fSeedLo], a
	ld a, [$DD37]
	ldh [fSeedHi], a
	; relocate SP into HRAM ($FFE0-$FFFD; the Z plane owns $DFxx)
	ld [fSpLo], sp
	ld sp, $FFFE
	xor a
	ldh [fPlane], a
	ldh [fPage], a
	ldh [fMeasQ], a
	ldh [fLast], a
	ldh [fEarn], a
	ld a, $FF
	ldh [fJoy], a               ; A still held from the launch: no instant measure
	; --- static screen (LCD off): captions + the framebuffer map grid ---
	call FxLcdOff
	ld hl, $9800
	ld bc, 32 * 32
.mc
	xor a
	ld [hli], a
	dec bc
	ld a, b
	or c
	jr nz, .mc
	; CGB (Phase 9.5): reset the menu's styled attrs, then ink the captions
	; (title violet, subtitle + hints slate; the raw bits keep the plain ink)
	ldh a, [hConsoleA]
	cp $11
	jr nz, .noattr
	ld a, 1
	ldh [rVBK], a
	ld hl, $9800
	ld bc, 32 * 32
.ac
	xor a
	ld [hli], a
	dec bc
	ld a, b
	or c
	jr nz, .ac
	ld hl, $9800 + 0 * 32
	ld a, MPAL_DEMO
	call FxInkRow
	ld hl, $9800 + 1 * 32
	ld a, MPAL_CARD
	call FxInkRow
	ld hl, $9800 + 16 * 32
	ld a, MPAL_CARD
	call FxInkRow
	ld hl, $9800 + 17 * 32
	ld a, MPAL_CARD
	call FxInkRow
	xor a
	ldh [rVBK], a
.noattr
	ld hl, FxTitle
	ld de, $9800 + 0 * 32
	ld b, 20
	call FxPuts
	ld hl, FxSub
	ld de, $9800 + 1 * 32
	ld b, 20
	call FxPuts
	ld hl, FxStatus
	ld de, $9800 + 15 * 32
	ld b, 20
	call FxPuts
	ld hl, FxHint1
	ld de, $9800 + 16 * 32
	ld b, 20
	call FxPuts
	ld hl, FxHint2
	ld de, $9800 + 17 * 32
	ld b, 20
	call FxPuts
	; framebuffer grid: rows 2-13, cols 2-17, tile ids 64.. row-major
	ld de, $9800 + 2 * 32 + 2
	ld c, 64                    ; tile id
	ld b, 12                    ; rows
.grow
	push bc
	ld b, 16
.gcol
	ld a, c
	ld [de], a
	inc de
	inc c
	dec b
	jr nz, .gcol
	ld a, e
	add 32 - 16
	ld e, a
	jr nc, :+
	inc d
:
	pop bc
	dec b
	jr nz, .grow
	; --- |0^127>: clear planes + R, set the diagonal ---
	ld hl, $C000
	ld bc, FLEX_PLANEB
.zx
	xor a
	ld [hli], a
	dec bc
	ld a, b
	or c
	jr nz, .zx
	ld hl, $D000
	ld bc, FLEX_PLANEB
.zz
	xor a
	ld [hli], a
	dec bc
	ld a, b
	or c
	jr nz, .zz
	ld c, LOW(FLEX_R)
	ld b, 32
.zr
	xor a
	ldh [c], a
	inc c
	dec b
	jr nz, .zr
	; diagonal: destab i = X_i (X col i, row i); stab i = Z_i (Z col i, row 127+i)
	ld b, 0                     ; i
.diag
	ld a, b
	call FxColBase              ; hl = X col i
	ld a, b
	srl a
	srl a
	srl a
	add l
	ld l, a                     ; + (i >> 3): stays in page (base low <= 224)
	ld a, b
	call FxBit7                 ; a = 1 << (i & 7)
	or [hl]
	ld [hl], a
	ld a, b
	call FxColBase
	set 4, h                    ; Z plane
	ld a, b
	add FLEX_N                  ; row 127 + i (<= 253)
	ld d, a
	srl a
	srl a
	srl a
	add l
	ld l, a
	ld a, d
	call FxBit7
	or [hl]
	ld [hl], a
	inc b
	ld a, b
	cp FLEX_N
	jr nz, .diag
	; --- GHZ: H 0, then CNOT q -> q+1 for q = 0..125 (full phase math) ---
	xor a
	call FxH
	ld b, 0
.chain
	ld a, b
	ldh [fT2], a                ; ctrl
	inc a
	ldh [fT3], a                ; tgt
	push bc
	call FxCNOT
	pop bc
	inc b
	ld a, b
	cp FLEX_N - 1
	jr nz, .chain
	call FxBlit                 ; LCD back on inside
	; --- input loop -----------------------------------------------------------
.poll
	ld a, $10
	ldh [rP1], a
	ldh a, [rP1]
	ldh a, [rP1]
	cpl
	and $0F
	ld b, a
	ld a, $20
	ldh [rP1], a
	ldh a, [rP1]
	ldh a, [rP1]
	cpl
	and $0F
	swap a
	or b
	ld b, a
	ld a, $30
	ldh [rP1], a
	ldh a, [fJoy]
	cpl
	and b
	ld c, a                     ; edges
	ld a, b
	ldh [fJoy], a
	bit JOY_B, c
	jr nz, .exit
	bit JOY_SELECT, c
	jr nz, .flip
	bit JOY_UP, c
	jr nz, .pgup
	bit JOY_DOWN, c
	jr nz, .pgdn
	bit JOY_A, c
	jr nz, .measure
	jr .poll
.flip
	ldh a, [fPlane]
	xor 1
	ldh [fPlane], a
	call FxBlit
	jr .poll
.pgup
	ldh a, [fPage]
	and a
	jr z, .poll
	dec a
	ldh [fPage], a
	call FxBlit
	jr .poll
.pgdn
	ldh a, [fPage]
	cp 2
	jr z, .poll
	inc a
	ldh [fPage], a
	call FxBlit
	jr .poll
.measure
	ldh a, [fMeasQ]
	cp FLEX_N
	jr nc, .poll                ; everything measured
	call FxMeasure              ; a = outcome
	ldh [fLast], a
	ldh a, [fMeasQ]
	inc a
	ldh [fMeasQ], a
	ld a, 1
	ldh [fEarn], a              ; CDX_FLEX (applied by FlexRestore)
	call FxBlit                 ; the collapse, on screen
	jp .poll
.exit
	; restore SP; main.asm's FlexRestore rebuilds the WRAM the menu needs
	ldh a, [fSpLo]
	ld l, a
	ldh a, [fSpHi]
	ld h, a
	ld sp, hl
	ret

; --- the stride-32 mini-kernel ------------------------------------------------

; A = qubit -> HL = $C000 + q*32 (the X column base). Clobbers AF.
FxColBase:
	ld l, a
	ld h, 0
	add hl, hl
	add hl, hl
	add hl, hl
	add hl, hl
	add hl, hl
	ld a, h
	or HIGH($C000)
	ld h, a
	ret

; A = 1 << (A & 7); a register-only BitmaskA (keeps stack use minimal).
FxBit7:
	and 7
	push hl
	add LOW(BitmaskLUT)
	ld l, a
	ld h, HIGH(BitmaskLUT)
	ld a, [hl]
	pop hl
	ret

; H on qubit A: R ^= X & Z per row, swap the columns. Unrolled over the
; 32 column bytes; C walks R in HRAM. Clobbers AF, BC, DE, HL, fT1.
FxH:
	call FxColBase
	ld d, h
	ld e, l
	set 4, d                    ; de = Z column
	ld c, LOW(FLEX_R)
	REPT 32
	ld a, [hl]                  ; X
	ld b, a
	ld a, [de]                  ; Z
	ld [hl], a                  ; X := Z
	ldh [fT1], a
	ld a, b
	ld [de], a                  ; Z := X
	ldh a, [fT1]
	and b                       ; X & Z (old values)
	ld b, a
	ldh a, [c]
	xor b
	ldh [c], a
	inc c
	inc l
	inc e
	ENDR
	ret

; CNOT fT2 -> fT3: R ^= Xa & Zb & ~(Xb ^ Za); Xb ^= Xa; Za ^= Zb.
; Unrolled; C walks R. Clobbers AF, BC, DE, HL, fT1.
FxCNOT:
	ldh a, [fT2]
	call FxColBase
	push hl
	ldh a, [fT3]
	call FxColBase
	ld d, h
	ld e, l                     ; de = Xb
	pop hl                      ; hl = Xa
	ld c, LOW(FLEX_R)
	REPT 32
	ld a, [hl]                  ; Xa (old)
	ldh [fT1], a
	ld a, [de]                  ; Xb (old)
	ld b, a
	ldh a, [fT1]
	xor b
	ld [de], a                  ; Xb ^= Xa
	set 4, h
	set 4, d
	ld a, [hl]                  ; Za (old)
	xor b                       ; ^ oldXb
	cpl                         ; ~(Xb ^ Za)
	ld b, a
	ld a, [de]                  ; Zb
	and b
	ld b, a                     ; Zb & ~(Xb^Za)
	ldh a, [fT1]
	and b                       ; t = Xa & Zb & ~(Xb^Za)
	ldh [fT1], a
	ld a, [de]                  ; Zb
	ld b, a
	ld a, [hl]                  ; Za
	xor b
	ld [hl], a                  ; Za ^= Zb
	res 4, h
	res 4, d
	ldh a, [fT1]
	ld b, a
	ldh a, [c]
	xor b
	ldh [c], a                  ; R ^= t
	inc c
	inc l
	inc e
	ENDR
	ret

; R bit A -> A = 0/1. Clobbers AF, B, C (uses ldh [c]).
FxRGet:
	ld b, a
	call FxBit7
	ld d, a
	ld a, b
	srl a
	srl a
	srl a
	add LOW(FLEX_R)
	ld c, a
	ldh a, [c]
	and d
	ret z
	ld a, 1
	ret

; R bit A := E (0/1). Clobbers AF, BC, D.
FxRSet:
	ld b, a
	call FxBit7
	ld d, a
	ld a, b
	srl a
	srl a
	srl a
	add LOW(FLEX_R)
	ld c, a
	ld a, e
	and a
	jr z, .clr
	ldh a, [c]
	or d
	ldh [c], a
	ret
.clr
	ld a, d
	cpl
	ld d, a
	ldh a, [c]
	and d
	ldh [c], a
	ret

; Measure qubit fMeasQ (Z basis). Returns A = outcome. The demo measures
; qubits IN ORDER, so after the first collapse every later measurement is a
; determinate k=1 phase read; a k != 1 here means a corrupt tableau and
; trips the kernel-error park (the same class as ERR_DET_EMPTY).
FxMeasure:
	ldh a, [fMeasQ]
	ldh [fQ], a
	call FxScanStab             ; carry: A = p (random); no carry: determinate
	jr nc, .detent
	ldh [fP], a
	jp .collapse
.detent
	; --- determinate: fold the stabilizer partners of every destabilizer
	; with an X bit at q through a scratch row - the paper's fold, at
	; stride 32 and buffer-free: the scratch row lives in TBUF (x half at
	; $CFE0, z at $CFF0) and each incoming row is read LIVE column-wise
	; (FxFoldRow merges the G-sum walk with the scratch update). Ascending
	; row order, exactly refsim's _fold_outcome.
	ld hl, FLEX_TBUF            ; scratch := identity
	ld b, 32
.dz
	xor a
	ld [hli], a
	dec b
	jr nz, .dz
	xor a
	ldh [fRp], a                ; sr
	ldh [fT3], a                ; any-hit flag
	ldh [fJ], a                 ; destab byte cursor 0..15
.dbyte
	ldh a, [fQ]
	call FxColBase
	ldh a, [fJ]
	add l
	ld l, a
	ld a, [hl]
	ld b, a
	ldh a, [fJ]
	cp 15
	ld a, b
	jr nz, :+
	and $7F                     ; byte 15: rows 120..126 only
:
	ldh [fT1], a                ; bit iterator
.dbit
	ldh a, [fT1]
	and a
	jr z, .dnextb
	ld hl, LsbLUT
	ld l, a
	ld a, [hl]
	ld d, a                     ; bit within byte
	call FxBit7
	ld e, a
	ldh a, [fT1]
	xor e
	ldh [fT1], a
	ldh a, [fJ]
	add a
	add a
	add a
	add d                       ; destab index i
	add FLEX_N                  ; partner stabilizer row 127 + i
	ldh [fI], a
	srl a
	srl a
	srl a
	ldh [fIB], a
	ldh a, [fI]
	call FxBit7
	ldh [fIM], a
	ld a, 1
	ldh [fT3], a
	call FxFoldRow              ; scratch *= row fI; sr updated
	jr .dbit
.dnextb
	ldh a, [fJ]
	inc a
	ldh [fJ], a
	cp 16
	jr nz, .dbyte
	ldh a, [fT3]
	and a
	jr nz, :+
	ld a, ERR_DET_EMPTY         ; no destabilizer hit: corrupt tableau
	jp KernelError
:
	ldh a, [fRp]                ; the fold's phase IS the outcome
	ret
.collapse
	; --- generic random collapse at stride 32 ---
	call RngBit
	ldh [fCoin], a
	; fPB/fPM = row p byte/mask
	ldh a, [fP]
	srl a
	srl a
	srl a
	ldh [fPB], a
	ldh a, [fP]
	call FxBit7
	ldh [fPM], a
	ldh a, [fP]
	call FxRGet
	ldh [fRp], a
	; TBUF := X column of q, masked to rows 0..253, bits p and p-127 cleared
	ldh a, [fQ]
	call FxColBase
	ld de, FLEX_TBUF
	ld b, 31
.tb
	ld a, [hli]
	ld [de], a
	inc e
	dec b
	jr nz, .tb
	ld a, [hl]
	and $3F
	ld [de], a
	ldh a, [fP]
	call FxTbufClear
	ldh a, [fP]
	sub FLEX_N                  ; the partner destabilizer (the paper's skip)
	call FxTbufClear
	; --- phase pass: every remaining target row i gets R[i] updated by the
	; G-sum of (row p, row i), computed column-wise through GLut ---
	xor a
	ldh [fJ], a
.pbyte
	ldh a, [fJ]
	add LOW(FLEX_TBUF)
	ld l, a
	ld h, HIGH(FLEX_TBUF)
	ld a, [hl]
	ldh [fT1], a                ; iterator copy
.pbit
	ldh a, [fT1]
	and a
	jr z, .pnext
	push hl
	ld h, HIGH(LsbLUT)
	ld l, a
	ld a, [hl]
	pop hl
	ld d, a                     ; bit
	call FxBit7
	ld e, a
	ldh a, [fT1]
	xor e
	ldh [fT1], a                ; clear from the iterator
	ldh a, [fJ]
	add a
	add a
	add a
	add d
	ldh [fI], a                 ; target row i
	srl a
	srl a
	srl a
	ldh [fIB], a
	ldh a, [fI]
	call FxBit7
	ldh [fIM], a
	call FxGsumPI               ; a = g-sum mod 4 of (row p, row i)
	ld b, a
	ldh a, [fRp]
	add a
	add b
	ld b, a
	ldh a, [fI]
	call FxRGet
	add a
	add b
	and 3
	bit 0, a
	jr z, :+
	ld a, ERR_ODD_GSUM          ; commuting rows: an odd sum is corruption
	jp KernelError
:
	srl a
	ld e, a
	ldh a, [fI]
	call FxRSet
	jr .pbit
.pnext
	ldh a, [fJ]
	inc a
	ldh [fJ], a
	cp 32
	jr nz, .pbyte
	; --- column update: any column whose row-p bit is set (X or Z part)
	; XORs TBUF into that part. Row p's own TBUF bit is cleared, so row p
	; stays intact through this pass (read live everywhere). ---
	ld b, 0                     ; q2
.cu
	ld a, b
	call FxColBase
	push bc
	ldh a, [fPB]
	add l
	ld e, a
	ld d, h                     ; de -> X byte holding row p
	ld a, [de]
	ld c, a
	ldh a, [fPM]
	and c
	jr z, .noX
	call FxXorTbuf              ; XOR TBUF into the X column (hl = base)
.noX
	set 4, h
	set 4, d
	ld a, [de]
	ld c, a
	ldh a, [fPM]
	and c
	jr z, .noZ
	call FxXorTbuf              ; hl -> Z column base (bit 4 set)
.noZ
	pop bc
	inc b
	ld a, b
	cp FLEX_N
	jr nz, .cu
	; --- copy row p into row p-127 (both planes + R) ---
	ld b, 0
.cp
	ld a, b
	call FxColBase
	push bc
	call FxCopyPBit             ; X part
	set 4, h
	call FxCopyPBit             ; Z part
	pop bc
	inc b
	ld a, b
	cp FLEX_N
	jr nz, .cp
	ldh a, [fRp]
	ld e, a
	ldh a, [fP]
	sub FLEX_N
	call FxRSet
	; --- row p := Z_q with phase = coin ---
	ld b, 0
.clr
	ld a, b
	call FxColBase
	push bc
	ldh a, [fPB]
	add l
	ld l, a
	ldh a, [fPM]
	cpl
	ld d, a
	ld a, [hl]
	and d
	ld [hl], a
	set 4, h
	ld a, [hl]
	and d
	ld [hl], a
	pop bc
	inc b
	ld a, b
	cp FLEX_N
	jr nz, .clr
	ldh a, [fQ]
	call FxColBase
	set 4, h                    ; Z column of q
	ldh a, [fPB]
	add l
	ld l, a
	ldh a, [fPM]
	or [hl]
	ld [hl], a
	ldh a, [fCoin]
	ld e, a
	ldh a, [fP]
	call FxRSet
	ldh a, [fCoin]
	ret

; Scan the stabilizer region (rows 127..253) of X col fQ for the smallest
; anticommuting row. Returns CARRY set + A = p, or carry clear (determinate).
FxScanStab:
	ldh a, [fQ]
	call FxColBase
	ld b, 15                    ; byte cursor (row 127 = byte 15 bit 7)
.s
	ld a, l
	add b
	ld e, a
	ld d, h
	ld a, [de]
	ld c, a
	ld a, b
	cp 15
	jr nz, :+
	ld a, c
	and $80
	ld c, a
:
	ld a, b
	cp 31
	jr nz, :+
	ld a, c
	and $3F
	ld c, a
:
	ld a, c
	and a
	jr nz, .hit
	inc b
	ld a, b
	cp 32
	jr nz, .s
	and a                       ; carry clear: determinate
	ret
.hit
	push hl
	ld h, HIGH(LsbLUT)
	ld l, c
	ld a, [hl]
	pop hl
	ld c, a
	ld a, b
	add a
	add a
	add a
	add c
	scf                         ; carry: random, A = p
	ret

; Clear bit A (row index) of TBUF. Clobbers AF, DE, preserves HL? no - AF/DE.
FxTbufClear:
	ld e, a
	call FxBit7
	cpl
	ld d, a
	ld a, e
	srl a
	srl a
	srl a
	add LOW(FLEX_TBUF)
	ld e, a
	push hl
	ld l, e
	ld h, HIGH(FLEX_TBUF)
	ld a, [hl]
	and d
	ld [hl], a
	pop hl
	ret

; XOR TBUF (32 B) into the 32-byte column at HL (preserves HL, DE, BC... it
; must preserve HL/DE for the caller). Clobbers AF + fT1.
FxXorTbuf:
	push hl
	push de
	push bc
	ld de, FLEX_TBUF
	ld b, 32
.x
	ld a, [de]
	ld c, a
	ld a, [hl]
	xor c
	ld [hli], a
	inc e
	dec b
	jr nz, .x
	pop bc
	pop de
	pop hl
	ret

; Copy bit p -> bit p-127 within the 32-byte column at HL (one plane part).
; Preserves HL. Clobbers AF, C, DE, fT1.
FxCopyPBit:
	push hl
	ldh a, [fPB]
	add l
	ld l, a
	ldh a, [fPM]
	and [hl]
	ldh [fT1], a                ; nonzero = source bit set
	pop hl
	push hl
	ldh a, [fP]
	sub FLEX_N
	ld c, a
	srl a
	srl a
	srl a
	add l
	ld l, a
	ld a, c
	call FxBit7
	ld d, a
	ldh a, [fT1]
	and a
	jr z, .clr
	ld a, [hl]
	or d
	ld [hl], a
	pop hl
	ret
.clr
	ld a, d
	cpl
	ld d, a
	ld a, [hl]
	and d
	ld [hl], a
	pop hl
	ret

; Fold stabilizer row fI (via fIB/fIM) into the scratch row at FLEX_TBUF
; (x half $CFE0, z half $CFF0): one column walk computes the G-sum of
; (row = LEFT, old scratch = RIGHT) through GLut AND applies scratch ^= row;
; then sr (fRp) := (k + 2*R[row] + 2*sr) >> 1, odd = corruption.
; Clobbers AF, BC, DE, HL, fK, fT2.
FxFoldRow:
	xor a
	ldh [fK], a
	ld hl, $C000
	ld c, 0                     ; qubit column q2
.col
	ld d, 0                     ; LUT index: x1 b3, z1 b2, x2 b1, z2 b0
	push hl
	ldh a, [fIB]
	add l
	ld l, a
	ldh a, [fIM]
	and [hl]
	jr z, :+
	set 3, d                    ; x1 = row bit, X plane
:
	set 4, h
	ldh a, [fIM]
	and [hl]
	jr z, :+
	set 2, d                    ; z1
:
	pop hl
	ld a, d
	ldh [fT2], a
	; scratch bits (OLD values feed the G-sum) + the ^= row update, X half
	ld a, c
	call FxBit7
	ld e, a                     ; 1 << (q2 & 7)
	ld a, c
	srl a
	srl a
	srl a
	add LOW(FLEX_TBUF)
	push hl
	ld l, a
	ld h, HIGH(FLEX_TBUF)
	ld a, [hl]
	and e
	jr z, :+
	ldh a, [fT2]
	set 1, a                    ; x2
	ldh [fT2], a
:
	ldh a, [fT2]
	bit 3, a
	jr z, :+
	ld a, [hl]
	xor e                       ; scratch X ^= row X
	ld [hl], a
:
	ld a, l
	add 16                      ; z half
	ld l, a
	ld a, [hl]
	and e
	jr z, :+
	ldh a, [fT2]
	or 1                        ; z2
	ldh [fT2], a
:
	ldh a, [fT2]
	bit 2, a
	jr z, :+
	ld a, [hl]
	xor e                       ; scratch Z ^= row Z
	ld [hl], a
:
	pop hl
	push hl
	ldh a, [fT2]
	add LOW(GLut)
	ld l, a
	ld a, HIGH(GLut)
	adc 0
	ld h, a
	ld a, [hl]
	ld e, a
	ldh a, [fK]
	add e
	ldh [fK], a
	pop hl
	ld a, l
	add 32
	ld l, a
	jr nc, :+
	inc h
:
	inc c
	ld a, c
	cp FLEX_N
	jp nz, .col
	; sr := (k + 2*R[row] + 2*sr) >> 1 (odd total = corrupt tableau)
	ldh a, [fI]
	call FxRGet
	add a
	ld b, a
	ldh a, [fK]
	add b
	ld b, a
	ldh a, [fRp]
	add a
	add b
	and 3
	bit 0, a
	jr z, :+
	ld a, ERR_ODD_GSUM
	jp KernelError
:
	srl a
	ldh [fRp], a
	ret

; G-sum mod 4 of rows p (left) and i (right), column-walked through GLut
; (a column-wise pairwise g-sum at stride 32). In: fPB/fPM/fIB/fIM.
; Out: A. Clobbers AF, BC, DE, HL, fK.
FxGsumPI:
	xor a
	ldh [fK], a
	ld hl, $C000                ; column 0 X base
	ld b, FLEX_N
.col
	ld d, 0                     ; LUT index
	push hl
	ldh a, [fPB]
	add l
	ld l, a
	ldh a, [fPM]
	and [hl]
	jr z, :+
	set 3, d                    ; x1
:
	set 4, h
	ldh a, [fPM]
	and [hl]
	jr z, :+
	set 2, d                    ; z1
:
	pop hl
	push hl
	ldh a, [fIB]
	add l
	ld l, a
	ldh a, [fIM]
	and [hl]
	jr z, :+
	set 1, d                    ; x2
:
	set 4, h
	ldh a, [fIM]
	and [hl]
	jr z, :+
	inc d                       ; z2
:
	pop hl
	push hl
	ld a, LOW(GLut)
	add d
	ld l, a
	ld a, HIGH(GLut)
	adc 0
	ld h, a
	ld a, [hl]
	ld e, a
	ldh a, [fK]
	add e
	ldh [fK], a
	pop hl
	ld a, l
	add 32
	ld l, a
	jr nc, :+
	inc h
:
	dec b
	jr nz, .col
	ldh a, [fK]
	and 3
	ret

; --- display --------------------------------------------------------------------

FxLcdOff:
	ldh a, [rLCDC]
	add a                       ; bit 7 (enable) -> carry
	ret nc                      ; already off (LY parks at 0: never wait)
.wv
	ldh a, [rLY]
	cp SCREEN_HEIGHT_PX
	jr nz, .wv
	xor a
	ldh [rLCDC], a
	ret

; Full framebuffer + status redraw (LCD off -> on). The 192 tiles show 1536
; plane bytes of the current view, duplicated onto both bitplanes.
FxBlit:
	call FxLcdOff
	; src = plane base + page * 1536
	ldh a, [fPage]
	ld h, a
	ld l, 0                     ; hl = page * 256
	add hl, hl                  ; * 512
	ld d, h
	ld e, l                     ; de = page * 512
	add hl, hl                  ; * 1024
	add hl, de                  ; * 1536
	ldh a, [fPlane]
	and a
	ld a, HIGH($C000)
	jr z, :+
	ld a, HIGH($D000)
:
	add h
	ld h, a                     ; hl = src
	; count = min(1536, plane bytes remaining past this page's start)
	ldh a, [fPage]
	ld de, FLEX_PLANEB
	and a
	jr z, .havelen
	cp 1
	ld de, FLEX_PLANEB - FLEX_PAGEB
	jr z, .havelen
	ld de, FLEX_PLANEB - 2 * FLEX_PAGEB
.havelen
	; count = min(1536, rem); pad = 1536 - count
	ld a, d
	cp HIGH(FLEX_PAGEB)
	jr c, .short
	jr nz, .full
	ld a, e
	cp LOW(FLEX_PAGEB)
	jr c, .short
.full
	ld de, FLEX_PAGEB
.short
	; copy DE src bytes duplicated; then zero-pad to 1536
	push de
	ld bc, $8000 + 64 * 16      ; dst: tile 64
	; (bc as dst pointer; hl = src; de = count)
.dup
	ld a, d
	or e
	jr z, .pad
	ld a, [hli]
	ld [bc], a
	inc bc
	ld [bc], a
	inc bc
	dec de
	jr .dup
.pad
	pop de
	ld a, LOW(FLEX_PAGEB)
	sub e
	ld l, a
	ld a, HIGH(FLEX_PAGEB)
	sbc d
	ld h, a                     ; hl = pad count
.padl
	ld a, h
	or l
	jr z, .status
	xor a
	ld [bc], a
	inc bc
	ld [bc], a
	inc bc
	dec hl
	jr .padl
.status
	; status row 15: "Q NNN OUT N  X PG N"
	ldh a, [fMeasQ]
	call FxDec3                 ; fT1..fT3 = digits
	ldh a, [fT1]
	ld [$9800 + 15 * 32 + 2], a
	ldh a, [fT2]
	ld [$9800 + 15 * 32 + 3], a
	ldh a, [fT3]
	ld [$9800 + 15 * 32 + 4], a
	ldh a, [fLast]
	add FONT_BASE
	ld [$9800 + 15 * 32 + 10], a
	ldh a, [fPlane]
	and a
	ld a, FONT_BASE + 32        ; 'X' (font: 0-9 then A-Z minus J)
	jr z, :+
	ld a, FONT_BASE + 34        ; 'Z'
:
	ld [$9800 + 15 * 32 + 13], a
	ldh a, [fPage]
	add FONT_BASE + 1
	ld [$9800 + 15 * 32 + 19], a
	ld a, LCDC_ENABLE | LCDC_BLOCK01 | LCDC_BG_9800 | LCDC_BG
	ldh [rLCDC], a
	ret

; A -> fT1..fT3 = three decimal digit TILES (no shell scratch usable here).
FxDec3:
	ld b, FONT_BASE
.h
	cp 100
	jr c, .hd
	sub 100
	inc b
	jr .h
.hd
	ld c, a
	ld a, b
	ldh [fT1], a
	ld a, c
	ld b, FONT_BASE
.t
	cp 10
	jr c, .td
	sub 10
	inc b
	jr .t
.td
	ld c, a
	ld a, b
	ldh [fT2], a
	ld a, c
	add FONT_BASE
	ldh [fT3], a
	ret

; hl = text, de = dest, b = len (LCD off).
FxPuts:
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, FxPuts
	ret

; Fill 20 attr cols at HL with A (caller holds VBK = 1). Clobbers B, HL.
FxInkRow:
	ld b, 20
.f
	ld [hli], a
	dec b
	jr nz, .f
	ret

FxTitle:  db "  FLEX - 127 QUBITS "
FxSub:    db "RAW STABILIZER STATE"
FxStatus: db "Q 000 OUT .  X PG 1 "
FxHint1:  db "A-MEASURE  SEL-X.Z  "
FxHint2:  db "UD-PAGE      B-MENU "
