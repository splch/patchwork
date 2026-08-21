; Phase 2 runtime: round producer (tableau or DEM mode) behind the coroutine,
; VBlank frame loop with a scripted consumer, detector ring (look-ahead
; queue), per-round pre-drawn fault buffer (PLAN.md ground rule 5), and the
; Pauli-frame 60 fps layer driven by the banked DEM tables.
;
; Round discipline (SPEC "Engine"):
;   round 0 = noiseless SYNC round: tableau mode executes the stream (the
;   X-check projections draw their coins inline); DEM mode burns the same
;   coin bytes. Faults start at round 1: PreDraw samples every site in SPEC
;   order into WFAULTS, XORs mechanism residuals into the true-error frame,
;   and (DEM mode) mechanism detector flips into ring slots t / t+1.
;   Tableau mode then executes the round stream, applying WFAULTS at SITES
;   markers, and emits detectors as consecutive-syndrome XOR. Player
;   corrections live in WCORR_* only - the engine never reads them, which is
;   what makes them commute past the look-ahead.

INCLUDE "hardware.inc"
INCLUDE "kernel/kernel.inc"
INCLUDE "generated/engine_defs.inc"

SECTION "Engine command", ROM0

; CMD_ENGINE entry (main context). Runs the frame loop until every round is
; produced and consumed, then publishes results. Clobbers everything.
EngineCommand::
	ld a, [MBOX_ENG_CFG]
	call SetConfig
	call EngMapBank             ; map this config's engine bank
	call EngineInit
	call KPrime
	; The init above (TableauInit clears 2 KiB) spans more than a frame, so
	; a VBlank is always pending here; clear it so the loop-top overrun
	; check counts only genuine slice overruns.
	xor a
	ldh [rIF], a
.frame
	; a pending VBlank here means the previous slice overran its frame;
	; wOvrGrace exempts exactly one check (see kernel.inc: the frame that
	; completed round 0 is CAL-beat work detected only after the reset)
	ldh a, [rIF]
	bit B_IF_VBLANK, a
	ld a, [wOvrGrace]           ; flags survive the load
	jr z, .nopend
	and a
	jr nz, .nopend              ; graced: CAL beat, not steady state
	ld hl, wOverruns
	inc [hl]
	ldh a, [rLY]
	ld [wDbgLY], a
	ld a, [wRound]
	ld [wDbgRound], a
.nopend
	xor a
	ld [wOvrGrace], a           ; the grace covers one loop-top check only
	ldh [rIF], a
	ld a, IE_VBLANK
	ldh [rIE], a
	halt
	nop
	xor a
	ldh [rIF], a                ; consume the wake flag, so the loop-top
	                            ; check only fires on a genuine overrun
	ld hl, wFrameLo
	inc [hl]
	jr nz, :+
	ld hl, wFrameHi
	inc [hl]
:
	call ConsumerStep
	; Budget refill with deficit carry: a block whose charge trips the yield
	; runs at the START of the next slice, so its overshoot must come out of
	; the new budget or that slice overruns the frame (the last G2 overrun
	; mechanism). Positive residual is NOT banked - a throttled/parked kernel
	; must not accumulate budget.
	ldh a, [hBudHi]
	bit 7, a
	jr z, .refill
	ldh a, [hBudLo]             ; negative residual: refill += residual
	ld c, a
	ldh a, [hBudHi]
	ld b, a
	ld a, [wBudLo]
	add c
	ldh [hBudLo], a
	ld a, [wBudHi]
	adc b
	ldh [hBudHi], a
	; Clamp at zero: KCharge detects exhaustion by unsigned borrow, so a
	; budget that STARTS negative reads as huge-unsigned and never yields
	; (unbounded slice). A deficit bigger than one refill (budget below the
	; largest single charge) must floor at 0 = one charged block per frame.
	bit 7, a
	jr z, .resumeK
	xor a
	ldh [hBudLo], a
	ldh [hBudHi], a
	jr .resumeK
.refill
	ld a, [wBudLo]
	ldh [hBudLo], a
	ld a, [wBudHi]
	ldh [hBudHi], a
.resumeK
	call KResume
	; debug: track the worst slice-end position (LY wraps at 154; treat
	; LY < 100 right after a slice as "ran into the next frame")
	ldh a, [rLY]
	ld hl, wDbgSlice
	cp [hl]
	jr c, :+
	ld [hl], a
	ld a, [wRound]
	ld [wDbgSliceR], a
	ldh a, [hSite]
	ld [wDbgSliceS], a
:
	ld a, [wEngDone]
	and a
	jp z, .frame
	ld a, [wProd]
	ld hl, wCons
	cp [hl]
	jp nz, .frame               ; let a paced consumer catch up
	ld a, [wProd]
	ld [MBOX_ENG_PROD], a
	ld a, [wFrameLo]
	ld [MBOX_ENG_FRAMES_LO], a
	ld a, [wFrameHi]
	ld [MBOX_ENG_FRAMES_HI], a
	ld a, [wOverruns]
	ld [MBOX_ENG_OVERRUNS], a
	xor a
	ldh [rIE], a
	ret

; Consume rounds: rate 0 = instantly; N = one round every N frames.
ConsumerStep:
	ld a, [wConsRate]
	and a
	jr nz, .paced
	ld a, [wProd]
	ld [wCons], a
	ret
.paced
	ld hl, wConsCntr
	inc [hl]
	cp [hl]                     ; a = rate
	ret nz
	xor a
	ld [wConsCntr], a
	ld a, [wCons]
	ld hl, wProd
	cp [hl]
	ret z
	inc a
	ld [wCons], a
	ret

; Map MBOX_ENG_CFG's engine-tables bank. EngBankTab holds (site bank, mech
; bank) pairs (Phase 8: Act 3 mech tables may live in their own bank);
; the SITE bank stays mapped for the run and PreDrawHit flips to the mech
; bank around its mechanism reads. Clobbers AF, HL.
EngMapBank::
	ld a, [MBOX_ENG_CFG]
	add a                       ; pair stride 2
	ld hl, EngBankTab
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hli]
	ld [wSiteBank], a
	ld [$2000], a
	ld a, [hl]
	ld [wMechBank], a
	ret

; Per-run init (main context; config + engine bank already set).
; Exported: the Phase 3 shell reuses it for its own runs/restarts.
EngineInit::
	ld hl, EngineCfgTab
	ld a, [MBOX_ENG_CFG]
	and a
	jr z, .havetab
	ld de, 14
.skiptab
	add hl, de
	dec a
	jr nz, .skiptab
.havetab
	ld de, wSitesLo
	ld b, 14                    ; 5 ptrs + nsites16 + r0coins + nerase (v0.8)
.cptab
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, .cptab
	ld a, [wNErase]
	ld b, a
	ld a, [wNSites]
	sub b
	ld [wNMain], a              ; bitmap-driven main-loop site count (16-bit)
	ld a, [wNSitesHi]
	sbc 0
	ld [wNMainHi], a
	ld a, [MBOX_ENG_MODE]
	ld [wEngMode], a
	ld a, [MBOX_ENG_ROUNDS]
	ld [wEngT], a
	ld a, [MBOX_ENG_P_LO]
	ld [wEngPlo], a
	ld a, [MBOX_ENG_P_HI]
	ld [wEngPhi], a
	ld a, [MBOX_ENG_Q_LO]
	ld [wEngQlo], a
	ld a, [MBOX_ENG_Q_HI]
	ld [wEngQhi], a
	ld a, [MBOX_ENG_E_LO]
	ld [wEngElo], a
	ld a, [MBOX_ENG_E_HI]
	ld [wEngEhi], a
	ld a, [MBOX_ENG_CONSRATE]
	ld [wConsRate], a
	ld a, [MBOX_ENG_BUD_LO]
	ld b, a
	ld [wBudLo], a
	ld a, [MBOX_ENG_BUD_HI]
	ld [wBudHi], a
	or b
	jr nz, :+
	ld a, $FF                   ; budget 0 = effectively unbounded
	ld [wBudLo], a
	ld a, $7F
	ld [wBudHi], a
:
	; clear ring + syndromes + frames + fault buffer header
	ld hl, ERING
	ld b, 64 + 8 + 8 + 8 + 2
	xor a
.clr1
	ld [hli], a
	dec b
	jr nz, .clr1
	; per-round delta rings (EFRAME 128 B + EHER 64 B, contiguous at $D400)
	ld hl, EFRAME
	ld b, 192
.clrf
	xor a
	ld [hli], a
	dec b
	jr nz, .clrf
	; stale cache-valid bits from a previous run poison round 0 (constant
	; outcomes, skipped collapses, shifted coin stream) - clear them
	ld hl, MVALID
	ld b, 8
.clrv
	xor a
	ld [hli], a
	dec b
	jr nz, .clrv
	; surgery hook: armed from the mailbox (WMPP masks are pre-poked and
	; survive init; 0 = no pending measurement this run)
	xor a
	ld [wEngMpp], a
	ld [wEngMppOut], a
	ld a, [MBOX_ENG_MPP_RND]
	ld [wEngMppRnd], a
	and a
	jr z, :+
	ld a, 1
	ld [wEngMpp], a
:
	xor a
	ld [wProd], a
	ld [wCons], a
	ld [wEngDone], a
	ld [wFrameLo], a
	ld [wFrameHi], a
	ld [wOverruns], a
	ld [wConsCntr], a
	ld [wRound], a
	ldh [hSynIdx], a
	ldh [hMeasLo], a
	ldh [hMeasHi], a
	ldh [hNoYield], a
	; debug capture block (stale values across runs once confused the
	; overrun isolation - clear per run)
	ld [wDbgLY], a
	ld [wDbgRound], a
	ld [wDbgSlice], a
	ld [wDbgSliceR], a
	ld [wDbgSliceS], a
	ld [wOvrGrace], a
	ld hl, EDETHIST
	ld b, 0                     ; 256 > 240: clear the whole history page
.clr2
	xor a
	ld [hli], a
	dec b
	jr nz, .clr2
	ld a, [MBOX_SEED_LO]
	ld e, a
	ld a, [MBOX_SEED_HI]
	ld d, a
	call RngSeed
	jp TableauInit

SECTION "Engine kernel", ROM0

; Kernel-context main: produce wEngT rounds, then park on KYield.
EngineMain::
.round
	; look-ahead throttle: never run further than RING_ROUNDS-2 ahead
.throttle
	ld a, [wProd]
	ld hl, wCons
	sub [hl]
	cp RING_ROUNDS - 2
	jr c, .go
	call KYield
	jr .throttle
.go
	; Phase 7 surgery hook: a pending MPP runs HERE - the round boundary
	; after round wEngMppRnd-1 completed, before round wEngMppRnd's noise is
	; drawn (matching refsim's mpp_after semantics). Kernel context: the
	; measurement self-charges and may yield. Tableau mode only.
	ld a, [wEngMpp]
	cp 1
	jr nz, .nompp
	ld a, [wEngMode]
	and a
	jr nz, .nompp
	ld a, [wEngMppRnd]
	ld hl, wRound
	cp [hl]
	jr nz, .nompp
	; stage masks + drop the whole measurement cache (a generalized collapse
	; can rewrite any cached qubit's Z row)
	ld hl, WMPP_X
	ld de, MPX_BUF
	ld b, 16
.mppcp
	ld a, [hli]
	ld [de], a
	inc e
	dec b
	jr nz, .mppcp
	ld hl, MVALID
	ld b, 8
	xor a
.mppcl
	ld [hli], a
	dec b
	jr nz, .mppcl
	call MeasurePP
	ld [wEngMppOut], a
	ld a, 2
	ld [wEngMpp], a
.nompp
	; Charge the fixed per-round bookkeeping (ring setup, mirror, stamps,
	; DEM round-0 coin burn) - uncharged before the G2 overrun fix.
	ld de, COST_ROUND_FIXED
	call KCharge
	; ring slot pointers for this round; clear the FUTURE slot
	ld a, [wRound]
	and ERING_MASK
	call RingAddr
	ld a, l
	ld [wRingT], a
	ld a, h
	ld [wRingT + 1], a
	ld a, [wRound]
	inc a
	and ERING_MASK
	call RingAddr
	ld a, l
	ld [wRingT1], a
	ld a, h
	ld [wRingT1 + 1], a
	xor a
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hl], a
	; EFRAME/EHER: current-round slot pointers + clear the FUTURE slots
	; (same ring discipline as ERING; both pages hold all 16 slots)
	ld a, [wRound]
	and ERING_MASK
	ld c, a
	add a
	add a                       ; slot * 4
	add LOW(EHER)
	ld [wHerT], a
	ld a, HIGH(EHER)
	ld [wHerT + 1], a
	ld a, c
	add a
	add a
	add a                       ; slot * 8 (LOW(EFRAME) = 0)
	ld [wFrmT], a
	ld a, HIGH(EFRAME)
	ld [wFrmT + 1], a
	ld a, [wRound]
	inc a
	and ERING_MASK
	ld c, a
	add a
	add a
	add LOW(EHER)
	ld l, a
	ld h, HIGH(EHER)
	xor a
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hl], a
	ld a, c
	add a
	add a
	add a
	ld l, a
	ld h, HIGH(EFRAME)
	xor a
	REPT 8
	ld [hli], a
	ENDR
	; round body
	ld a, [wRound]
	and a
	jr nz, .steady
	ld a, [wEngMode]
	and a
	jr z, .r0tab
	call BurnCoins              ; DEM: mirror the projection coin draws
	jr .fin
.r0tab
	xor a
	ld [WFAULT_CNT], a
	call EngineExecRound
	call SynLatch               ; establish the reference frame, no emit
	jr .fin
.steady
	; instrument round 1 with the TIMA rig (slot TSLOT_TABLE): real
	; M-cycles for one steady round, valid when the budget lets round 1
	; finish in one slice (harness uses a large budget when reading it)
	ld a, [wRound]
	cp 1
	jr nz, :+
	ld a, [MBOX_ENG_TIMER1]
	and a
	jr z, :+
	; suspend yielding for the timed round: the TIMA rig cannot count
	; across yields (halted frames run with IE = VBlank only)
	ld a, 1
	ldh [hNoYield], a
	call TimerStart
:
	call PreDraw
	ld a, [wEngMode]
	and a
	jr nz, .demdone
	call EngineExecRound
	call DetectorEmit
.demdone
	ld a, [wRound]
	cp 1
	jr nz, :+
	ld a, [MBOX_ENG_TIMER1]
	and a
	jr z, :+
	ld c, TSLOT_TABLE
	call TimerStop
	xor a
	ldh [hNoYield], a
:
	ld a, [wRound]
	call RingMirror
.fin
	; reset the overrun counter after round 0 so wOverruns reports steady
	; state only (the SYNC round's projection collapses are the documented
	; level-start beat and may overrun frames); arm the one-check grace so
	; the frame this reset runs in is excluded too (its pending flag is
	; only checked at the NEXT loop top, when wRound already reads 1)
	ld a, [wRound]
	and a
	jr nz, :+
	xor a
	ld [wOverruns], a
	ld a, 1
	ld [wOvrGrace], a
:
	ld a, [wRound]
	add LOW(ESTAMPS)
	ld l, a
	ld a, HIGH(ESTAMPS)
	adc 0
	ld h, a
	ld a, [wFrameLo]
	ld [hl], a
	ld a, [wRound]
	inc a
	ld [wProd], a
	ld [wRound], a
	ld hl, wEngT
	cp [hl]
	jp nz, .round
	ld a, 1
	ld [wEngDone], a
.park
	call KYield
	jr .park

; A = slot index -> HL = ERING + slot*4. Clobbers AF.
RingAddr:
	add a
	add a
	add LOW(ERING)
	ld l, a
	ld h, HIGH(ERING)
	ret

; A = round: copy ring slot (round & 15) into EDETHIST + (round mod 60)*4.
; Rolling window - identical to the old behavior for rounds < 60; the shell's
; look-back needs it to keep rolling past round 60. Clobbers AF, BC, DE, HL.
RingMirror:
	ld c, a
.mod
	cp EDETHIST_MAX
	jr c, .in
	sub EDETHIST_MAX
	jr .mod
.in
	ld b, a
	ld a, c
	and ERING_MASK
	call RingAddr
	ld d, h
	ld e, l
	ld a, b
	add a
	add a
	ld l, a
	ld h, HIGH(EDETHIST)        ; round*4 <= 236: same page
	ld b, 4
.cp
	ld a, [de]
	inc e
	ld [hli], a
	dec b
	jr nz, .cp
	ret

; DEM round 0: consume the same rng bytes the tableau projection would
; (one coin byte per X check). Clobbers AF, B.
BurnCoins:
	ld a, [wNXck]
	ld b, a
.burn
	push bc
	call RngByte
	pop bc
	dec b
	jr nz, .burn
	ret

; prev := cur, cur := 0, staging bit index reset. Clobbers AF, B, DE, HL.
SynLatch:
	ld hl, WSYN_CUR
	ld de, WSYN_PREV
	ld b, 4
.lat
	ld a, [hl]
	ld [de], a
	xor a
	ld [hli], a
	inc e
	dec b
	jr nz, .lat
	xor a
	ldh [hSynIdx], a
	ret

; ring[t] := cur ^ prev (4 bytes since Phase 8; slot was pre-cleared), then latch.
DetectorEmit:
	ld a, [wRingT]
	ld e, a
	ld a, [wRingT + 1]
	ld d, a
	ld hl, WSYN_CUR
	ld b, 4
.emit
	ld a, [hl]                  ; cur byte
	ld c, a
	ld a, l
	sub 4
	ld l, a                     ; -> prev byte
	ld a, [hl]
	xor c
	ld [de], a
	inc e
	ld a, l
	add 5                       ; next cur byte
	ld l, a
	dec b
	jr nz, .emit
	jr SynLatch

; Record measurement outcome (A = 0/1) into the syndrome staging buffer at
; bit hSynIdx (check order). Clobbers AF, BC, HL.
SynStage:
	ld c, a
	ldh a, [hSynIdx]
	ld b, a
	inc a
	ldh [hSynIdx], a
	ld a, c
	and a
	ret z
	ld a, b
	and 7
	add LOW(BitmaskLUT)
	ld l, a
	ld h, HIGH(BitmaskLUT)
	ld a, [hl]
	ld c, a
	ld a, b
	srl a
	srl a
	srl a
	add LOW(WSYN_CUR)
	ld l, a
	ld h, HIGH(WSYN_CUR)
	ld a, [hl]
	or c
	ld [hl], a
	ret

; --- pre-draw: sample the round's noise into WFAULTS (SPEC order) ----------

PreDraw:
	xor a
	ld [WFAULT_CNT], a
	ldh [hSite], a              ; base site of the current pclass byte
	ldh [hSiteHi], a            ; (16-bit since Phase 8: Act 3 rounds ~400 sites)
	; --- erasure pre-pass: sites 0..wNErase-1, class e16 (SPEC v0.4). The
	; pclass bitmap covers only the sites AFTER these, so the main loop below
	; starts at hSite = wNErase with bitmap bit 0. e16 == 0 draws NOTHING
	; (site numbering still advances) - bit-exact with the Phase 2 stream.
	ld a, [wNErase]
	and a
	jr z, .main
	ld l, a
	ld a, [wEngElo]
	ld h, a
	ld a, [wEngEhi]
	or h
	jr nz, .doerase
	ld a, l                     ; e16 == 0: skip the pass, advance numbering
	ldh [hSite], a
	jr .main
.doerase
	ld a, l
	ldh [hTmp4], a              ; site countdown (PreDrawHit leaves hTmp4 alone)
	ld de, COST_ERASE_PASS
	call KCharge
	ld a, [wEngEhi]
	ld b, a                     ; b = e16 hi
	ld a, [wEngElo]
	ld c, a                     ; c = e16 lo
.esite
	call RngByte                ; b1 (clobbers AF only)
	cp b
	jr c, .ehit                 ; b1 < hi: hit
	jr nz, .enext               ; b1 > hi: miss
	call RngByte                ; b1 == hi: b2 decides
	cp c
	jr nc, .enext
.ehit
	push bc
	call PreDrawHit             ; hSite = exact site; heralds + mech + delta
	pop bc
.enext
	ldh a, [hSite]
	inc a
	ldh [hSite], a
	ldh a, [hTmp4]
	dec a
	ldh [hTmp4], a
	jr nz, .esite
.main
	ld a, [wEngPhi]
	ld b, a                     ; b = gate-class p16 high byte
	ld a, [wEngQhi]
	ld d, a                     ; d = measurement-class q16 high byte
	ld a, [wPclsLo]
	ld l, a
	ld a, [wPclsHi]
	ld h, a
	; The group loop keeps the RNG stream position in C: the low address of
	; the next unread state byte (hRngS0..hRngS0+3; +4 = buffer empty).
	; Same lazy-refill rule as RngByte, so the byte sequence is identical;
	; the position is handed back to hRngCnt around every out-of-line
	; consumer (PreDrawSecond/PreDrawHit draw through RngByte).
	ldh a, [hRngCnt]
	cpl
	add LOW(hRngS0) + 5         ; c = hRngS0 + (4 - cnt)
	ld c, a
	; full pclass bytes = wNMain16 >> 3 (<= 255 for any site count <= 2047)
	ld a, [wNMainHi]
	ld e, a
	ld a, [wNMain]
	srl e
	rra
	srl e
	rra
	srl e
	rra
	ldh [hTmp3], a              ; number of full pclass bytes (8 sites each)
	and a
	jp z, .tail
	xor a
	ldh [hIterByte], a          ; charge countdown (free outside MeasureZ):
	                            ; 0 = charge now, so the FIRST group is
	                            ; covered (the old &3 rule left the first
	                            ; groups + wrap-gap uncharged: G2 defect)
.group
	ldh a, [hIterByte]
	and a
	jr nz, .nocharge
	ld de, COST_PREDRAW_CHUNK   ; KCharge preserves BC/HL
	call KCharge
	ld a, [wEngQhi]
	ld d, a                     ; DE was the charge argument: re-seat q16 hi
	ld a, 4
.nocharge
	dec a
	ldh [hIterByte], a
	ld a, [hli]
	ld e, a                     ; e = pclass byte for these 8 sites
	FOR K, 8
	ld a, c                     ; --- site base+K: inline stream byte ---
	cp LOW(hRngS0) + 4
	jr nz, .hv\@
	push bc
	push de
	push hl
	call RngStep
	pop hl
	pop de
	pop bc
	ld c, LOW(hRngS0)           ; fresh buffer (hRngCnt = 4)
.hv\@
	ldh a, [c]                  ; the stream byte b1
	inc c
	bit K, e                    ; class bit (A = b1 survives `bit`)
	jr z, .p\@
	cp d                        ; q-class site
	jr .j\@
.p\@
	cp b                        ; p-class site (the majority: falls through)
.j\@
	jr c, .hit\@                ; b1 < hi: hit
	jr z, .sec\@                ; b1 == hi: low byte decides
	jr .done\@
.sec\@
	ld a, LOW(hRngS0) + 4       ; PreDrawSecond draws via RngByte:
	sub c                       ; hand the position back to hRngCnt
	ldh [hRngCnt], a
	bit K, e
	jr nz, .sq\@
	ld a, [wEngPlo]
	jr .sl\@
.sq\@
	ld a, [wEngQlo]
.sl\@
	call PreDrawSecond          ; carry = hit
	push af                     ; carry is the verdict: keep it live
	ldh a, [hRngCnt]
	cpl
	add LOW(hRngS0) + 5
	ld c, a                     ; re-derive the position
	pop af
	jr nc, .done\@
	jr .hs\@                    ; hRngCnt already coherent
.hit\@
	ld a, LOW(hRngS0) + 4       ; PreDrawHit draws via RngByte (Uniform*)
	sub c
	ldh [hRngCnt], a
.hs\@
	ldh a, [hSite]
	add K
	ldh [hSite], a              ; exact site index for the hit machinery
	jr nc, .hs2\@
	ldh a, [hSiteHi]
	inc a
	ldh [hSiteHi], a
.hs2\@
	push bc
	push de
	push hl
	call PreDrawHit
	pop hl
	pop de
	pop bc
	ldh a, [hRngCnt]            ; PreDrawHit drew: re-derive the position
	cpl
	add LOW(hRngS0) + 5
	ld c, a
	ldh a, [hSite]
	sub K
	ldh [hSite], a              ; restore the byte-group base
	jr nc, .done\@
	ldh a, [hSiteHi]
	dec a
	ldh [hSiteHi], a
.done\@
	ENDR
	ldh a, [hSite]
	add 8
	ldh [hSite], a
	jr nc, :+
	ldh a, [hSiteHi]
	inc a
	ldh [hSiteHi], a
:
	ldh a, [hTmp3]
	dec a
	ldh [hTmp3], a
	jp nz, .group
	ld a, LOW(hRngS0) + 4       ; hand the position back before the tail
	sub c
	ldh [hRngCnt], a
.tail
	; remaining sites (< 8): simple per-site epilogue (RngByte-order, via
	; hRngCnt - coherent on both entries: the jp z path never moved C)
	ld a, [wEngQhi]
	ld c, a                     ; the tail keeps the old b/c = p/q hi contract
	ld a, [wNMain]
	and 7
	ret z
	ldh [hTmp3], a
	ld de, COST_PREDRAW_TAIL    ; tail was uncharged (G2 defect)
	call KCharge
	ld a, [hl]
	ld e, a
	ld d, 1
.tsite
	ldh a, [hRngCnt]
	and a
	jr nz, .thave
	push bc
	push de
	push hl
	call RngStep
	pop hl
	pop de
	pop bc
	ld a, 4
.thave
	dec a
	ldh [hRngCnt], a
	cp 3
	jr z, .tb0
	cp 2
	jr z, .tb1
	cp 1
	jr z, .tb2
	ldh a, [hRngS3]
	jr .tcp
.tb0
	ldh a, [hRngS0]
	jr .tcp
.tb1
	ldh a, [hRngS1]
	jr .tcp
.tb2
	ldh a, [hRngS2]
.tcp
	push af
	ld a, e
	and d
	jr nz, .tq
	pop af
	cp b
	jr .tj
.tq
	pop af
	cp c
.tj
	jr c, .thit
	jr z, .tsec
.tnext
	sla d
	ldh a, [hSite]
	inc a
	ldh [hSite], a
	jr nz, :+
	ldh a, [hSiteHi]
	inc a
	ldh [hSiteHi], a
:
	ldh a, [hTmp3]
	dec a
	ldh [hTmp3], a
	jr nz, .tsite
	ret
.tsec
	ld a, e
	and d
	jr nz, .tsq
	ld a, [wEngPlo]
	jr .tsl
.tsq
	ld a, [wEngQlo]
.tsl
	call PreDrawSecond
	jr c, .thit
	jr .tnext
.thit
	push bc
	push de
	push hl
	call PreDrawHit
	pop hl
	pop de
	pop bc
	jr .tnext

; Second-byte bernoulli decision: A = the class p16 low byte; draws b2 and
; returns CARRY on hit (b2 < lo). Clobbers AF, hTmp2.
PreDrawSecond:
	ldh [hTmp2], a
	call RngByte                ; b2 (clobbers AF only)
	push bc
	ld b, a
	ldh a, [hTmp2]
	ld c, a
	ld a, b
	cp c                        ; carry iff b2 < lo
	pop bc
	ret

; One sampled fault at site hSite: draw the Pauli choice, append to WFAULTS,
; and apply the mechanism (true frame + EFRAME round delta; DEM also ring
; flips; erasure also heralds into EHER). Clobbers AF/BC/DE/HL, hTmp1,
; hTmp2, hRow. Leaves hTmp3/hTmp4 alone (PreDraw loop counters).
PreDrawHit:
	ld de, COST_PREDRAW_HIT     ; per-hit work was uncharged (G2 defect)
	call KCharge
	ldh a, [hSite]
	ld l, a
	ldh a, [hSiteHi]
	ld h, a                     ; hl = site index (16-bit)
	add hl, hl                  ; *2
	ld d, h
	ld e, l
	add hl, hl                  ; *4
	add hl, de                  ; *6 (site records are 6 bytes)
	ld a, [wSitesLo]
	add l
	ld l, a
	ld a, [wSitesHi]
	adc h
	ld h, a                     ; hl -> site record
	ld a, [hli]                 ; kind
	ldh [hTmp1], a
	inc hl                      ; skip pclass
	ld a, [hli]                 ; qa (for the erase herald)
	ldh [hTmp2], a
	inc hl                      ; skip qb
	ldh a, [hTmp1]
	and a
	jr z, .c0
	cp 1
	jr z, .c1
	cp 3
	jr z, .c3
	push hl
	call Uniform15
	pop hl
	jr .have
.c3
	; erasure: uniform(4) incl. I; herald bit qa even for I (SPEC v0.4)
	push hl
	call Uniform4
	ldh [hRow], a
	ldh a, [hTmp2]
	call BitmaskA               ; a = 1 << (qa & 7); clobbers AF only
	ld c, a
	ldh a, [hTmp2]
	srl a
	srl a
	srl a
	ld l, a
	ld a, [wHerT]
	add l
	ld l, a                     ; slot*4 + qa>>3 <= $BF: same page
	ld a, [wHerT + 1]
	ld h, a
	ld a, [hl]
	or c
	ld [hl], a
	pop hl
	jr .stored
.c1
	push hl
	call Uniform3
	pop hl
	jr .have
.c0
	xor a
.have
	ldh [hRow], a               ; choice (hRow is free outside MeasureZ)
.stored
	ld a, [WFAULT_CNT]
	cp WFAULT_MAX
	jr c, :+
	ld a, ERR_FAULT_OVF
	jp KernelError
:
	push hl
	ld c, a
	inc a
	ld [WFAULT_CNT], a
	ld a, c
	add a
	add c                       ; entry index * 3 (16-bit sites since Phase 8)
	add LOW(WFAULTS)            ; $60 + 117 max: no carry
	ld l, a
	ld h, HIGH(WFAULTS)
	ldh a, [hSite]
	ld [hli], a
	ldh a, [hSiteHi]
	ld [hli], a
	ldh a, [hRow]
	ld [hl], a
	pop hl
	; mech id = EngineIds[idptr + choice*2]
	ld a, [hli]
	ld e, a
	ld a, [hl]
	ld d, a
	ldh a, [hRow]
	add a
	add e
	ld e, a
	jr nc, :+
	inc d
:
	ld a, [wIdsLo]
	add e
	ld e, a
	ld a, [wIdsHi]
	adc d
	ld d, a
	ld a, [de]
	ld l, a
	inc de
	ld a, [de]
	ld h, a                     ; hl = mech id
	; mech addr = wMechs + id*16 (Phase 8: 4-byte det masks, clean stride)
	add hl, hl
	add hl, hl
	add hl, hl
	add hl, hl                  ; hl = id*16
	ld a, [wMechsLo]
	add l
	ld l, a
	ld a, [wMechsHi]
	adc h
	ld h, a                     ; hl -> mech (det0 det1 fx fz)
	; the mech table may live in its own bank (Act 3); map it for the reads
	ld a, [wMechBank]
	ld [$2000], a
	push hl                     ; mech base for the EFRAME delta pass
	ld a, [wEngMode]
	and a
	jr z, .skipdet
	ld a, [wRingT]
	ld e, a
	ld a, [wRingT + 1]
	ld d, a
	ld b, 4
.d0
	ld a, [de]
	xor [hl]
	ld [de], a
	inc e
	inc hl
	dec b
	jr nz, .d0
	ld a, [wRingT1]
	ld e, a
	ld a, [wRingT1 + 1]
	ld d, a
	ld b, 4
.d1
	ld a, [de]
	xor [hl]
	ld [de], a
	inc e
	inc hl
	dec b
	jr nz, .d1
	jr .fx
.skipdet
	ld de, 8
	add hl, de
.fx
	ld de, WTRUE_FX
	ld b, 8                     ; fx (4) + fz (4), contiguous
.fr
	ld a, [de]
	xor [hl]
	ld [de], a
	inc e
	inc hl
	dec b
	jr nz, .fr
	; per-round delta: EFRAME slot ^= mech residual (SPEC v0.4; XOR of all
	; slots == WTRUE, asserted by the frame-delta differential test)
	pop hl
	ld de, 8
	add hl, de                  ; -> mech fx
	ld a, [wFrmT]
	ld e, a
	ld a, [wFrmT + 1]
	ld d, a
	ld b, 8
.fd
	ld a, [de]
	xor [hl]
	ld [de], a
	inc e                       ; slot*8 + 7 <= $7F: same page
	inc hl
	dec b
	jr nz, .fd
	; back to the site bank (the stream/site reads that follow need it)
	ld a, [wSiteBank]
	ld [$2000], a
	ret

; --- engine stream executors (per config, direct gate calls) ---------------

EngineExecRound:
	xor a
	ldh [hSite], a
	ldh [hSiteHi], a            ; PreDraw leaves this set past site 255 (Act 3)
	ldh [hFaultIdx], a
	ldh a, [hCfg]
	and a
	jp z, EngineExec_c0
	jp EngineExec_c1

; Advance the site counter by B stream-marker sites, applying pending
; WFAULTS entries that fall inside the window. Sites and the window limit
; are 16-bit (Phase 8); WFAULTS entries are (site lo, site hi, choice).
; Preserves HL. Clobbers AF/BC/DE + hLim* + hTmp2-4 + hRow + hQa.
SitesApply:
	ldh a, [hSite]
	add b
	ldh [hLimLo], a             ; window limit (16-bit; survives the fault
	ldh a, [hSiteHi]            ; application, unlike the hTmp scratch)
	adc 0
	ldh [hLimHi], a
.chk
	ld a, [WFAULT_CNT]
	ld c, a
	ldh a, [hFaultIdx]
	cp c
	jr z, .done
	ld c, a
	add a
	add c                       ; entry index * 3
	add LOW(WFAULTS)
	ld e, a
	ld d, HIGH(WFAULTS)         ; de -> (site lo, site hi, choice)
	inc de
	ld a, [de]                  ; entry site hi
	ld c, a
	ldh a, [hLimHi]
	cp c
	jr c, .done                 ; lim_hi < entry_hi: beyond this window
	jr nz, .apply               ; lim_hi > entry_hi: inside
	dec de
	ld a, [de]                  ; entry site lo
	ld c, a
	inc de
	ldh a, [hLimLo]
	cp c
	jr c, .done                 ; lim < entry: beyond
	jr z, .done                 ; entry == lim: beyond (window is [site, lim))
.apply
	push de
	ld de, COST_FAULT           ; fault application was uncharged (G2 defect)
	call KCharge
	pop de
	dec de                      ; -> site lo
	push hl
	ld a, [de]
	ld l, a
	inc de
	ld a, [de]
	ld h, a                     ; hl = entry site (16-bit)
	inc de
	ld a, [de]
	ldh [hRow], a               ; choice
	call ApplySiteFault
	pop hl
	ldh a, [hFaultIdx]
	inc a
	ldh [hFaultIdx], a
	jr .chk
.done
	ldh a, [hLimLo]
	ldh [hSite], a
	ldh a, [hLimHi]
	ldh [hSiteHi], a
	ret

; HL = site index (16-bit), hRow = choice: apply the fault Paulis to the
; tableau (cache-invalidating). Clobbers AF/BC/DE/HL, hTmp3, hTmp4, hQa, hTmp2.
ApplySiteFault:
	add hl, hl                  ; *2
	ld d, h
	ld e, l
	add hl, hl                  ; *4
	add hl, de                  ; *6
	ld a, [wSitesLo]
	add l
	ld l, a
	ld a, [wSitesHi]
	adc h
	ld h, a
	ld a, [hli]
	ldh [hTmp3], a              ; kind
	inc hl
	ld a, [hli]
	ldh [hQa], a                ; qa
	ld a, [hl]
	ldh [hTmp4], a              ; qb
	ldh a, [hTmp3]
	and a
	jr z, .xerr
	cp 1
	jr z, .dep1
	cp 3
	jr z, .erase
	ldh a, [hRow]               ; DEP2: v = choice + 1
	inc a
	ldh [hRow], a
	srl a
	srl a
	call ApplyPauliCached       ; first Pauli on qa
	ldh a, [hTmp4]
	ldh [hQa], a
	ldh a, [hRow]
	and 3
	jp ApplyPauliCached         ; second Pauli on qb
.dep1
	ldh a, [hRow]
	inc a
	jp ApplyPauliCached
.erase
	ldh a, [hRow]               ; erasure choice IS the 4-code (0 = I no-op)
	jp ApplyPauliCached
.xerr
	ld a, 1
	jp ApplyPauliCached

; \1 = config suffix, \2 = CNot label base, \3 = H label base.
; M/R loop counts live in hQb (MeasureZ clobbers hTmp1-4 but preserves hQb).
MACRO M_ENGEXEC
EngineExec_c\1:
	ld a, [wStreamLo]
	ld l, a
	ld a, [wStreamHi]
	ld h, a
.next\1
	ld a, [hli]
	ld e, a
	ld a, [hli]
	ld d, a
	call KCharge                ; may yield; all registers survive
	ld a, [hli]
	and a
	ret z                       ; OP_END: round complete
	cp OP_CX
	jr z, .cx\1
	cp OP_H
	jr z, .h\1
	cp OP_M
	jp z, .m\1
	cp OP_R
	jp z, .r\1
	cp OP_SITES
	jp z, .sites\1
	cp OP_CLRC
	jp z, .clrc\1
	ld a, ERR_BAD_OPCODE
	jp KernelError
.cx\1
	ld a, [hli]
	ldh [hTmp4], a              ; pair count (gates leave hTmps alone)
.cxl\1
	ld a, [hli]
	ld c, a
	ld a, [hli]
	ld b, a                     ; bc = control column base
	ld a, [hli]
	ld e, a
	ld a, [hli]
	ld d, a                     ; de = target column base
	push hl
	ld h, b
	ld l, c
	call \2_pre
	pop hl
	ldh a, [hTmp4]
	dec a
	ldh [hTmp4], a
	jr nz, .cxl\1
	jr .next\1
.h\1
	ld a, [hli]
	ldh [hTmp4], a
.hloop\1
	ld a, [hli]
	ld c, a
	ld a, [hli]
	ld b, a
	push hl
	ld h, b
	ld l, c
	call \3_pre
	pop hl
	ldh a, [hTmp4]
	dec a
	ldh [hTmp4], a
	jr nz, .hloop\1
	jr .next\1
.m\1
	ld a, [hli]
	ldh [hQb], a                ; count (survives MeasureZ)
.ml\1
	ld a, [hli]
	ldh [hQa], a
	push hl
	ldh a, [hQa]
	call CacheLookup
	jr c, .mhit\1
	call MeasureZ
.mhit\1
	ldh [hTmp3], a
	ldh a, [hQa]
	ld b, a
	ldh a, [hTmp3]
	ld c, a
	call CacheStore
	ldh a, [hTmp3]
	call SynStage
	pop hl
	ldh a, [hQb]
	dec a
	ldh [hQb], a
	jr nz, .ml\1
	jp .next\1
.r\1
	ld a, [hli]
	ldh [hQb], a
.rl\1
	ld a, [hli]
	ldh [hQa], a
	push hl
	ldh a, [hQa]
	call CacheLookup
	jr c, .rknown\1
	call MeasureZ
.rknown\1
	and a
	jr z, .rzero\1
	call DoPX
.rzero\1
	ldh a, [hQa]
	ld b, a
	ld c, 0
	call CacheStore
	pop hl
	ldh a, [hQb]
	dec a
	ldh [hQb], a
	jr nz, .rl\1
	jp .next\1
.sites\1
	ld a, [hli]
	ld b, a
	call SitesApply
	jp .next\1
.clrc\1
	push hl
	ld hl, MVALID
	ld b, 8
.cl\1
	xor a
	ld [hli], a
	dec b
	jr nz, .cl\1
	pop hl
	jp .next\1
ENDM

SECTION "Engine executors", ROM0

	M_ENGEXEC 0, CNot_c0, H_c0
	M_ENGEXEC 1, CNot_c1, H_c1
