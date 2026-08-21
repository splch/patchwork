; Phase 7.5/8.5 end-state autopilot for the Act 2/3 configs: decode the
; ACCUMULATED detector board (XOR of all consumed rounds' det masks - lies
; self-cancel except a final-round survivor) per side, at code capacity,
; with the config's own on-cart decoder:
;   LOOKUP (small codes): the bank-18 dense-index tables - refsim.lookup's
;     decode_guarded is the contract (guard fail = the oracle's None = the
;     decoder gives up: correction zeroed + distress flag).
;   BP (bb30/gb26): the bank-19 BP-lite core (bp.asm) on the blob side
;     tables - refsim.bp is the contract (never gives up; non-convergence
;     sets the distress flag, the last iteration's decisions still apply).
; Publishes the Act 1 autopilot's mailbox contract so the autopsy UI works
; unchanged: UF_CORR_X/Z + UF_APF (bit0 done, bit1 dead, bit2 distress).
; The verdict is per-tenant memory-Z: dead = OR over the k Z_L masks of
; parity((wCTrueX ^ UF_CORR_X) & ZL_i).
;
; Banking: AutopsyTick (bank 4) calls Ap23StepT (ROM0), which maps DEC_BANK
; (lookup) or GFX2_BANK (BP) for one bounded chunk and always restores
; GFX_BANK. End state only - the kernel is frozen, so the engine banks are
; not needed and the UF WRAM region is free for the BP working set.

INCLUDE "hardware.inc"
INCLUDE "shell/shell.inc"
INCLUDE "generated/act23dec_defs.inc"

; file-local state ($CFB0-$CFCF: between the UF vars and UF_CORR_X)
DEF wA23Phase EQU $CFB0         ; 0 acc, 1 side0, 2 bp0, 3 side1, 4 bp1,
                                ; 5 verdict, 8 done
DEF wA23R     EQU $CFB1         ; rounds to accumulate
DEF wA23Fail  EQU $CFB2         ; decoder distress (guard fail / no converge)
DEF wA23Dead  EQU $CFB3         ; verdict accumulator
DEF wA23Acc   EQU $CFB4         ; 4 B accumulated det mask (page-contained)
DEF wD23C     EQU $CFB8         ; lookup solve: header + cursors
DEF wD23Rank  EQU $CFB9
DEF wD23Cb    EQU $CFBA
DEF wD23Syn   EQU $CFBB         ; 2 B side-local syndrome
DEF wD23Idx   EQU $CFBD         ; 2 B dense index
DEF wD23Msk   EQU $CFBF         ; 2 B masks base (bank 18)
DEF wD23Dns   EQU $CFC1         ; 2 B dense base (bank 18)
DEF wD23Cor   EQU $CFC3         ; 2 B correction dest (WRAM)
DEF wD23Sg    EQU $CFC5         ; 2 B guard sigma scratch
DEF wA23Res   EQU $CFC7         ; 4 B residual (true ^ corr) for the verdict

SECTION "Act23 autopsy glue", ROM0

; Reset the end-state decode. Called from GameOver (any bank mapped).
Ap23Init::
	xor a
	ld [wA23Phase], a
	ld [wA23Fail], a
	ld [wA23Dead], a
	ld [UF_APF], a
	ld hl, UF_CORR_X
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hli], a                 ; UF_CORR_Z (contiguous)
	ld [hli], a
	ld [hli], a
	ld [hl], a
	ld a, [wCons]
	cp WDETLOG_MAX
	jr c, :+
	ld a, WDETLOG_MAX
:
	ld [wA23R], a
	ret

; One bounded chunk per frame from AutopsyTick (bank 4). Restores GFX_BANK.
Ap23StepT::
	ld a, [wA23Phase]
	and a
	jr z, .acc
	cp 1
	jr z, .side0
	cp 2
	jp z, .bp0
	cp 3
	jp z, .side1
	cp 4
	jp z, .bp1
	cp 5
	jp z, .verdict
	ret                         ; 8: done
.acc
	; accumulate: wA23Acc = XOR of the logged rounds (WDETLOG is WRAM)
	xor a
	ld hl, wA23Acc
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hl], a
	ld a, [wA23R]
	and a
	jr z, .accdone
	ld b, a
	ld hl, WDETLOG
.accr
	ld de, wA23Acc
	ld c, 4
.accb
	ld a, [de]
	xor [hl]
	ld [de], a
	inc hl
	inc de
	dec c
	jr nz, .accb
	dec b
	jr nz, .accr
.accdone
	ld a, 1
	ld [wA23Phase], a
	ret
.side0
	call A23TabEntry            ; a = type, de = side0, bc = side1 (bank 18)
	cp DEC_LOOKUP
	jr z, .lk0
	xor a                       ; blob side 0
	call A23BpBindT
	ld a, 2
	ld [wA23Phase], a
	ret
.lk0
	ld hl, UF_CORR_X
	call A23LookupT
	ld a, 3
	ld [wA23Phase], a
	ret
.bp0
	ld hl, UF_CORR_X
	call A23BpChunkT
	and a
	ret z
	ld a, 3
	ld [wA23Phase], a
	ret
.side1
	call A23TabEntry
	cp DEC_LOOKUP
	jr z, .lk1
	ld a, 1                     ; blob side 1
	call A23BpBindT
	ld a, 4
	ld [wA23Phase], a
	ret
.lk1
	ld d, b
	ld e, c
	ld hl, UF_CORR_Z
	call A23LookupT
	ld a, 5
	ld [wA23Phase], a
	ret
.bp1
	ld hl, UF_CORR_Z
	call A23BpChunkT
	and a
	ret z
	ld a, 5
	ld [wA23Phase], a
	ret
.verdict
	; residual = wCTrueX ^ UF_CORR_X (unrolled: fixed addresses)
	ld a, [wCTrueX]
	ld hl, UF_CORR_X
	xor [hl]
	ld [wA23Res], a
	ld a, [wCTrueX + 1]
	ld hl, UF_CORR_X + 1
	xor [hl]
	ld [wA23Res + 1], a
	ld a, [wCTrueX + 2]
	ld hl, UF_CORR_X + 2
	xor [hl]
	ld [wA23Res + 2], a
	ld a, [wCTrueX + 3]
	ld hl, UF_CORR_X + 3
	xor [hl]
	ld [wA23Res + 3], a
	; dead = OR over tenants of parity(residual & ZL_i)
	xor a
	ld [wA23Dead], a
	ld a, [wK]
	ld b, a
	ld a, [wLZPtr]
	ld l, a
	ld a, [wLZPtr + 1]
	ld h, a
.tenant
	push bc
	ld de, wA23Res
	ld b, 4
	ld c, 0
.tb
	ld a, [de]
	inc de
	and [hl]
	inc hl
	xor c
	ld c, a
	dec b
	jr nz, .tb
	push hl
	ld l, c
	ld h, HIGH(PopcntLUT)
	ld a, [hl]
	pop hl
	and 1
	jr z, .t0
	ld [wA23Dead], a
.t0
	pop bc
	dec b
	jr nz, .tenant
	ld a, [wA23Dead]
	add a                       ; bit1 = dead
	ld b, a
	ld a, [wA23Fail]
	and a
	jr z, :+
	set 2, b                    ; bit2 = decoder distress
:
	ld a, b
	or 1                        ; bit0 = done
	ld [UF_APF], a
	ld a, 8
	ld [wA23Phase], a
	ret

; Per-config decoder dispatch row (Act23DecTab, ROM0, stride 5).
; Returns A = type, DE = side0 block, BC = side1 block. Clobbers HL, flags.
A23TabEntry:
	ld a, [MBOX_ENG_CFG]
	ld e, a
	ld d, 0
	ld l, a
	ld h, 0
	add hl, hl
	add hl, hl
	add hl, de                  ; cfg * 5
	ld de, Act23DecTab
	add hl, de
	ld a, [hli]
	push af
	ld a, [hli]
	ld e, a
	ld a, [hli]
	ld d, a
	ld a, [hli]
	ld c, a
	ld a, [hl]
	ld b, a
	pop af
	ret

; DE = side block (bank-18 address), HL = 4 B correction dest.
A23LookupT:
	ld a, DEC_BANK
	ld [$2000], a
	call Dec23Solve
	ld a, GFX_BANK
	ld [$2000], a
	ret

; A = blob side (0/1): bind + snapshot the accumulated syndrome + reset.
A23BpBindT:
	ld b, a
	ld a, GFX2_BANK
	ld [$2000], a
	ld a, b
	call Ap23BpBind
	ld a, GFX_BANK
	ld [$2000], a
	ret

; HL = correction dest. Runs BP chunks; on solve completion copies the
; decisions out and latches distress. Returns A = 1 when done.
A23BpChunkT:
	ld a, GFX2_BANK
	ld [$2000], a
	push hl
	call Ap23BpChunk
	pop hl
	and a
	jr z, .out
	call Ap23BpTake             ; bank 19 still mapped
	ld a, 1
.out
	ld b, a
	ld a, GFX_BANK
	ld [$2000], a
	ld a, b
	ret

; --------------------------------------------------- bank-19 BP adapters ---

SECTION "Act23 bp glue", ROMX, BANK[GFX2_BANK]

; A = side (0/1): bind the blob side table, project wA23Acc onto it, reset.
Ap23BpBind::
	ld b, a
	ld a, [wSidePtr]
	ld l, a
	ld a, [wSidePtr + 1]
	ld h, a
	ld a, b
	and a
	jr z, .bind
	; side 1 block = side 0 + 1 + 11*C0 (header + C proj + 4C masks +
	; 6C edges); 11C summed as C + 2C + 8C
	ld a, [hl]                  ; C0
	inc hl
	ld e, a
	ld d, 0
	add hl, de                  ; + C
	sla e
	rl d
	add hl, de                  ; + 2C
	sla e
	rl d
	sla e
	rl d
	add hl, de                  ; + 8C
.bind
	call BpBind
	ld de, wA23Acc
	call BpSnapSrc
	jp BpReset

; Run up to 4 BP sub-steps (<= ~10k M-cycles: the autopsy frame has no
; kernel slice but still keeps the zero-overrun contract; a full 2-side
; solve lands in ~90 frames). Returns A = 1 when the solve is complete.
Ap23BpChunk::
	ld b, 4
.c
	push bc
	call BpSubStep
	pop bc
	and a
	jr nz, .done
	dec b
	jr nz, .c
	xor a
	ret
.done
	ld a, 1
	ret

; HL = dest: copy the result decisions out; distress if never converged.
Ap23BpTake::
	ld de, wBpDec
	ld b, 4
.cp
	ld a, [de]
	inc de
	ld [hli], a
	dec b
	jr nz, .cp
	ld a, [wBpConv]
	and a
	ret nz
	ld a, 1
	ld [wA23Fail], a
	ret

; ------------------------------------------------------ bank-18 lookup ---

SECTION "Act23 lookup solve", ROMX, BANK[DEC_BANK]

; DE = side block (this bank): db C, rank, cb; proj[C]; ind[rank];
; C x 4 B check masks; 2^rank x cb dense corrections.
; HL = 4 B correction dest (WRAM). Input: wA23Acc. On guard fail the
; correction is zeroed and wA23Fail set (= refsim decode_guarded's None).
; Clobbers everything.
Dec23Solve::
	ld a, l
	ld [wD23Cor], a
	ld a, h
	ld [wD23Cor + 1], a
	ld a, [de]
	inc de
	ld [wD23C], a
	ld a, [de]
	inc de
	ld [wD23Rank], a
	ld a, [de]
	inc de
	ld [wD23Cb], a
	; --- project: wD23Syn = wA23Acc through proj (at DE) ---
	xor a
	ld [wD23Syn], a
	ld [wD23Syn + 1], a
	ld a, [wD23C]
	ld b, a
	ld c, 0
.pr
	ld a, [de]
	inc de
	push de
	push bc
	ld b, a
	and 7
	call BitmaskA
	ld e, a
	ld a, b
	srl a
	srl a
	srl a
	add LOW(wA23Acc)
	ld l, a
	ld h, HIGH(wA23Acc)
	ld a, [hl]
	and e
	pop bc
	jr z, .pr0
	ld a, c
	and 7
	call BitmaskA
	ld e, a
	ld a, c
	srl a
	srl a
	srl a
	add LOW(wD23Syn)
	ld l, a
	ld h, HIGH(wD23Syn)
	ld a, [hl]
	or e
	ld [hl], a
.pr0
	pop de
	inc c
	dec b
	jr nz, .pr
	; --- dense index: bit r = syn bit ind[r] (ind at DE) ---
	xor a
	ld [wD23Idx], a
	ld [wD23Idx + 1], a
	ld a, [wD23Rank]
	ld b, a
	ld c, 0
.ir
	ld a, [de]
	inc de
	push de
	push bc
	ld b, a
	and 7
	call BitmaskA
	ld e, a
	ld a, b
	srl a
	srl a
	srl a
	add LOW(wD23Syn)
	ld l, a
	ld h, HIGH(wD23Syn)
	ld a, [hl]
	and e
	pop bc
	jr z, .ir0
	ld a, c
	and 7
	call BitmaskA
	ld e, a
	ld a, c
	srl a
	srl a
	srl a
	add LOW(wD23Idx)
	ld l, a
	ld h, HIGH(wD23Idx)
	ld a, [hl]
	or e
	ld [hl], a
.ir0
	pop de
	inc c
	dec b
	jr nz, .ir
	; --- table geometry: masks = DE, dense = masks + 4C ---
	ld a, e
	ld [wD23Msk], a
	ld a, d
	ld [wD23Msk + 1], a
	ld a, [wD23C]
	ld l, a
	ld h, 0
	add hl, hl
	add hl, hl
	add hl, de
	ld a, l
	ld [wD23Dns], a
	ld a, h
	ld [wD23Dns + 1], a
	; --- fetch: corr = dense[idx * cb], zero-extended to 4 B ---
	ld a, [wD23Idx]
	ld l, a
	ld a, [wD23Idx + 1]
	ld h, a
	ld a, [wD23Cb]
	cp 3
	jr z, .m3
	cp 4
	jr z, .m4
	add hl, hl
	jr .madd
.m3
	ld d, h
	ld e, l
	add hl, hl
	add hl, de
	jr .madd
.m4
	add hl, hl
	add hl, hl
.madd
	ld a, [wD23Dns]
	ld e, a
	ld a, [wD23Dns + 1]
	ld d, a
	add hl, de
	ld a, [wD23Cor]
	ld e, a
	ld a, [wD23Cor + 1]
	ld d, a
	xor a
	ld [de], a
	inc de
	ld [de], a
	inc de
	ld [de], a
	inc de
	ld [de], a
	ld a, [wD23Cor]
	ld e, a
	ld a, [wD23Cor + 1]
	ld d, a
	ld a, [wD23Cb]
	ld b, a
.cp
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, .cp
	; --- guard: sigma(corr) must reproduce the side syndrome ---
	xor a
	ld [wD23Sg], a
	ld [wD23Sg + 1], a
	ld a, [wD23Msk]
	ld l, a
	ld a, [wD23Msk + 1]
	ld h, a
	ld a, [wD23C]
	ld b, a
	ld c, 0
.gc
	push bc
	ld a, [wD23Cor]
	ld e, a
	ld a, [wD23Cor + 1]
	ld d, a
	ld b, 4
	ld c, 0
.gb
	ld a, [de]
	inc de
	and [hl]
	inc hl
	xor c
	ld c, a
	dec b
	jr nz, .gb
	push hl
	ld l, c
	ld h, HIGH(PopcntLUT)
	ld a, [hl]
	pop hl
	pop bc
	and 1
	jr z, .gc0
	push hl
	ld a, c
	and 7
	call BitmaskA
	ld e, a
	ld a, c
	srl a
	srl a
	srl a
	add LOW(wD23Sg)
	ld l, a
	ld h, HIGH(wD23Sg)
	ld a, [hl]
	or e
	ld [hl], a
	pop hl
.gc0
	inc c
	dec b
	jr nz, .gc
	ld a, [wD23Sg]
	ld hl, wD23Syn
	cp [hl]
	jr nz, .fail
	ld a, [wD23Sg + 1]
	ld hl, wD23Syn + 1
	cp [hl]
	ret z
.fail
	ld a, [wD23Cor]
	ld l, a
	ld a, [wD23Cor + 1]
	ld h, a
	xor a
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hl], a
	ld a, 1
	ld [wA23Fail], a
	ret
