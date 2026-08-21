; Circuit-stream executor: runs compiled instruction streams (ROM tables from
; tools/harness/gbtables.py, or harness-poked scripts in WRAM) with SPEC.md
; sampling order: instructions in stream order, targets left to right, one
; site per (noise instruction, target), pairs as single sites for DEPOLARIZE2.

INCLUDE "hardware.inc"
INCLUDE "kernel/kernel.inc"

; Shared with the Phase 2 engine executors (which run from ROM0 while an
; engine bank is mapped): config load, Pauli-with-cache, and the measurement
; cache itself stay in ROM0. The stream interpreter below moved to bank 6
; (the testbench bank) in Phase 6 for ROM0 relief: every caller (mailbox
; table/script/timing/rng paths) runs with bank 6 mapped, which also holds
; the circuit tables it reads.
SECTION "Executor shared", ROM0

; A = config id. Loads n from CfgNTab, derives every geometry field, and
; GENERATES the three 16-byte row masks into WMASKS (WRAM: readable under
; any mapped bank; Phase 7 - a config now costs one ROM0 byte, which is
; what makes the Act 2 config set affordable). Clobbers AF, BC, DE, HL.
SetConfig::
	cp N_CONFIGS
	jr c, .ok
	ld a, ERR_BAD_TABLE
	jp KernelError
.ok
	ldh [hCfg], a
	ld hl, CfgNTab
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hl]
	ldh [hCfgN], a
	add 7                       ; rowB = (n + 7) >> 3
	srl a
	srl a
	srl a
	ldh [hCfgRowB], a
	ldh a, [hCfgN]
	add a                       ; 2n (n <= 56: no carry)
	add 8                       ; slice = (2n + 1 + 7) >> 3
	srl a
	srl a
	srl a
	ldh [hCfgSlice], a
	ldh a, [hCfgN]
	srl a
	srl a
	srl a
	ldh [hScanOff], a           ; n >> 3
	ld b, a
	ldh a, [hCfgSlice]
	sub b
	ldh [hScanCnt], a
	ld a, LOW(WMASKS)
	ldh [hMaskLo], a
	ld a, HIGH(WMASKS)
	ldh [hMaskHi], a
	; zero all 48 mask bytes, then set the two bit ranges + OR into full
	ld hl, WMASKS
	ld b, 48
	xor a
.z
	ld [hli], a
	dec b
	jr nz, .z
	ld de, WMASKS + 16          ; destab: bits 0..n-1
	ld b, 0
	ldh a, [hCfgN]
	ld c, a
	call MaskSetRange
	ld de, WMASKS               ; stab: bits n..2n-1
	ldh a, [hCfgN]
	ld b, a
	ld c, a
	call MaskSetRange
	ld hl, WMASKS               ; full = stab | destab
	ld de, WMASKS + 16
	ld b, 16
.or
	ld a, [de]
	or [hl]
	ld c, a
	ld a, l
	add 32
	ld l, a                     ; WMASKS block spans $D4C0-$D4EF: same page
	ld [hl], c
	ld a, l
	sub 32
	ld l, a
	inc l
	inc e
	dec b
	jr nz, .or
	ret

; Set C bits starting at bit B in the 16-byte block at DE (page-local).
; Clobbers AF, BC, HL. Exported: the Phase 9 magic-square demo hand-builds
; its 4-qubit mini-config's masks with it.
MaskSetRange::
.bit
	ld a, b
	srl a
	srl a
	srl a
	add e
	ld l, a
	ld h, d
	ld a, b
	and 7
	call BitmaskA
	or [hl]
	ld [hl], a
	inc b
	dec c
	jr nz, .bit
	ret

; Apply Pauli code in A to hQa, invalidating its cache when code != 0.
ApplyPauliCached::
	and a
	ret z
	ldh [hTmp2], a
	ldh a, [hQa]
	call CacheInvalidate
	ldh a, [hTmp2]
	jp ApplyPauliCode

; A = qubit. Returns carry set + A = cached value if valid, else carry clear.
; Clobbers AF, BC, HL. (Hot per measurement: the qubit mask is looked up
; once inline and held in B rather than through two BitmaskA calls.)
CacheLookup::
	ld c, a
	and 7
	add LOW(BitmaskLUT)
	ld l, a
	ld h, HIGH(BitmaskLUT)
	ld b, [hl]                  ; b = 1 << (qubit & 7)
	ld a, c
	srl a
	srl a
	srl a
	add LOW(MVALID)
	ld l, a
	ld h, HIGH(MVALID)
	ld a, b
	and [hl]
	ret z                       ; invalid: carry clear (and inputs A=0)
	ld a, l
	add MVALUE - MVALID
	ld l, a
	ld a, b
	and [hl]
	jr z, .zero
	ld a, 1
	scf
	ret
.zero
	xor a
	scf
	ret

; B = qubit, C = value (0/1): mark cache valid with value. Clobbers AF, D, HL.
; (Hot per measurement: mask held in D, one inline LUT read.)
CacheStore::
	ld a, b
	and 7
	add LOW(BitmaskLUT)
	ld l, a
	ld h, HIGH(BitmaskLUT)
	ld d, [hl]                  ; d = 1 << (qubit & 7)
	ld a, b
	srl a
	srl a
	srl a
	add LOW(MVALID)
	ld l, a
	ld h, HIGH(MVALID)
	ld a, d
	or [hl]
	ld [hl], a                  ; valid bit set
	ld a, l
	add MVALUE - MVALID
	ld l, a
	ld a, c
	and a                       ; value? (flags survive the ld)
	ld a, d
	jr z, .clearval
	or [hl]
	ld [hl], a
	ret
.clearval
	cpl
	and [hl]
	ld [hl], a
	ret

; A = qubit: clear its cache-valid bit. Clobbers AF, BC, HL.
CacheInvalidate::
	ld c, a
	and 7
	add LOW(BitmaskLUT)
	ld l, a
	ld h, HIGH(BitmaskLUT)
	ld a, [hl]
	cpl
	ld b, a                     ; b = ~mask
	ld a, c
	srl a
	srl a
	srl a
	add LOW(MVALID)
	ld l, a
	ld h, HIGH(MVALID)
	ld a, [hl]
	and b
	ld [hl], a
	ret

SECTION "Testbench executor", ROMX, BANK[6]

; Per-run init: buffers, counters, RNG seed from the mailbox, |0^n>.
; Config must already be set. Clobbers everything.
RunInit::
	xor a
	ldh [hMeasLo], a
	ldh [hMeasHi], a
	ldh [hHerald], a
	ldh [hHeraldOv], a
	ldh [hGroup], a
	ld hl, MEAS_BUF
	ld b, MEAS_BUF_LEN
.clr
	xor a
	ld [hli], a
	dec b
	jr nz, .clr
	ld hl, MVALID
	ld b, 8
.clrv
	xor a
	ld [hli], a
	dec b
	jr nz, .clrv
	ld a, [MBOX_SEED_LO]
	ld e, a
	ld a, [MBOX_SEED_HI]
	ld d, a
	call RngSeed
	jp TableauInit

; A = table id. Runs one ROM circuit table. Clobbers everything.
RunTable::
	cp N_TABLES
	jr c, .ok
	ld a, ERR_BAD_TABLE
	jp KernelError
.ok
	add a                       ; id * 2
	ld hl, CircuitTableIndex
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hli]
	ld e, a
	ld a, [hl]
	ld d, a                     ; de -> table
	ld a, [de]                  ; config byte
	inc de
	push de
	call SetConfig
	call RunInit
	pop hl                      ; hl -> stream
	jr ExecLoop

; Runs the harness-poked script at SCRIPT_BUF ([config][stream]).
RunScript::
	ld hl, SCRIPT_BUF
	ld a, [hli]
	push hl
	call SetConfig
	call RunInit
	pop hl
	; fall through
; HL -> instruction stream. Runs until OP_END. Clobbers everything.
ExecLoop::
	ld a, [hli]
	and a                       ; OP_END = 0
	ret z
	cp OP_CX
	jp z, .cx
	cp OP_H
	jp z, .h
	cp OP_M
	jp z, .m
	cp OP_R
	jp z, .r
	cp OP_XERR
	jp z, .xerr
	cp OP_DEP1
	jp z, .dep1
	cp OP_DEP2
	jp z, .dep2
	cp OP_ERASE
	jp z, .erase
	cp OP_TSTART
	jp z, .tstart
	cp OP_TSTOP
	jp z, .tstop
	cp OP_PX
	jp z, .px
	cp OP_PY
	jp z, .py
	cp OP_PZ
	jp z, .pz
	cp OP_S
	jp z, .s
	cp OP_MPP
	jp z, .mpp
	ld a, ERR_BAD_OPCODE
	jp KernelError

.cx
	ld a, [hli]
	ld b, a                     ; pair count
.cxloop
	ld a, [hli]
	ldh [hQa], a
	ld a, [hli]
	ldh [hQb], a
	push hl
	push bc
	ldh a, [hQa]
	call CacheInvalidate
	ldh a, [hQb]
	call CacheInvalidate
	call DoCNOT
	pop bc
	pop hl
	dec b
	jr nz, .cxloop
	jp ExecLoop

.h
	ld a, [hli]
	ld b, a
.hloop
	ld a, [hli]
	ldh [hQa], a
	push hl
	push bc
	call CacheInvalidate
	call DoH
	pop bc
	pop hl
	dec b
	jr nz, .hloop
	jp ExecLoop

.m
	ld a, [hli]
	ld b, a
.mloop
	ld a, [hli]
	ldh [hQa], a
	push hl
	push bc
	ldh a, [hQa]
	call CacheLookup            ; carry = valid, A = value
	jr c, .mhit
	call MeasureZ
.mhit
	ldh [hTmp3], a
	ldh a, [hQa]
	ld b, a
	ldh a, [hTmp3]
	ld c, a
	call CacheStore             ; B = qubit, C = value
	ldh a, [hTmp3]
	call AppendMeasBit
	pop bc
	pop hl
	dec b
	jr nz, .mloop
	jp ExecLoop

.r
	ld a, [hli]
	ld b, a
.rloop
	ld a, [hli]
	ldh [hQa], a
	push hl
	push bc
	ldh a, [hQa]
	call CacheLookup            ; carry = valid, A = value
	jr c, .rknown
	call MeasureZ
.rknown
	and a
	jr z, .rzero
	call DoPX                   ; flip |1> -> |0>
.rzero
	ldh a, [hQa]
	ld b, a
	ld c, 0
	call CacheStore             ; post-reset state is |0>
	pop bc
	pop hl
	dec b
	jr nz, .rloop
	jp ExecLoop

.xerr
	call LoadP16
	ld a, [hli]
	ld b, a
.xeloop
	ld a, [hli]
	ldh [hQa], a
	push hl
	push bc
	call Bern16
	jr nc, .xenohit
	ldh a, [hQa]
	call CacheInvalidate
	call DoPX
.xenohit
	pop bc
	pop hl
	dec b
	jr nz, .xeloop
	jp ExecLoop

.dep1
	call LoadP16
	ld a, [hli]
	ld b, a
.d1loop
	ld a, [hli]
	ldh [hQa], a
	push hl
	push bc
	call Bern16
	jr nc, .d1skip
	call Uniform3
	inc a                       ; 1=X, 2=Y, 3=Z
	ldh [hTmp1], a
	ldh a, [hQa]
	call CacheInvalidate
	ldh a, [hTmp1]
	call ApplyPauliCode
.d1skip
	pop bc
	pop hl
	dec b
	jr nz, .d1loop
	jp ExecLoop

.dep2
	call LoadP16
	ld a, [hli]
	ld b, a
.d2loop
	ld a, [hli]
	ldh [hTmp3], a              ; qubit a
	ld a, [hli]
	ldh [hTmp4], a              ; qubit b
	push hl
	push bc
	call Bern16
	jr nc, .d2skip
	call Uniform15
	inc a                       ; v+1 in 1..15: (pa<<2)|pb
	ldh [hTmp1], a
	ldh a, [hTmp3]
	ldh [hQa], a
	ldh a, [hTmp1]
	srl a
	srl a                       ; pa
	call ApplyPauliCached
	ldh a, [hTmp4]
	ldh [hQa], a
	ldh a, [hTmp1]
	and 3                       ; pb
	call ApplyPauliCached
.d2skip
	pop bc
	pop hl
	dec b
	jr nz, .d2loop
	jp ExecLoop

.erase
	call LoadP16
	ld a, [hli]
	ld b, a
.erloop
	ld a, [hli]
	ldh [hTmp3], a              ; qubit
	push hl
	push bc
	call Bern16
	jr nc, .erskip
	call Uniform4               ; 0=I, 1=X, 2=Y, 3=Z (I still heralds)
	ldh [hTmp2], a
	ldh a, [hTmp3]
	ldh [hTmp1], a
	call HeraldAppend
	ldh a, [hTmp3]
	ldh [hQa], a
	ldh a, [hTmp2]
	call ApplyPauliCached
.erskip
	pop bc
	pop hl
	dec b
	jr nz, .erloop
	ldh a, [hGroup]
	inc a
	ldh [hGroup], a
	jp ExecLoop

.tstart
	push hl
	call TimerStart
	pop hl
	jp ExecLoop

.tstop
	push hl
	ld c, TSLOT_TABLE
	call TimerStop
	pop hl
	jp ExecLoop

.px
	ld a, [hli]
	ld b, a
.pxloop
	ld a, [hli]
	ldh [hQa], a
	push hl
	push bc
	call CacheInvalidate
	call DoPX
	pop bc
	pop hl
	dec b
	jr nz, .pxloop
	jp ExecLoop

.py
	ld a, [hli]
	ld b, a
.pyloop
	ld a, [hli]
	ldh [hQa], a
	push hl
	push bc
	call CacheInvalidate
	call DoPY
	pop bc
	pop hl
	dec b
	jr nz, .pyloop
	jp ExecLoop

.pz
	ld a, [hli]
	ld b, a
.pzloop
	ld a, [hli]
	ldh [hQa], a
	push hl
	push bc
	call CacheInvalidate
	call DoPZ
	pop bc
	pop hl
	dec b
	jr nz, .pzloop
	jp ExecLoop

.s
	ld a, [hli]
	ld b, a
.sloop
	ld a, [hli]
	ldh [hQa], a
	push hl
	push bc
	call CacheInvalidate
	call DoS
	pop bc
	pop hl
	dec b
	jr nz, .sloop
	jp ExecLoop

.mpp
	; [xmask 8B][zmask 8B] -> MPX_BUF/MPZ_BUF (contiguous, page-local)
	ld de, MPX_BUF
	ld b, 16
.mppcp
	ld a, [hli]
	ld [de], a
	inc e
	dec b
	jr nz, .mppcp
	push hl
	; a generalized collapse can rewrite any cached qubit's Z row: drop the
	; whole measurement cache (MPPs are rare; correctness over speed)
	ld hl, MVALID
	ld b, 8
	xor a
.mppcl
	ld [hli], a
	dec b
	jr nz, .mppcl
	call MeasurePP
	call AppendMeasBit
	pop hl
	jp ExecLoop

; Read p16 (lo, hi) from the stream into hPlo/hPhi. HL advances.
LoadP16:
	ld a, [hli]
	ldh [hPlo], a
	ld a, [hli]
	ldh [hPhi], a
	ret

; Append measurement outcome (A = 0/1) to MEAS_BUF; buffer is pre-cleared so
; only set bits are written. Clobbers AF, BC, DE, HL.
AppendMeasBit::
	ld c, a
	ldh a, [hMeasLo]
	ld e, a
	ldh a, [hMeasHi]
	ld d, a
	; byte index = (pos >> 3) with pos < 512
	ld a, e
	srl a
	srl a
	srl a
	bit 0, d
	jr z, :+
	or $20
:
	ld l, a
	ld h, HIGH(MEAS_BUF)        ; MEAS_BUF is $C400 (LOW = 0)
	ld a, e
	and 7
	call BitmaskA
	ld b, a
	ld a, c
	and a
	jr z, .count
	ld a, [hl]
	or b
	ld [hl], a
.count
	ldh a, [hMeasLo]
	inc a
	ldh [hMeasLo], a
	ret nz
	ldh a, [hMeasHi]
	inc a
	ldh [hMeasHi], a
	ret

; Herald log append: hTmp1 = qubit, hTmp2 = pauli code. Clobbers AF, C, HL.
HeraldAppend::
	ldh a, [hHerald]
	cp HERALD_MAX
	jr c, .store
	ld a, 1
	ldh [hHeraldOv], a
	jr .count
.store
	ldh a, [hHerald]
	ld c, a
	add a                       ; * 3 = *2 + *1
	add c
	add LOW(HERALD_BUF)         ; $80 + max 117 = $F7: no carry
	ld l, a
	ld h, HIGH(HERALD_BUF)
	ldh a, [hGroup]
	ld [hli], a
	ldh a, [hTmp1]
	ld [hli], a
	ldh a, [hTmp2]
	ld [hli], a
.count
	ldh a, [hHerald]
	inc a
	ldh [hHerald], a
	ret

; CMD_RNG_DUMP: seed from mailbox, write [MBOX_RNG_COUNT] stream bytes
; (1..255; 0 means 256) to MEAS_BUF onward. Clobbers everything.
; Reads no circuit tables, so it lives in bank 1 with the other small
; testbench pieces (bank 6 is full of tables + the stream executor).
SECTION "Testbench rng dump", ROMX, BANK[1]

RunRngDump::
	xor a
	ldh [hMeasLo], a
	ldh [hMeasHi], a
	ldh [hHerald], a
	ldh [hHeraldOv], a
	ld a, [MBOX_SEED_LO]
	ld e, a
	ld a, [MBOX_SEED_HI]
	ld d, a
	call RngSeed
	ld a, [MBOX_RNG_COUNT]
	ld b, a
	ld hl, MEAS_BUF
.loop
	push bc
	push hl
	call RngByte
	pop hl
	pop bc
	ld [hli], a
	dec b
	jr nz, .loop
	ret
