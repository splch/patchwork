; Phase 8.5 BP-lite: integer offset-min-sum belief propagation - a bit-for-bit
; transliteration of tools/refsim/bp.py (the normative oracle; its docstring
; is the contract). One side at code capacity, side tables from the gfx blob
; in WRAM (wSidePtr), so no banking is ever needed: the same core serves the
; live triage overlay (GF_TRIAGE levels, play state) and the end-state
; autopsy decode for the BP configs (act23.asm binds it to the accumulated
; detector board).
;
; Work is sliced: BpSubStep runs one bounded chunk (<= ~2k M-cycles) and the
; caller decides the cadence - the live overlay runs ONE chunk per frame on
; top of the engine, the end-state decoder loops chunks freely (kernel
; frozen). A full 16-iteration solve is ~11 chunks x 16; live latency is a
; couple of seconds by design (the codex sells the scanner sweep as such).
;
; Messages: BP_VC/BP_CV int8 edge arrays, check-major, edges per check in
; ascending qubit order (= the blob's edge lists = the oracle's enumeration).
; The check pass uses the standard two-min reduction (min1/min2/argmin +
; total sign product), which is exactly the reference's per-edge min over
; OTHERS; sign(0) = +1; offset 1 with floor 0; syndrome bit flips the base
; sign. The variable pass accumulates 16-bit totals (prior +8), clamps to
; [-127,127], decides total < 0, then writes back clamp(total - incoming).
; flips[q] counts hard-decision changes across ALL iterations; the result
; is the FIRST syndrome-reproducing iteration's decisions, else the last's.

INCLUDE "hardware.inc"
INCLUDE "shell/shell.inc"

DEF BP_PRIOR EQU 8
DEF BP_ITERS EQU 16
DEF BP_CHUNK EQU 6              ; checks per sub-step chunk

SECTION "BP lite", ROMX, BANK[GFX2_BANK]

; ---------------------------------------------------------------- binding ---

; HL = side block in the WRAM blob: db C; C proj bytes; C x 4 B masks;
; C x (db w, q0..q4 $FF-pad). Caches C + the three table base pointers.
; Clobbers AF, BC, HL.
BpBind::
	ld a, [hli]
	ld [wBpC], a
	ld a, l
	ld [wBpPProj], a
	ld a, h
	ld [wBpPProj + 1], a
	ld a, [wBpC]
	ld c, a
	ld b, 0
	add hl, bc                  ; + C: masks
	ld a, l
	ld [wBpPMask], a
	ld a, h
	ld [wBpPMask + 1], a
	add hl, bc                  ; + 4C: edges
	add hl, bc
	add hl, bc
	add hl, bc
	ld a, l
	ld [wBpPEdge], a
	ld a, h
	ld [wBpPEdge + 1], a
	ret

; Build wBpSyn (side-local, bit i = side check i) from a 4 B PAGE-CONTAINED
; global check bitmask at DE, through the bound proj table. The live overlay
; passes SH_LIVE (the residual board the player sees); the end-state decoder
; passes its accumulated detector mask. Clobbers everything.
BpSnapLive::
	ld de, SH_LIVE
BpSnapSrc::
	xor a
	ld [wBpSyn], a
	ld [wBpSyn + 1], a
	ld a, [wBpPProj]
	ld l, a
	ld a, [wBpPProj + 1]
	ld h, a
	ld a, [wBpC]
	ld b, a
	ld c, 0                     ; side-local index
.chk
	ld a, [hli]                 ; global check index g
	push hl
	push bc
	push de
	ld b, a
	and 7
	call BitmaskA
	ld c, a
	ld a, b
	srl a
	srl a
	srl a
	add e
	ld l, a
	ld h, d
	ld a, [hl]
	and c
	pop de
	pop bc
	jr z, .quiet
	ld a, c
	and 7
	call BitmaskA
	push de
	ld e, a
	ld a, c
	srl a
	srl a
	srl a
	add LOW(wBpSyn)
	ld l, a
	ld h, HIGH(wBpSyn)
	ld a, [hl]
	or e
	ld [hl], a
	pop de
.quiet
	pop hl
	inc c
	dec b
	jr nz, .chk
	ret

; Fresh solve on the bound side + wBpSyn: vc = +PRIOR everywhere, flips /
; decisions / convergence cleared, iteration cursors reset. Clobbers all.
BpReset::
	ld hl, BP_VC
	ld b, 80
	ld a, BP_PRIOR
.vc
	ld [hli], a
	dec b
	jr nz, .vc
	ld hl, BP_FLIP
	ld b, 32
	xor a
.fl
	ld [hli], a
	dec b
	jr nz, .fl
	ld hl, wBpDec
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hl], a
	ld hl, wBpPrev
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hl], a
	ld hl, wBpConvD
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hl], a
	ld [wBpIter], a
	ld [wBpConv], a
	; fall through
; Reset the per-iteration cursors: sub-step 0, check 0, running pointers at
; their bases, syndrome shadow reloaded. Clobbers AF.
BpRunStart:
	xor a
	ld [wBpSub], a
	ld [wBpCk], a
	ld a, LOW(BP_VC)
	ld [wBpVcP], a
	ld a, HIGH(BP_VC)
	ld [wBpVcP + 1], a
	ld a, LOW(BP_CV)
	ld [wBpCvP], a
	ld a, HIGH(BP_CV)
	ld [wBpCvP + 1], a
	ld a, [wBpPEdge]
	ld [wBpEdgP], a
	ld a, [wBpPEdge + 1]
	ld [wBpEdgP + 1], a
	ld a, [wBpSyn]
	ld [wBpSynSh], a
	ld a, [wBpSyn + 1]
	ld [wBpSynSh + 1], a
	ret

; --------------------------------------------------------------- sub-step ---

; One bounded chunk of the current iteration. Returns A = 1 when the whole
; 16-iteration solve is complete (wBpDec = result decisions, BP_FLIP = flip
; counts, wBpConv = converged), else A = 0. Clobbers everything.
BpSubStep::
	ld a, [wBpSub]
	and a
	jp z, BpChkChunk
	cp 1
	jp z, BpVarAChunk
	cp 2
	jp z, BpDecide
	cp 3
	jp z, BpVarBChunk
	jp BpConverge

; sub 0: check pass, up to BP_CHUNK checks. Reads vc, writes cv.
BpChkChunk:
	ld b, BP_CHUNK
.check
	ld a, [wBpCk]
	ld hl, wBpC
	cp [hl]
	jp z, .passdone
	push bc
	; w from the edges table (qubit list unused in this pass)
	ld a, [wBpEdgP]
	ld l, a
	ld a, [wBpEdgP + 1]
	ld h, a
	ld a, [hl]
	ld [wBpW], a
	; advance the edges cursor to the next check entry (stride 6)
	ld bc, 6
	add hl, bc
	ld a, l
	ld [wBpEdgP], a
	ld a, h
	ld [wBpEdgP + 1], a
	; --- pass A: two-min + sign product over the check's vc bytes ---
	ld a, $80                   ; sentinel > any |int8| (CLAMP+1)
	ld [wBpMin1], a
	ld [wBpMin2], a
	xor a
	ld [wBpPosM], a
	ld [wBpSgn], a
	ld a, [wBpVcP]
	ld e, a
	ld a, [wBpVcP + 1]
	ld d, a
	ld a, [wBpW]
	ld b, a
	ld c, 0                     ; pos
.pa
	ld a, [de]
	inc de
	bit 7, a
	jr z, .amag
	ld l, a
	ld a, [wBpSgn]
	xor 1
	ld [wBpSgn], a
	ld a, l
	cpl
	inc a
.amag
	ld hl, wBpMin1
	cp [hl]
	jr nc, .amin2
	ld l, a                     ; new min1: demote old
	ld a, [wBpMin1]
	ld [wBpMin2], a
	ld a, l
	ld [wBpMin1], a
	ld a, c
	ld [wBpPosM], a
	jr .anext
.amin2
	ld hl, wBpMin2
	cp [hl]
	jr nc, .anext
	ld [wBpMin2], a
.anext
	inc c
	dec b
	jr nz, .pa
	; syndrome bit for this check: shift the shadow right, carry = bit
	ld hl, wBpSynSh + 1
	srl [hl]
	dec hl
	rr [hl]
	ld a, [wBpSgn]
	jr nc, :+
	xor 1
:
	ld [wBpSgn], a              ; base sign = product ^ syndrome bit
	; --- pass B: emit cv = sign * max(0, min - 1) per edge ---
	ld a, [wBpVcP]
	ld e, a
	ld a, [wBpVcP + 1]
	ld d, a
	ld a, [wBpCvP]
	ld l, a
	ld a, [wBpCvP + 1]
	ld h, a
	ld a, [wBpW]
	ld b, a
	ld c, 0
.pb
	ld a, [de]
	inc de
	and $80
	rlca                        ; a = sign(v) as 0/1 (sign(0) = +1)
	push hl
	ld hl, wBpSgn
	xor [hl]                    ; out sign bit
	ld l, a
	ld a, [wBpPosM]
	cp c
	ld a, [wBpMin1]
	jr nz, :+
	ld a, [wBpMin2]             ; the argmin edge sees the second minimum
:
	and a                       ; offset 1, floor 0
	jr z, :+
	dec a
:
	bit 0, l
	jr z, :+
	cpl
	inc a                       ; negate (0 stays 0)
:
	pop hl
	ld [hli], a
	inc c
	dec b
	jr nz, .pb
	; writeback: vc cursor += w (DE walked it), cv cursor = HL
	ld a, e
	ld [wBpVcP], a
	ld a, d
	ld [wBpVcP + 1], a
	ld a, l
	ld [wBpCvP], a
	ld a, h
	ld [wBpCvP + 1], a
	ld hl, wBpCk
	inc [hl]
	pop bc
	dec b
	jp nz, .check
	xor a
	ret
.passdone
	; enter varA: cursors back to base + totals = prior
	ld a, 1
	ld [wBpSub], a
	xor a
	ld [wBpCk], a
	ld a, LOW(BP_CV)
	ld [wBpCvP], a
	ld a, HIGH(BP_CV)
	ld [wBpCvP + 1], a
	ld a, [wBpPEdge]
	ld [wBpEdgP], a
	ld a, [wBpPEdge + 1]
	ld [wBpEdgP + 1], a
	ld hl, BP_TOT
	ld a, [wNData]
	ld b, a
.tot
	ld a, BP_PRIOR
	ld [hli], a
	xor a
	ld [hli], a
	dec b
	jr nz, .tot
	xor a
	ret

; sub 1: totals += sext(cv), edge walk, up to BP_CHUNK checks.
BpVarAChunk:
	ld b, BP_CHUNK
.check
	ld a, [wBpCk]
	ld hl, wBpC
	cp [hl]
	jr z, .passdone
	push bc
	ld a, [wBpEdgP]
	ld l, a
	ld a, [wBpEdgP + 1]
	ld h, a
	ld a, [wBpCvP]
	ld e, a
	ld a, [wBpCvP + 1]
	ld d, a
	ld a, [hli]
	ld b, a                     ; w
	ld c, a                     ; (kept: advance edges by 5 - w after)
.edge
	push bc
	ld a, [hli]                 ; q
	ld c, a
	ld a, [de]                  ; cv (int8)
	inc de
	push hl
	push de
	ld e, a
	ld d, 0
	bit 7, e
	jr z, :+
	dec d                       ; sign extend
:
	ld a, c
	add a
	add LOW(BP_TOT)             ; BP_TOT page-contained ($CF30 + 2n <= $CF6B)
	ld l, a
	ld h, HIGH(BP_TOT)
	ld a, [hl]
	add e
	ld [hli], a
	ld a, [hl]
	adc d
	ld [hl], a
	pop de
	pop hl
	pop bc
	dec b
	jr nz, .edge
	; edges entry stride 6: skip the pad (5 - w) plus nothing (w consumed)
	ld a, 5
	sub c
	ld c, a
	ld b, 0
	add hl, bc
	ld a, l
	ld [wBpEdgP], a
	ld a, h
	ld [wBpEdgP + 1], a
	ld a, e
	ld [wBpCvP], a
	ld a, d
	ld [wBpCvP + 1], a
	ld hl, wBpCk
	inc [hl]
	pop bc
	dec b
	jr nz, .check
	xor a
	ret
.passdone
	ld a, 2
	ld [wBpSub], a
	xor a
	ret

; sub 2: clamp totals -> T (stored back in the slot's low byte), build the
; decision mask, count flips, latch prev. One call (n <= 30).
BpDecide:
	xor a
	ld hl, wBpDec
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hl], a
	ld a, [wNData]
	ld b, a
	ld c, 0                     ; q
.q
	ld a, c
	add a
	add LOW(BP_TOT)
	ld l, a
	ld h, HIGH(BP_TOT)
	ld a, [hli]
	ld e, a
	ld d, [hl]
	push hl
	call BpClampDE
	pop hl
	dec hl
	ld [hl], a                  ; T[q] in the slot's low byte (varB reads it)
	bit 7, a
	jr z, .next
	push bc
	ld a, c
	and 7
	call BitmaskA
	ld d, a
	ld a, c
	srl a
	srl a
	srl a
	add LOW(wBpDec)
	ld l, a
	ld h, HIGH(wBpDec)
	ld a, [hl]
	or d
	ld [hl], a
	pop bc
.next
	inc c
	dec b
	jr nz, .q
	; flips += (dec ^ prev) bits; prev = dec
	ld a, [wNData]
	ld b, a
	ld c, 0
.f
	push bc
	ld a, c
	srl a
	srl a
	srl a
	ld e, a
	add LOW(wBpDec)
	ld l, a
	ld h, HIGH(wBpDec)
	ld d, [hl]
	ld a, e
	add LOW(wBpPrev)
	ld l, a
	ld a, [hl]
	xor d
	ld d, a
	ld a, c
	and 7
	call BitmaskA
	and d
	jr z, .f0
	ld a, c
	add LOW(BP_FLIP)            ; BP_FLIP page-contained
	ld l, a
	ld h, HIGH(BP_FLIP)
	inc [hl]
.f0
	pop bc
	inc c
	dec b
	jr nz, .f
	ld a, [wBpDec]
	ld [wBpPrev], a
	ld a, [wBpDec + 1]
	ld [wBpPrev + 1], a
	ld a, [wBpDec + 2]
	ld [wBpPrev + 2], a
	ld a, [wBpDec + 3]
	ld [wBpPrev + 3], a
	; enter varB: cursors back to base
	ld a, 3
	ld [wBpSub], a
	xor a
	ld [wBpCk], a
	ld a, LOW(BP_VC)
	ld [wBpVcP], a
	ld a, HIGH(BP_VC)
	ld [wBpVcP + 1], a
	ld a, LOW(BP_CV)
	ld [wBpCvP], a
	ld a, HIGH(BP_CV)
	ld [wBpCvP + 1], a
	ld a, [wBpPEdge]
	ld [wBpEdgP], a
	ld a, [wBpPEdge + 1]
	ld [wBpEdgP + 1], a
	xor a
	ret

; sub 3: vc = clamp(T[q] - cv), edge walk, up to BP_CHUNK checks.
BpVarBChunk:
	ld b, BP_CHUNK
.check
	ld a, [wBpCk]
	ld hl, wBpC
	cp [hl]
	jr z, .passdone
	push bc
	ld a, [wBpEdgP]
	ld l, a
	ld a, [wBpEdgP + 1]
	ld h, a
	ld a, [wBpCvP]
	ld e, a
	ld a, [wBpCvP + 1]
	ld d, a
	ld a, [hli]
	ld b, a                     ; w
	push af                     ; (w for the stride fix-up)
.edge
	ld a, [hli]                 ; q
	ld c, a
	ld a, [de]                  ; cv
	inc de
	push hl
	push de
	push bc
	ld e, a
	ld d, 0
	bit 7, e
	jr z, :+
	dec d
:
	ld a, c
	add a
	add LOW(BP_TOT)
	ld l, a
	ld h, HIGH(BP_TOT)
	ld b, [hl]                  ; T (clamped int8)
	ld a, b
	rla
	sbc a, a
	ld h, a                     ; sext(T) high
	ld a, b
	sub e
	ld l, a
	ld a, h
	sbc d
	ld d, a
	ld e, l
	call BpClampDE
	ld b, a
	ld a, [wBpVcP]
	ld l, a
	ld a, [wBpVcP + 1]
	ld h, a
	ld [hl], b
	inc hl
	ld a, l
	ld [wBpVcP], a
	ld a, h
	ld [wBpVcP + 1], a
	pop bc
	pop de
	pop hl
	dec b
	jr nz, .edge
	pop af                      ; w
	ld c, a
	ld a, 5
	sub c
	ld c, a
	ld b, 0
	add hl, bc
	ld a, l
	ld [wBpEdgP], a
	ld a, h
	ld [wBpEdgP + 1], a
	ld a, e
	ld [wBpCvP], a
	ld a, d
	ld [wBpCvP + 1], a
	ld hl, wBpCk
	inc [hl]
	pop bc
	dec b
	jr nz, .check
	xor a
	ret
.passdone
	ld a, 4
	ld [wBpSub], a
	xor a
	ret

; sub 4: first-convergence test, iteration close, loop or finish.
BpConverge:
	ld a, [wBpConv]
	and a
	jr nz, .iterend
	; sigma(dec): per side check, parity over 4 bytes of (dec & mask)
	xor a
	ld [wBpSynSh], a
	ld [wBpSynSh + 1], a
	ld a, [wBpPMask]
	ld l, a
	ld a, [wBpPMask + 1]
	ld h, a
	ld a, [wBpC]
	ld b, a
	ld c, 0
.sg
	push bc
	ld de, wBpDec
	ld b, 4
	ld c, 0
.sgb
	ld a, [de]
	inc de
	and [hl]
	inc hl
	xor c
	ld c, a
	dec b
	jr nz, .sgb
	push hl
	ld l, c
	ld h, HIGH(PopcntLUT)
	ld a, [hl]
	pop hl
	pop bc
	and 1
	jr z, .sg0
	push hl
	ld a, c
	and 7
	call BitmaskA
	ld e, a
	ld a, c
	srl a
	srl a
	srl a
	add LOW(wBpSynSh)
	ld l, a
	ld h, HIGH(wBpSynSh)
	ld a, [hl]
	or e
	ld [hl], a
	pop hl
.sg0
	inc c
	dec b
	jr nz, .sg
	ld a, [wBpSynSh]
	ld hl, wBpSyn
	cp [hl]
	jr nz, .iterend
	ld a, [wBpSynSh + 1]
	ld hl, wBpSyn + 1
	cp [hl]
	jr nz, .iterend
	ld a, 1
	ld [wBpConv], a
	ld a, [wBpDec]
	ld [wBpConvD], a
	ld a, [wBpDec + 1]
	ld [wBpConvD + 1], a
	ld a, [wBpDec + 2]
	ld [wBpConvD + 2], a
	ld a, [wBpDec + 3]
	ld [wBpConvD + 3], a
.iterend
	ld hl, wBpIter
	inc [hl]
	ld a, [hl]
	cp BP_ITERS
	jr nc, .solved
	call BpRunStart
	xor a
	ret
.solved
	; result = first-converged decisions if any, else the last iteration's
	ld a, [wBpConv]
	and a
	jr z, .keep
	ld a, [wBpConvD]
	ld [wBpDec], a
	ld a, [wBpConvD + 1]
	ld [wBpDec + 1], a
	ld a, [wBpConvD + 2]
	ld [wBpDec + 2], a
	ld a, [wBpConvD + 3]
	ld [wBpDec + 3], a
.keep
	ld a, 1
	ret

; Clamp int16 D:E to [-127, 127]. Returns A; preserves BC. Clobbers DE.
BpClampDE:
	bit 7, d
	jr nz, .neg
	ld a, d
	and a
	jr nz, .p
	ld a, e
	cp 128
	ret c
.p
	ld a, 127
	ret
.neg
	ld a, d
	inc a
	jr nz, .m
	ld a, e
	cp $81
	ret nc
.m
	ld a, $81                   ; -127
	ret

; -------------------------------------------------------------- live driver -

; One per-frame slice of the live triage scanner (GF_TRIAGE levels, play
; state, called from GameTickB). Snapshot-solve semantics: a solve runs on
; a frozen syndrome; wBpDirty only starts the NEXT solve, never restarts a
; running one - on a static board (the cash-out stall, where triage is
; read) the overlay settles to the oracle's oscillation mask. Clobbers all.
BpLiveStep::
	ld a, [wBpPhase]
	and a
	jr z, .idle
	cp 1
	jr z, .run
	; phase 2: reconcile the painted overlay toward wBpOsc, <= 4 cells/frame
	ld a, [wBpRecQ]
	ld c, a
	ld b, 4
.rec
	ld a, [wNData]
	cp c
	jr z, .recdone
	push bc
	ld a, c
	srl a
	srl a
	srl a
	ld e, a
	add LOW(wBpOsc)
	ld l, a
	ld h, HIGH(wBpOsc)
	ld d, [hl]
	ld a, e
	add LOW(wBpShown)
	ld l, a
	ld a, [hl]
	xor d
	ld d, a                     ; changed bits in q's byte
	ld a, c
	and 7
	call BitmaskA
	and d
	pop bc
	jr z, .recnext
	; flip the shown bit, then repaint with the standard precedence
	push bc
	ld a, c
	srl a
	srl a
	srl a
	add LOW(wBpShown)
	ld l, a
	ld h, HIGH(wBpShown)
	ld a, c
	and 7
	push hl
	call BitmaskA
	pop hl
	ld d, a
	ld a, [hl]
	xor d
	ld [hl], a
	ld a, c
	call RepaintDataQ
	pop bc
	dec b
	jr z, .recsave
.recnext
	inc c
	jr .rec
.recsave
	inc c
	ld a, c
	ld [wBpRecQ], a
	ret
.recdone
	xor a
	ld [wBpPhase], a
	ret
.idle
	ld a, [wBpDirty]
	and a
	ret z
	ld a, [wSidePtr]
	ld l, a
	ld a, [wSidePtr + 1]
	ld h, a
	or l
	ret z                       ; no side tables on this config: stay dark
	xor a
	ld [wBpDirty], a
	call BpBind                 ; side 0 (Z checks / X errors): memory basis
	call BpSnapLive
	call BpReset
	ld a, 1
	ld [wBpPhase], a
	ret
.run
	; a sub-step (~2.5k M) on top of a FULL kernel slice broke the frame
	; budget (measured: 1 overrun at the TRIAGE level); claim the light
	; kernel refill like consume frames do - the deficit carry keeps the
	; engine's average throughput honest
	ld a, 1
	ld [wDidWork], a
	call BpSubStep
	and a
	ret z
	; solve done: publish the oscillation mask (flips >= 2), start reconcile
	xor a
	ld [wBpOsc], a
	ld [wBpOsc + 1], a
	ld [wBpOsc + 2], a
	ld [wBpOsc + 3], a
	ld a, [wNData]
	ld b, a
	ld c, 0
.osc
	ld a, c
	add LOW(BP_FLIP)
	ld l, a
	ld h, HIGH(BP_FLIP)
	ld a, [hl]
	cp 2
	jr c, .osc0
	push bc
	ld a, c
	and 7
	call BitmaskA
	ld d, a
	ld a, c
	srl a
	srl a
	srl a
	add LOW(wBpOsc)
	ld l, a
	ld h, HIGH(wBpOsc)
	ld a, [hl]
	or d
	ld [hl], a
	pop bc
.osc0
	inc c
	dec b
	jr nz, .osc
	xor a
	ld [wBpRecQ], a
	ld a, 2
	ld [wBpPhase], a
	ret

; Kill the overlay: clear the target mask and repaint every currently-shown
; cell (the oscillating sets are small - trapping-set sized - so the dirty
; ring absorbs this one-shot). Called from GameOverBanked. Clobbers all.
BpOverlayOff::
	xor a
	ld [wBpOsc], a
	ld [wBpOsc + 1], a
	ld [wBpOsc + 2], a
	ld [wBpOsc + 3], a
	ld a, [wNData]
	ld b, a
	ld c, 0
.q
	push bc
	ld a, c
	srl a
	srl a
	srl a
	add LOW(wBpShown)
	ld l, a
	ld h, HIGH(wBpShown)
	ld a, c
	and 7
	push hl
	call BitmaskA
	pop hl
	ld d, a
	ld a, [hl]
	and d
	jr z, .q0
	ld a, [hl]
	xor d
	ld [hl], a
	ld a, c
	call RepaintDataQ
.q0
	pop bc
	inc c
	dec b
	jr nz, .q
	ret
