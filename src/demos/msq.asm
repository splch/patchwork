; Phase 9: the magic-square demo (Mermin-Peres pseudo-telepathy) - the
; "nonlocality demo the codex promised": CHSH's 0.854 optimum is out of
; Clifford reach (the honesty card's caveat), but THIS game is won with
; probability 1 by stabilizer measurements alone, and the cartridge plays it
; on the real tableau every round.
;
; One 4-qubit tableau holds both parties: Alice = qubits (0,1), Bob = (2,3),
; Bell pairs (0,2) and (1,3), rebuilt per round. The referee (the gameplay
; RNG, seeded from the menu - the daily-seed panel pins it) draws row r and
; column c; Alice's three row cells are measured on (0,1) and Bob's three
; column cells on (2,3) with MeasurePP - real generalized measurements, no
; scripts. The sign tables (generated, machine-derived) say what each line's
; outcomes must XOR to; the demo TRIPWIRES the physics (KernelError ERR_MSQ
; on any violated line or a disagreeing intersection) rather than asserting
; it in prose. tools/msq/gen.py carries the no-classical-strategy
; certificate; tests/test_rom_phase9.py diffs outcomes against refsim.
;
; Context: entered from main.asm with MUSIC_BANK==MSQ_BANK (20) mapped, IME
; off, VRAM tiles already loaded by MenuDraw. hNoYield = 1 (MeasurePP's
; KCharge must never yield: there is no coroutine here). The mini-config is
; hand-built (n = 4 on the c0 gate tier; the CfgNTab path stays untouched).

INCLUDE "hardware.inc"
INCLUDE "shell/shell.inc"
INCLUDE "generated/msq_defs.inc"

; demo state (the MEAS_BUF page: kernel-testbench scratch, demo-owned here;
; addresses mirrored in romproto MSQ_*)
DEF wMsqRow    EQU $C400
DEF wMsqCol    EQU $C401
DEF wMsqA      EQU $C402        ; 3 B Alice row outcomes
DEF wMsqB      EQU $C405        ; 3 B Bob column outcomes
DEF wMsqWins   EQU $C408        ; 2 B LE
DEF wMsqRounds EQU $C40A
DEF wMsqJoy    EQU $C40B
DEF wMsqDec    EQU $C40C        ; 5 B wins digits (staged outside VBlank)
DEF wMsqDec3   EQU $C411        ; 3 B rounds digits

DEF MSQ_GRID_ROW EQU 4          ; grid rows 4/6/8, cols 7/9/11
DEF MSQ_GRID_COL EQU 7

SECTION "Msq demo", ROMX, BANK[20]

MsqRun::
	ld a, 1
	ldh [hNoYield], a
	; --- mini-config: n = 4 on the c0 slice tier ---
	xor a
	ldh [hCfg], a
	ldh [hScanOff], a           ; n >> 3 = 0
	ld a, 4
	ldh [hCfgN], a
	ld a, 1
	ldh [hCfgRowB], a
	ld a, 2
	ldh [hCfgSlice], a          ; ceil((2n+1)/8) = 2
	ldh [hScanCnt], a
	ld a, LOW(WMASKS)
	ldh [hMaskLo], a
	ld a, HIGH(WMASKS)
	ldh [hMaskHi], a
	ld hl, WMASKS               ; zero all 48 mask bytes
	ld b, 48
	xor a
.zm
	ld [hli], a
	dec b
	jr nz, .zm
	ld de, WMASKS + 16          ; destab: bits 0..3
	ld b, 0
	ld c, 4
	call MaskSetRange
	ld de, WMASKS               ; stab: bits 4..7
	ld b, 4
	ld c, 4
	call MaskSetRange
	ld de, WMASKS + 32          ; full: bits 0..7
	ld b, 0
	ld c, 8
	call MaskSetRange
	; --- referee RNG from the menu seed (panel-pinnable) ---
	ld a, [MBOX_SEED_LO]
	ld e, a
	ld a, [MBOX_SEED_HI]
	ld d, a
	call RngSeed
	xor a
	ld [wMsqWins], a
	ld [wMsqWins + 1], a
	ld [wMsqRounds], a
	ld a, $FF
	ld [wMsqJoy], a             ; A still held from the launch: no instant round
	; --- static screen (LCD off) ---
.wv
	ldh a, [rLY]
	cp SCREEN_HEIGHT_PX
	jr nz, .wv
	xor a
	ldh [rLCDC], a
	ld hl, $9800
	ld bc, 32 * 32
.mc
	xor a
	ld [hli], a
	dec bc
	ld a, b
	or c
	jr nz, .mc
	; CGB (Phase 9.5): the menu leaves styled attrs behind - reset, then
	; ink this screen deliberately (title brick, subtitle blue, stat rows
	; green, hint slate; the grid keeps the plain ink)
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
	ld a, MPAL_LOGO_Z
	call MsqInkRow
	ld hl, $9800 + 1 * 32
	ld a, MPAL_LOGO_X
	call MsqInkRow
	ld hl, $9800 + 10 * 32
	ld a, MPAL_ACT1
	call MsqInkRow
	ld hl, $9800 + 12 * 32
	ld a, MPAL_ACT1
	call MsqInkRow
	ld hl, $9800 + 14 * 32
	ld a, MPAL_ACT1
	call MsqInkRow
	ld hl, $9800 + 16 * 32
	ld a, MPAL_CARD
	call MsqInkRow
	xor a
	ldh [rVBK], a
.noattr
	ld hl, MsqTitle
	ld de, $9800 + 0 * 32
	ld b, 20
	call MsqPuts
	ld hl, MsqSub
	ld de, $9800 + 1 * 32
	ld b, 20
	call MsqPuts
	ld hl, MsqRowLbl
	ld de, $9800 + 10 * 32
	ld b, 20
	call MsqPuts
	ld hl, MsqScore
	ld de, $9800 + 12 * 32
	ld b, 20
	call MsqPuts
	ld hl, MsqClass
	ld de, $9800 + 14 * 32
	ld b, 20
	call MsqPuts
	ld hl, MsqHint
	ld de, $9800 + 16 * 32
	ld b, 20
	call MsqPuts
	call MsqGridDots            ; the empty 3x3 grid
	ld a, LCDC_ENABLE | LCDC_BLOCK01 | LCDC_BG_9800 | LCDC_BG
	ldh [rLCDC], a
	; --- input loop ---
.poll
	call MusService             ; the menu theme keeps playing here
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
	ld a, [wMsqJoy]
	cpl
	and b
	ld c, a
	ld a, b
	ld [wMsqJoy], a
	bit JOY_B, c
	ret nz                      ; back to the menu (the caller redraws)
	bit JOY_A, c
	jr z, .poll
	call MsqRound
	jr .poll

; --- one round -----------------------------------------------------------------

MsqRound:
	ld a, [wMsqRounds]
	inc a
	jr z, :+                    ; saturate the display counter
	ld [wMsqRounds], a
:
	call Uniform3
	ld [wMsqRow], a
	call Uniform3
	ld [wMsqCol], a
	; fresh state + the two ebits: H 0, CX 0->2, H 1, CX 1->3
	call TableauInit
	xor a
	ldh [hQa], a
	call DoH
	xor a
	ldh [hQa], a
	ld a, 2
	ldh [hQb], a
	call DoCNOT
	ld a, 1
	ldh [hQa], a
	call DoH
	ld a, 1
	ldh [hQa], a
	ld a, 3
	ldh [hQb], a
	call DoCNOT
	; Alice: row r cells (r, 0..2) on qubits (0,1)
	ld c, 0                     ; j
.arow
	ld a, [wMsqRow]
	ld b, a
	add a
	add b                       ; r * 3
	add c                       ; + j = cell
	push bc
	ld hl, MsqAliceX
	ld de, MsqAliceZ
	call MsqMeasureCell
	pop bc
	ld b, a
	ld a, c
	add LOW(wMsqA)
	ld l, a
	ld h, HIGH(wMsqA)
	ld [hl], b
	inc c
	ld a, c
	cp 3
	jr nz, .arow
	; Bob: column c cells (0..2, c) on qubits (2,3)
	ld c, 0                     ; i
.bcol
	ld a, c
	ld b, a
	add a
	add b                       ; i * 3
	ld b, a
	ld a, [wMsqCol]
	add b                       ; + c = cell
	push bc
	ld hl, MsqBobX
	ld de, MsqBobZ
	call MsqMeasureCell
	pop bc
	ld b, a
	ld a, c
	add LOW(wMsqB)
	ld l, a
	ld h, HIGH(wMsqB)
	ld [hl], b
	inc c
	ld a, c
	cp 3
	jr nz, .bcol
	; --- the tripwires: line parities + the intersection ---
	ld a, [wMsqA]
	ld hl, wMsqA + 1
	xor [hl]
	inc hl
	xor [hl]
	ld b, a
	ld a, [wMsqRow]
	add LOW(MsqRowSign)
	ld l, a
	ld a, HIGH(MsqRowSign)
	adc 0
	ld h, a
	ld a, [hl]
	cp b
	jr nz, .violation
	ld a, [wMsqB]
	ld hl, wMsqB + 1
	xor [hl]
	inc hl
	xor [hl]
	ld b, a
	ld a, [wMsqCol]
	add LOW(MsqColSign)
	ld l, a
	ld a, HIGH(MsqColSign)
	adc 0
	ld h, a
	ld a, [hl]
	cp b
	jr nz, .violation
	ld a, [wMsqCol]             ; Alice's value at the shared cell...
	add LOW(wMsqA)
	ld l, a
	ld h, HIGH(wMsqA)
	ld b, [hl]
	ld a, [wMsqRow]             ; ...must equal Bob's
	add LOW(wMsqB)
	ld l, a
	ld h, HIGH(wMsqB)
	ld a, [hl]
	cp b
	jr nz, .violation
	; --- a win (they all are; that is the demo) ---
	ld a, [wMsqWins]
	add 1
	ld [wMsqWins], a
	ld a, [wMsqWins + 1]
	adc 0
	ld [wMsqWins + 1], a
	ld a, CDX_MSQ
	call CdxSet
	ld a, SFX_GOOD
	call SfxPlay
	; stage the decimal digits outside VBlank (Dec5Write loops too long)
	ld a, [wMsqWins]
	ld l, a
	ld a, [wMsqWins + 1]
	ld h, a
	ld de, wMsqDec
	call Dec5Write
	ld a, [wMsqRounds]
	call Bin2Dec3               ; -> wHudTmp (shell scratch: free here)
	ld a, [wHudTmp]
	ld [wMsqDec3], a
	ld a, [wHudTmp + 1]
	ld [wMsqDec3 + 1], a
	ld a, [wHudTmp + 2]
	ld [wMsqDec3 + 2], a
	jp MsqPaint
.violation
	ld a, ERR_MSQ               ; the certificate failed: that IS a kernel bug
	jp KernelError

; Measure one cell: A = cell index (0..8), HL = X mask table, DE = Z table.
; Loads MPX/MPZ (byte 0; the buffers are 8 B each, zero elsewhere) and runs
; the generalized measurement. Returns A = outcome. Clobbers everything.
MsqMeasureCell:
	push de
	push hl
	ld c, a
	ld hl, MPX_BUF              ; MPX + MPZ are contiguous 16 bytes
	ld b, 16
	xor a
.z
	ld [hli], a
	dec b
	jr nz, .z
	pop hl                      ; X table
	ld a, c
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hl]
	ld [MPX_BUF], a
	pop hl                      ; Z table (was DE)
	ld a, c
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hl]
	ld [MPZ_BUF], a
	jp MeasurePP                ; tail: A = outcome

; --- painting --------------------------------------------------------------------

; Reset the 3x3 grid to dots (LCD off at init).
MsqGridDots:
	ld b, 0                     ; r
.r
	ld c, 0                     ; c
.c
	push bc
	call MsqCellAddr
	ld a, [MsqDot]
	ld [de], a
	pop bc
	inc c
	ld a, c
	cp 3
	jr nz, .c
	inc b
	ld a, b
	cp 3
	jr nz, .r
	ret

; DE = $9800 + (MSQ_GRID_ROW + 2*B) * 32 + (MSQ_GRID_COL + 2*C).
MsqCellAddr:
	ld a, b
	add a                       ; 2r
	add MSQ_GRID_ROW
	ld l, a
	ld h, 0
	add hl, hl
	add hl, hl
	add hl, hl
	add hl, hl
	add hl, hl                  ; row * 32
	ld a, c
	add a
	add MSQ_GRID_COL
	add l
	ld l, a
	ld de, $9800
	add hl, de
	ld d, h
	ld e, l
	ret

; One VBlank paints the round: grid dots, the measured row/column values,
; the R/C labels, and the staged counters (~30 tile writes, well inside).
MsqPaint:
.wv
	ldh a, [rLY]
	cp SCREEN_HEIGHT_PX
	jr nz, .wv
	call MsqGridDots
	; Alice's row values at (row, j)
	ld c, 0
.av
	ld a, [wMsqRow]
	ld b, a
	push bc
	call MsqCellAddr
	ld a, c
	add LOW(wMsqA)
	ld l, a
	ld h, HIGH(wMsqA)
	ld a, [hl]
	call MsqValTile
	ld [de], a
	pop bc
	inc c
	ld a, c
	cp 3
	jr nz, .av
	; Bob's column values at (i, col)
	ld b, 0
.bv
	ld a, [wMsqCol]
	ld c, a
	push bc
	call MsqCellAddr
	ld a, b
	add LOW(wMsqB)
	ld l, a
	ld h, HIGH(wMsqB)
	ld a, [hl]
	call MsqValTile
	ld [de], a
	pop bc
	inc b
	ld a, b
	cp 3
	jr nz, .bv
	; labels: 1-based row/col digits (row 10 cols 4 and 12)
	ld a, [wMsqRow]
	add FONT_BASE + 1
	ld [$9800 + 10 * 32 + 4], a
	ld a, [wMsqCol]
	add FONT_BASE + 1
	ld [$9800 + 10 * 32 + 12], a
	; counters: WINS xxxxx (cols 5-9), RND xxx (cols 15-17) on row 12
	ld hl, wMsqDec
	ld de, $9800 + 12 * 32 + 5
	ld b, 5
	call MsqPuts
	ld hl, wMsqDec3
	ld de, $9800 + 12 * 32 + 15
	ld b, 3
	jp MsqPuts

; A = outcome (0/1) -> A = '+' or '-' tile.
MsqValTile:
	and a
	jr nz, .m
	ld a, [MsqPlus]
	ret
.m
	ld a, [MsqMinus]
	ret

; hl = text, de = dest, b = len (LCD off or VBlank).
MsqPuts:
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, MsqPuts
	ret

; Fill 20 attr cols at HL with A (caller holds VBK = 1). Clobbers B, HL.
MsqInkRow:
	ld b, 20
.f
	ld [hli], a
	dec b
	jr nz, .f
	ret

MsqTitle:  db "    MAGIC SQUARE    "
MsqSub:    db "  PSEUDO-TELEPATHY  "
MsqRowLbl: db "ROW      COL        "
MsqScore:  db "WINS 00000 RND 000  "
MsqClass:  db "CLASSICAL MAX 8 OF 9"
MsqHint:   db "A-PLAY ROUND  B-MENU"
MsqDot:    db "."
MsqPlus:   db "+"
MsqMinus:  db "-"
