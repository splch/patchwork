; Measurement path (SPEC.md "Measurement of Z_a"): k=1 free phase read,
; k=2 pairwise g-sum straight from column-major, k>=3 scratch fold, and the
; random branch with smallest-p, the i = p-n skip, and evenness asserts.
; Written for obvious correctness first; the gate slices carry the cycle
; budget (PLAN.md 2.3: measurement is not the wall).
;
; MeasureZ: hQa = qubit -> A = outcome (0/1). Clobbers AF/BC/DE/HL and
; hTmp1-4, hP, hCoin, hRp, hK, hRow, hIter*. Preserves hQa, hQb.

INCLUDE "hardware.inc"
INCLUDE "kernel/kernel.inc"

; hl = XPLANE_BASE + \1*16 (same as tableau.asm's helper; kept local)
MACRO MXBASE
	ld l, \1
	ld h, 0
	add hl, hl
	add hl, hl
	add hl, hl
	add hl, hl
	ld a, h
	or HIGH(XPLANE_BASE)
	ld h, a
ENDM

SECTION "Measure helpers", ROM0

; A = row index -> A = phase bit (0/1). Clobbers AF, BC.
RReadBit::
	ld b, a
	and 7
	call BitmaskA               ; clobbers AF only
	ld c, a                     ; c = mask
	ld a, b
	srl a
	srl a
	srl a
	add LOW(RVEC)
	ld b, c                     ; b = mask
	ld c, a                     ; c = HRAM address low
	ldh a, [c]
	and b
	ret z
	ld a, 1
	ret

; A = row index, B = value (0/1). Clobbers AF, BC.
RWriteBit::
	ldh [hTmp1], a
	ld a, b
	ldh [hTmp2], a
	ldh a, [hTmp1]
	and 7
	call BitmaskA
	ld b, a                     ; b = mask
	ldh a, [hTmp1]
	srl a
	srl a
	srl a
	add LOW(RVEC)
	ld c, a
	ldh a, [hTmp2]
	and a
	jr z, .clear
	ldh a, [c]
	or b
	ldh [c], a
	ret
.clear
	ld a, b
	cpl
	ld b, a
	ldh a, [c]
	and b
	ldh [c], a
	ret

; Clear bit A of TBUF. Clobbers AF, BC, HL.
TbufClearBit::
	ld b, a
	and 7
	call BitmaskA
	cpl
	ld c, a                     ; c = ~mask
	ld a, b
	srl a
	srl a
	srl a
	add LOW(TBUF)
	ld l, a
	ld h, HIGH(TBUF)
	ld a, [hl]
	and c
	ld [hl], a
	ret

; Lowest set bit of CBUF (8 bytes, assumed nonempty): returns its index in A
; and CLEARS it (so repeated calls enumerate ascending). Clobbers AF, BC, DE, HL.
CbufFirstBit::
	ld hl, CBUF
	ld c, 0
.scan
	ld a, [hl]
	and a
	jr nz, .found
	inc l
	inc c
	jr .scan
.found
	ld e, l                     ; save CBUF byte address low
	ld l, a
	ld h, HIGH(LsbLUT)
	ld a, [hl]                  ; a = bit index within byte
	push af
	call BitmaskA
	cpl
	ld l, e
	ld h, HIGH(CBUF)
	and [hl]
	ld [hl], a                  ; clear the bit
	pop af
	ld b, a
	ld a, c
	add a
	add a
	add a
	add b                       ; index = byte*8 + bit
	ret

; Extract row A into the 16-byte buffer at DE (X part at DE, Z at DE+8).
; Iterates ceil(n/8)*8 columns; columns >= n read cleared zeros.
; The buffer must live in the $C5xx row-buffer page (they all do).
; Clobbers AF/BC/DE/HL, hTmp1-4.
ExtractRow::
	ldh [hTmp1], a              ; row index
	ld a, e
	ldh [hTmp2], a              ; dest low (X part; advances through both planes)
	ldh a, [hTmp1]
	and 7
	call BitmaskA
	ldh [hTmp3], a              ; row bitmask
	ldh a, [hTmp1]
	srl a
	srl a
	srl a
	ldh [hTmp4], a              ; row byte offset
	; the X pass leaves hTmp2 at dest+8 (bytes + zero-fill), where Z begins
	ld a, HIGH(XPLANE_BASE)
	call .plane
	ld a, HIGH(ZPLANE_BASE)
.plane
	ld h, a
	ldh a, [hTmp4]
	ld l, a                     ; hl -> column 0's row byte in this plane
	ldh a, [hCfgRowB]
	ldh [hTmp1], a              ; output byte countdown (row index is consumed)
	ldh a, [hTmp3]
	ld c, a                     ; c = row bitmask
	ld de, 16                   ; column stride: add hl, de rides page crossings
	; Produce hCfgRowB real bytes, then ZERO-FILL to 8: the unrolled g-sums
	; read the full buffer (stale-tail bug found by the cross-config fuzz),
	; but reading columns beyond ceil(n/8)*8 is wasted work at d3.
.obyte
	REPT 8
	ld a, [hl]
	and c
	add a, $FF                  ; carry = bit set
	rr b
	add hl, de
	ENDR
	push hl
	ldh a, [hTmp2]
	ld l, a
	ld h, HIGH(TBUF)            ; all row buffers live in the $C5xx page
	ld [hl], b
	inc a
	ldh [hTmp2], a
	pop hl
	ldh a, [hTmp1]
	dec a
	ldh [hTmp1], a
	jr nz, .obyte
	ldh a, [hCfgRowB]
	ld c, a
	ldh a, [hTmp2]
	ld l, a
	ld h, HIGH(TBUF)
.fill
	ld a, c
	cp 8
	jr z, .filled
	ld [hl], 0
	inc l
	inc c
	jr .fill
.filled
	ld a, l
	ldh [hTmp2], a              ; = plane dest + 8: the Z pass starts here
	ret

SECTION "G_LUT", ROM0

GLut:: db 0, 0, 0, 0, 0, 0, 1, 3, 0, 3, 0, 1, 0, 1, 3, 0

; Buffer-vs-buffer g-sum mod 4, unrolled over the 8-byte row buffers,
; bounded to the hCfgRowB real bytes (the zero-filled tail contributes 0 to
; every term, so skipping it is free precision-wise and saves ~70/byte).
; \1/\2 = LEFT X/Z bases, \3/\4 = RIGHT X/Z bases, \5 = name suffix.
; k = pc(Lx&Lz) + pc(Rx&Rz) + 2*pc(Lz&Rx) - pc((Lx^Rx)&(Lz^Rz))  (mod 4)
; Out: A. Clobbers AF, BC, D, E, HL.
MACRO M_GSUMBUF
Gsum\5::
	ld h, HIGH(PopcntLUT)
	ldh a, [hCfgRowB]
	ld c, a                     ; byte bound
	ld e, 0                     ; running total
	ld d, 0                     ; t3 accumulator
	FOR J, 8
	ld a, [\1 + J]              ; t1 term: Lx & Lz
	ld b, a
	ld a, [\2 + J]
	and b
	ld l, a
	ld a, [hl]
	add e
	ld e, a
	ld a, [\3 + J]              ; t2 term: Rx & Rz
	ld b, a
	ld a, [\4 + J]
	and b
	ld l, a
	ld a, [hl]
	add e
	ld e, a
	ld a, [\2 + J]              ; t3 term: Lz & Rx
	ld b, a
	ld a, [\3 + J]
	and b
	ld l, a
	ld a, [hl]
	add d
	ld d, a
	ld a, [\1 + J]              ; t4 term: (Lx^Rx) & (Lz^Rz)
	ld b, a
	ld a, [\3 + J]
	xor b
	ld b, a
	ld a, [\2 + J]
	ld l, a
	ld a, [\4 + J]
	xor l
	and b
	ld l, a
	ld a, [hl]
	ld b, a
	ld a, e
	sub b
	ld e, a
	IF J < 7
	dec c
	jp z, .out                  ; jp: .out is beyond jr range from early J
	ENDC
	ENDR
.out
	ld a, d                     ; total += 2 * t3
	add a
	add e
	and 3
	ret
ENDM

SECTION "Buffer gsums", ROM0

	M_GSUMBUF IROW_X, IROW_Z, SCR_X, SCR_Z, IS
	M_GSUMBUF PROW_X, PROW_Z, IROW_X, IROW_Z, PI

; --- main entry --------------------------------------------------------------

SECTION "MeasureZ", ROM0

; hQa = qubit -> A = outcome. See header comment for clobbers.
MeasureZ::
	; Stabilizer rows live in column bytes hScanOff.. only, so the
	; anticommute scan starts there (destab bytes can't set stab-mask bits).
	ldh a, [hQa]
	MXBASE a                    ; hl -> X column of q
	ldh a, [hScanOff]
	ld c, a                     ; c = byte index
	add l
	ld l, a                     ; hl -> first stab byte (16-aligned base)
	ldh a, [hMaskLo]
	ld e, a
	ldh a, [hMaskHi]
	ld d, a
	ldh a, [hScanOff]
	add e
	ld e, a
	jr nc, :+
	inc d
:                               ; de -> stab mask + scanoff
	ldh a, [hScanCnt]
	ld b, a
.scan
	ld a, [de]
	and [hl]
	jr nz, .random
	inc l
	inc e
	inc c
	dec b
	jr nz, .scan
	jr MeasDeterminate
.random
	ld l, a                     ; a = masked byte (nonzero)
	ld h, HIGH(LsbLUT)
	ld a, [hl]
	ld b, a
	ld a, c
	add a
	add a
	add a
	add b
	ldh [hP], a                 ; p = smallest anticommuting stabilizer row
	jp RandomCollapse

MeasDeterminate:
	; Store-free fast pass: count nonzero destab bytes; the dominant k = 1
	; case (single nonzero byte with a single bit) never touches CBUF or
	; the popcount LUT. Rare multi-bit cases rebuild CBUF below.
	ldh a, [hQa]
	MXBASE a
	ldh a, [hMaskLo]
	add 16                      ; destab mask (page-safe: masks are aligned)
	ld e, a
	ldh a, [hMaskHi]
	adc 0
	ld d, a
	ldh a, [hCfgRowB]
	ld b, a
	ld c, 0                     ; c = nonzero-byte count
.fast
	ld a, [de]
	and [hl]
	jr nz, .hit
.cont
	inc l
	inc e
	dec b
	jr nz, .fast
	ld a, c
	and a
	jr nz, .some
	ld a, ERR_DET_EMPTY
	jp KernelError
.hit
	ldh [hTmp2], a              ; the nonzero masked byte
	ldh a, [hCfgRowB]
	sub b                       ; byte index (b not yet decremented)
	ldh [hTmp3], a
	inc c
	jr .cont
.some
	cp 1
	jr nz, .rebuild             ; bits spread over several bytes: k >= 2
	ldh a, [hTmp2]
	ld b, a
	dec a
	and b
	jr nz, .rebuild             ; two+ bits in one byte: k >= 2
	; k == 1: free phase-bit read, outcome = R[n + idx*8 + lsb]
	ldh a, [hTmp2]
	ld l, a
	ld h, HIGH(LsbLUT)
	ld a, [hl]
	ld b, a
	ldh a, [hTmp3]
	add a
	add a
	add a
	add b
	ld b, a
	ldh a, [hCfgN]
	add b
	jp RReadBit                 ; tail call: A = outcome
.rebuild
	; k >= 2 (rare): build CBUF + exact popcount for the k2/fold paths.
	ldh a, [hQa]
	MXBASE a
	ldh a, [hMaskLo]
	add 16
	ld e, a
	ldh a, [hMaskHi]
	adc 0
	ld d, a
	ldh a, [hCfgRowB]
	ld b, a
	ld c, LOW(CBUF)
	xor a
	ldh [hK], a
.cb
	ld a, [de]
	and [hl]
	push hl
	ld h, HIGH(CBUF)
	ld l, c
	ld [hl], a
	ld l, a
	ld h, HIGH(PopcntLUT)
	ld a, [hl]
	ld l, a
	ldh a, [hK]
	add l
	ldh [hK], a
	pop hl
	inc l
	inc e
	inc c
	dec b
	jr nz, .cb
	jp MeasDetFromCbuf

; CBUF + hK set (k >= 1): the shared determinate dispatch (MeasureZ's
; rebuild path and MeasurePP). k = 1 free phase read; k = 2 pairwise column
; g-sum; k >= 3 scratch fold. Returns A = outcome.
MeasDetFromCbuf:
	ldh a, [hK]
	cp 1
	jr nz, .k2chk
	call CbufFirstBit
	ld b, a
	ldh a, [hCfgN]
	add b
	jp RReadBit
.k2chk
	cp 2
	jp nz, MeasFold
	; fall through
MeasK2:
	; outcome = ((gsum + 2*r1 + 2*r2) mod 4) >> 1, g-sum via two row
	; extractions + the unrolled buffer g-sum. (The old per-column
	; 4-bit-probe GsumPairColumns cost ~2x this at n=49 and is gone.)
	; Charges: ROM-measured 2026-08-20 on CX-fan k=2 windows (c0 3,170 /
	; c1 5,150 incl. dispatch) + margin. The pre-rework c0 charge (2200)
	; undercharged even its own path (~2.5k measured) - the G2 defect class.
	ldh a, [hCfg]
	and a
	ld de, 3500
	jr z, :+
	ld de, 5600
:
	call KCharge
	call CbufFirstBit
	ld b, a
	ldh a, [hCfgN]
	add b
	ldh [hP], a                 ; row1 (hP free on this path)
	call CbufFirstBit
	ld b, a
	ldh a, [hCfgN]
	add b
	ldh [hCoin], a              ; row2 (hCoin free on this path)
	ldh a, [hP]
	ld de, PROW_X
	call ExtractRow
	ldh a, [hCoin]
	ld de, IROW_X
	call ExtractRow
	call GsumPI                 ; left = row1 buffer, right = row2 buffer
	ldh [hK], a
	ldh a, [hP]
	call RReadBit
	add a
	ld b, a
	ldh a, [hK]
	add b
	ldh [hK], a
	ldh a, [hCoin]
	call RReadBit
	add a
	ld b, a
	ldh a, [hK]
	add b
	and 3
	bit 0, a
	jr nz, .odd
	srl a
	ret
.odd
	ld a, ERR_ODD_GSUM
	jp KernelError

MeasFold:
	; k >= 3: fold stabilizer partners through the scratch row (ascending).
	ld hl, SCR_X
	ld b, 16
	xor a
.z
	ld [hli], a
	dec b
	jr nz, .z
	xor a
	ldh [hRp], a                ; sr
	ldh a, [hK]
	ldh [hP], a                 ; remaining count (hP free on this path)
.fold
	; Per-step charge: ExtractRow + bounded buffer g-sum + scratch XOR.
	; ROM-measured 2026-08-20 (CX-fan k4-k3 delta): ~1.57k at n=17,
	; ~2.59k at n=49; charged with margin. (The 2026-08-19 pass charged
	; 1800/3800 - by 2026-08-20 the c0 step had crept to ~2.1k measured,
	; an undercharge; the ExtractRow/g-sum rework brought it back under.)
	ldh a, [hCfg]
	and a
	ld de, 1800
	jr z, :+
	ld de, 2900
:
	call KCharge                ; yields mid-fold in engine context only
	call CbufFirstBit
	ld b, a
	ldh a, [hCfgN]
	add b
	ldh [hCoin], a              ; current row = n + i (hCoin free here)
	ld de, IROW_X
	call ExtractRow
	call GsumIS                 ; left = incoming row, right = scratch
	ld b, a
	ldh a, [hCoin]
	push bc
	call RReadBit
	pop bc
	add a
	add b                       ; gsum + 2*r_row
	ld b, a
	ldh a, [hRp]
	add a
	add b
	and 3
	bit 0, a
	jr nz, .odd
	srl a
	ldh [hRp], a                ; sr = tot >> 1
	ld hl, SCR_X                ; scratch ^= row (16 bytes, same page)
	ld de, IROW_X
	ld b, 16
.xr
	ld a, [de]
	xor [hl]
	ld [hl], a
	inc l
	inc e
	dec b
	jr nz, .xr
	ldh a, [hP]
	dec a
	ldh [hP], a
	jr nz, .fold
	ldh a, [hRp]
	ret
.odd
	ld a, ERR_ODD_GSUM
	jp KernelError

; --- random branch -----------------------------------------------------------

SECTION "Random collapse", ROM0

RandomCollapse:
	ld de, 4200                 ; Tbuf + extract row p + fixed tail
	call KCharge
	call RngBit
	ldh [hCoin], a
	; TBUF = Xq & fullmask (the Z-measurement anti vector)
	ldh a, [hQa]
	MXBASE a
	ldh a, [hMaskLo]
	add 32                      ; full row mask
	ld e, a
	ldh a, [hMaskHi]
	adc 0
	ld d, a
	ldh a, [hCfgSlice]
	ld b, a
	ld c, LOW(TBUF)
.tb
	ld a, [de]
	and [hl]
	push hl
	ld h, HIGH(TBUF)
	ld l, c
	ld [hl], a
	pop hl
	inc l
	inc e
	inc c
	dec b
	jr nz, .tb
	call CollapseCommon
	; --- row p := Z_q ---
	ldh a, [hP]
	call ClearRowBitAllCols
	; set bit p of Z column of q
	ldh a, [hQa]
	MXBASE a
	set 4, h                    ; Z plane
	ldh a, [hP]
	srl a
	srl a
	srl a
	add l
	ld l, a
	ldh a, [hP]
	and 7
	call BitmaskA
	or [hl]
	ld [hl], a
	ldh a, [hCoin]
	ld b, a
	ldh a, [hP]
	call RWriteBit
	ldh a, [hCoin]
	ret

; Generalized random branch (MeasurePP): TBUF already holds the anti vector.
MppRandom:
	ld de, 4200
	call KCharge
	call RngBit
	ldh [hCoin], a
	call CollapseCommon
	; --- row p := the measured Pauli M ---
	ldh a, [hP]
	call ClearRowBitAllCols
	call MppWriteRowP
	ldh a, [hCoin]
	ld b, a
	ldh a, [hP]
	call RWriteBit
	ldh a, [hCoin]
	ret

; Shared collapse body (SPEC "Measurement", random branch): TBUF = the anti
; vector (& full mask), hP = smallest anticommuting stabilizer row, hCoin
; set. Clears bits p and p-n from TBUF, extracts row p, phase-passes every
; remaining target, XORs row p into their columns, and copies row p into
; the destabilizer partner p-n (R bit included). Row p itself is left to
; the caller (Z_q vs the generalized M). Clobbers everything.
CollapseCommon:
	ldh a, [hP]
	call TbufClearBit
	ldh a, [hCfgN]
	ld b, a
	ldh a, [hP]
	sub b
	call TbufClearBit           ; skip i = p - n (QUANTUM.md 18.2)
	; extract row p; latch its phase
	ldh a, [hP]
	ld de, PROW_X
	call ExtractRow
	ldh a, [hP]
	call RReadBit
	ldh [hRp], a
	; --- phase pass over targets (columns still untouched) ---
	xor a
	ldh [hIterByte], a
.pbyte
	ldh a, [hIterByte]
	ld c, a
	ldh a, [hCfgSlice]
	cp c
	jr z, .columns
	ld h, HIGH(TBUF)
	ld a, LOW(TBUF)
	add c
	ld l, a
	ld a, [hl]
	ldh [hIterBits], a
.pbit
	ldh a, [hIterBits]
	and a
	jr z, .nextbyte
	ld l, a
	ld h, HIGH(LsbLUT)
	ld a, [hl]
	ld b, a                     ; bit index
	push bc
	call BitmaskA               ; a = 1 << bit
	ld c, a
	ldh a, [hIterBits]
	xor c                       ; clear the bit from the iterator
	ldh [hIterBits], a
	pop bc
	ldh a, [hIterByte]
	add a
	add a
	add a
	add b
	ldh [hRow], a               ; target row i
	ld de, 3300                 ; per-target: extraction + g-sum + phases
	call KCharge
	ldh a, [hRow]               ; ExtractRow takes the row in A (KCharge ate it)
	ld de, IROW_X
	call ExtractRow
	call GsumPI                 ; left = row p, right = row i
	ld b, a
	ldh a, [hRp]
	add a
	add b
	ld b, a
	ldh a, [hRow]
	push bc
	call RReadBit
	pop bc
	add a
	add b
	and 3
	bit 0, a
	jr nz, .odd
	srl a
	ld b, a
	ldh a, [hRow]
	call RWriteBit
	jr .pbit
.nextbyte
	ldh a, [hIterByte]
	inc a
	ldh [hIterByte], a
	jr .pbyte
.odd
	ld a, ERR_ODD_GSUM
	jp KernelError
	; --- batched column update: cols with PROW bit set get TBUF xored in ---
.columns
	xor a
	ldh [hRow], a               ; q2 counter
.cu
	; Charge every 8 columns (worst ~230 M/column when both planes XOR).
	ldh a, [hRow]
	and 7
	jr nz, .nocucharge
	ld de, 2000
	call KCharge
.nocucharge
	ldh a, [hRow]
	ld c, a
	; PROW_X bit q2?
	srl a
	srl a
	srl a
	add LOW(PROW_X)
	ld l, a
	ld h, HIGH(TBUF)
	ld a, c
	and 7
	call BitmaskA
	and [hl]
	jr z, .noX
	ld a, c
	call XorTbufIntoXcol
.noX
	ldh a, [hRow]
	ld c, a
	srl a
	srl a
	srl a
	add LOW(PROW_Z)
	ld l, a
	ld h, HIGH(TBUF)
	ld a, c
	and 7
	call BitmaskA
	and [hl]
	jr z, .noZ
	ld a, c
	call XorTbufIntoZcol
.noZ
	ldh a, [hRow]
	inc a
	ldh [hRow], a
	ld b, a
	ldh a, [hCfgN]
	cp b
	jr nz, .cu
	; --- copy row p -> row p-n (bits from PROW), R bit too ---
	; Charge the fixed tail: WriteRowFromProw (~120/col) + ClearRowBitAllCols
	; (~50/col) + row-p rewrite, ~8.4k worst at n=49.
	ld de, 10400
	call KCharge
	ldh a, [hCfgN]
	ld b, a
	ldh a, [hP]
	sub b
	ldh [hRow], a               ; dest row p-n
	call WriteRowFromProw
	ldh a, [hRp]
	ld b, a
	ldh a, [hCfgN]
	ld c, a
	ldh a, [hP]
	sub c
	call RWriteBit
	ret

; XOR TBUF (slice bytes) into the X column of qubit A. Clobbers AF, B, DE, HL.
XorTbufIntoXcol::
	MXBASE a
	jr XorTbufCommon
XorTbufIntoZcol::
	MXBASE a
	set 4, h
XorTbufCommon:
	ld de, TBUF
	ldh a, [hCfgSlice]
	ld b, a
.x
	ld a, [de]
	xor [hl]
	ld [hl], a
	inc l
	inc e
	dec b
	jr nz, .x
	ret

; Write row hRow of every column from PROW bits (set or clear per column).
; Clobbers everything except hQa/hQb/hP/hCoin/hRp.
WriteRowFromProw::
	ldh a, [hRow]
	and 7
	call BitmaskA
	ldh [hTmp3], a              ; dest bitmask
	ldh a, [hRow]
	srl a
	srl a
	srl a
	ldh [hTmp4], a              ; dest byte offset
	xor a
	ldh [hTmp1], a              ; q2
.q
	; X plane
	ldh a, [hTmp1]
	ld c, a
	srl a
	srl a
	srl a
	add LOW(PROW_X)
	ld l, a
	ld h, HIGH(TBUF)
	ld a, c
	and 7
	call BitmaskA
	and [hl]
	ldh [hTmp2], a              ; nonzero = bit set
	ld a, c
	MXBASE a
	ldh a, [hTmp4]
	add l
	ld l, a
	call .writebit
	; Z plane
	ldh a, [hTmp1]
	ld c, a
	srl a
	srl a
	srl a
	add LOW(PROW_Z)
	ld l, a
	ld h, HIGH(TBUF)
	ld a, c
	and 7
	call BitmaskA
	and [hl]
	ldh [hTmp2], a
	ld a, c
	MXBASE a
	set 4, h
	ldh a, [hTmp4]
	add l
	ld l, a
	call .writebit
	ldh a, [hTmp1]
	inc a
	ldh [hTmp1], a
	ld b, a
	ldh a, [hCfgN]
	cp b
	jr nz, .q
	ret
.writebit
	; [hl]: clear hTmp3 mask, set it if hTmp2 nonzero
	ldh a, [hTmp3]
	cpl
	and [hl]
	ld b, a
	ldh a, [hTmp2]
	and a
	jr z, .store
	ldh a, [hTmp3]
	or b
	ld b, a
.store
	ld a, b
	ld [hl], a
	ret

; Clear bit A (row index) in every column of both planes. Clobbers most.
ClearRowBitAllCols::
	ld b, a
	and 7
	call BitmaskA
	cpl
	ldh [hTmp3], a              ; ~mask
	ld a, b
	srl a
	srl a
	srl a
	ldh [hTmp4], a              ; byte offset
	xor a
	ldh [hTmp1], a              ; q2
.q
	ldh a, [hTmp1]
	MXBASE a
	ldh a, [hTmp4]
	add l
	ld l, a
	ldh a, [hTmp3]
	and [hl]
	ld [hl], a                  ; X plane
	set 4, h
	ldh a, [hTmp3]
	and [hl]
	ld [hl], a                  ; Z plane
	ldh a, [hTmp1]
	inc a
	ldh [hTmp1], a
	ld b, a
	ldh a, [hCfgN]
	cp b
	jr nz, .q
	ret

; --- generalized measurement (Phase 7; SPEC v0.7 "MPP") ---------------------

SECTION "MeasurePP", ROM0

; Measure the Pauli with qubit masks MPX_BUF/MPZ_BUF (sign 0). A = outcome.
; Same machinery as MeasureZ with the anti vector built by column XORs:
; anti bit i = parity(x_i & zm) ^ parity(z_i & xm), i.e. TBUF = XOR of
; X columns over MPZ bits and Z columns over MPX bits. Consumes the mask
; buffers and TBUF; clobbers like MeasureZ. Identity input is a caller bug
; (lands in ERR_DET_EMPTY via an all-zero anti vector).
MeasurePP::
	ld de, 9000                 ; anti build + scan + CBUF, worst-case bound
	call KCharge
	ld hl, TBUF
	ld b, 16
	xor a
.z
	ld [hli], a
	dec b
	jr nz, .z
	xor a
	ldh [hTmp1], a              ; q
.build
	ldh a, [hTmp1]
	ld c, a
	srl a
	srl a
	srl a
	add LOW(MPZ_BUF)
	ld l, a
	ld h, HIGH(MPZ_BUF)
	ld a, c
	and 7
	call BitmaskA
	and [hl]
	jr z, .nozb
	ld a, c
	call XorXcolIntoTbuf
.nozb
	ldh a, [hTmp1]
	ld c, a
	srl a
	srl a
	srl a
	add LOW(MPX_BUF)
	ld l, a
	ld h, HIGH(MPX_BUF)
	ld a, c
	and 7
	call BitmaskA
	and [hl]
	jr z, .noxb
	ld a, c
	call XorZcolIntoTbuf
.noxb
	ldh a, [hTmp1]
	inc a
	ldh [hTmp1], a
	ld b, a
	ldh a, [hCfgN]
	cp b
	jr nz, .build
	; scan the stabilizer region of the anti vector
	ldh a, [hScanOff]
	ld c, a                     ; byte index
	add LOW(TBUF)
	ld l, a
	ld h, HIGH(TBUF)
	ldh a, [hMaskLo]
	ld e, a
	ldh a, [hMaskHi]
	ld d, a
	ldh a, [hScanOff]
	add e
	ld e, a
	jr nc, :+
	inc d
:
	ldh a, [hScanCnt]
	ld b, a
.scan
	ld a, [de]
	and [hl]
	jr nz, .random
	inc l
	inc e
	inc c
	dec b
	jr nz, .scan
	; determinate: CBUF := TBUF & destab mask, hK = popcount
	ld hl, TBUF
	ldh a, [hMaskLo]
	add 16
	ld e, a
	ldh a, [hMaskHi]
	adc 0
	ld d, a
	ld c, LOW(CBUF)
	ld b, 8
	xor a
	ldh [hK], a
.cb
	ld a, [de]
	and [hl]
	push hl
	ld h, HIGH(CBUF)
	ld l, c
	ld [hl], a
	ld l, a
	ld h, HIGH(PopcntLUT)
	ld a, [hl]
	ld l, a
	ldh a, [hK]
	add l
	ldh [hK], a
	pop hl
	inc l
	inc e
	inc c
	dec b
	jr nz, .cb
	ldh a, [hK]
	and a
	jr nz, .det
	ld a, ERR_DET_EMPTY
	jp KernelError
.det
	jp MeasDetFromCbuf
.random
	ld l, a                     ; a = masked byte (nonzero)
	ld h, HIGH(LsbLUT)
	ld a, [hl]
	ld b, a
	ld a, c
	add a
	add a
	add a
	add b
	ldh [hP], a
	jp MppRandom

; A = qubit: TBUF ^= its X column (hCfgSlice bytes). Clobbers AF, B, DE, HL.
XorXcolIntoTbuf:
	MXBASE a
	jr XorColTbufCommon
XorZcolIntoTbuf:
	MXBASE a
	set 4, h
XorColTbufCommon:
	ld de, TBUF
	ldh a, [hCfgSlice]
	ld b, a
.x
	ld a, [de]
	xor [hl]
	ld [de], a
	inc l
	inc e
	dec b
	jr nz, .x
	ret

; Row hP of every column := the measured Pauli's bits (X plane from
; MPX_BUF, Z plane from MPZ_BUF). Precondition: ClearRowBitAllCols(hP) ran.
; Clobbers AF, BC, HL, hTmp1, hTmp3, hTmp4.
MppWriteRowP:
	ldh a, [hP]
	and 7
	call BitmaskA
	ldh [hTmp3], a              ; row bitmask
	ldh a, [hP]
	srl a
	srl a
	srl a
	ldh [hTmp4], a              ; row byte offset
	xor a
	ldh [hTmp1], a              ; q
.q
	ldh a, [hTmp1]
	ld c, a
	srl a
	srl a
	srl a
	add LOW(MPX_BUF)
	ld l, a
	ld h, HIGH(MPX_BUF)
	ld a, c
	and 7
	call BitmaskA
	and [hl]
	jr z, .nox
	ld a, c
	MXBASE a
	ldh a, [hTmp4]
	add l
	ld l, a
	ldh a, [hTmp3]
	or [hl]
	ld [hl], a
.nox
	ldh a, [hTmp1]
	ld c, a
	srl a
	srl a
	srl a
	add LOW(MPZ_BUF)
	ld l, a
	ld h, HIGH(MPZ_BUF)
	ld a, c
	and 7
	call BitmaskA
	and [hl]
	jr z, .noz
	ld a, c
	MXBASE a
	set 4, h
	ldh a, [hTmp4]
	add l
	ld l, a
	ldh a, [hTmp3]
	or [hl]
	ld [hl], a
.noz
	ldh a, [hTmp1]
	inc a
	ldh [hTmp1], a
	ld b, a
	ldh a, [hCfgN]
	cp b
	jr nz, .q
	ret

SECTION "Reset + error", ROM0

; Reset to |0>: measure, X-correct on 1 (MR semantics). hQa = qubit.
DoReset::
	call MeasureZ
	and a
	ret z
	jp DoPX

; Fatal kernel error: A = code. Parks with status ST_ERROR.
KernelError::
	ld b, a
	ld a, b
	ld [MBOX_ERROR], a
	ld a, ST_ERROR
	ld [MBOX_STATUS], a
.hang
	jr .hang
