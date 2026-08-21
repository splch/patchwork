; Column-major bit-sliced CHP tableau - gate slices (SPEC.md "Tableau").
;
; X column for qubit a: XPLANE_BASE + a*16 ($C000 | a<<4)
; Z column:             ZPLANE_BASE + a*16 ($D000 | a<<4)
; Plane toggle: set/res 4 of the pointer high byte (2 M-cycles).
; Phase vector: hRvec in HRAM, accessed with compile-time LDH offsets from
; the FOR-unrolled slices. Columns are 16-aligned so `inc l` never carries.
;
; Gate routines are instantiated per config (slice byte count): _c0 = d3
; (5 bytes), _c1 = d5 (13 bytes). Dispatch via Do* wrappers on hCfg.
; All gate routines: qubit(s) in hQa / hQb; clobber AF, BC, DE, HL.

INCLUDE "hardware.inc"
INCLUDE "kernel/kernel.inc"

; HL = XPLANE_BASE + \1*16 (\1 = register holding the qubit index)
MACRO XBASE_HL
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

; DE = XPLANE_BASE + \1*16
MACRO XBASE_DE
	push hl
	XBASE_HL \1
	ld d, h
	ld e, l
	pop hl
ENDM

SECTION "Tableau init", ROM0

; Initialize |0^n> for the current config. Clobbers everything.
TableauInit::
	; clear both plane regions (1 KiB each covers n <= 56 at stride 16)
	ld hl, XPLANE_BASE
	call .clear1k
	ld hl, ZPLANE_BASE
	call .clear1k
	ld c, LOW(RVEC)             ; clear R
	ld b, 16
.clrR
	xor a
	ldh [c], a
	inc c
	dec b
	jr nz, .clrR
	; diagonal: destab i = X_i (X column i, row i); stab i = Z_i (Z column i,
	; row n+i)
	ldh a, [hCfgN]
	ld b, a                     ; count
	ld c, 0                     ; qubit i
.diag
	; X plane: bit i of column i -> byte (i >> 3), mask (i & 7)
	ld a, c
	XBASE_HL a                  ; hl = X col i... (uses A; c preserved)
	ld a, c
	srl a
	srl a
	srl a
	add l
	ld l, a                     ; hl += i>>3 (no carry: <=6 within 16-block)
	ld a, c
	and 7
	call BitmaskA               ; a = 1 << (i & 7)
	or [hl]
	ld [hl], a
	; Z plane: bit (n+i) of column i
	ld a, c
	XBASE_HL a
	set 4, h                    ; -> Z plane
	ldh a, [hCfgN]
	add c                       ; a = n + i (<= 97, fits)
	push bc
	ld b, a
	srl a
	srl a
	srl a
	add l
	ld l, a
	ld a, b
	and 7
	call BitmaskA
	pop bc
	or [hl]
	ld [hl], a
	inc c
	dec b
	jr nz, .diag
	ret
.clear1k
	ld bc, 1024
.clrloop
	xor a
	ld [hli], a
	dec bc
	ld a, b
	or c
	jr nz, .clrloop
	ret

; A = 1 << (A & 7), via BitmaskLUT. Clobbers AF only.
BitmaskA::
	push hl
	and 7
	add LOW(BitmaskLUT)
	ld l, a
	ld h, HIGH(BitmaskLUT)
	ld a, [hl]
	pop hl
	ret

; --- gate slice macros ------------------------------------------------------
; \1 = slice byte count. Instantiated twice below.

MACRO M_CNOT                     ; hQa = control a, hQb = target b
	; 42 M-cycles/byte (was 50): X-plane work batched before one toggle to
	; the Z planes, so only 4 set/res per byte instead of 8. Phase term
	; computed from cached OLD values (c = Xa, b = Xb then ~(Xb^Za)).
	; \2_pre: entry with HL -> Xa and DE -> Xb already set (engine path).
	ldh a, [hQa]
	XBASE_HL a                  ; hl -> Xa
	ldh a, [hQb]
	XBASE_DE a                  ; de -> Xb
\2_pre::
	FOR J, \1
	ld a, [hl]                  ; Xa (old)
	ld c, a                     ; c = Xa
	ld a, [de]                  ; Xb (old)
	ld b, a                     ; b = Xb
	xor c
	ld [de], a                  ; Xb ^= Xa (write early; phase uses caches)
	set 4, h                    ; -> Za
	set 4, d                    ; -> Zb
	ld a, [hl]                  ; Za (old)
	xor b
	cpl
	ld b, a                     ; b = ~(Xb ^ Za)
	ld a, [de]                  ; Zb (old)
	and c
	and b                       ; a = t = Xa & Zb & ~(Xb ^ Za)
	ld b, a
	ldh a, [RVEC + J]
	xor b
	ldh [RVEC + J], a           ; R ^= t
	ld a, [de]                  ; Zb
	xor [hl]                    ; ^ Za
	ld [hl], a                  ; Za ^= Zb
	res 4, h
	res 4, d
	IF J < (\1) - 1
	inc l
	inc e
	ENDC
	ENDR
	ret
ENDM

MACRO M_H                        ; hQa = qubit; \2_pre: HL preset
	ldh a, [hQa]
	XBASE_HL a
\2_pre::
	FOR J, \1
	ld a, [hl]                  ; Xa
	ld b, a
	set 4, h
	ld a, [hl]                  ; Za
	ld c, a
	and b
	ld e, a                     ; e = t = Xa & Za
	ldh a, [RVEC + J]
	xor e
	ldh [RVEC + J], a
	ld [hl], b                  ; Za := Xa
	res 4, h
	ld [hl], c                  ; Xa := Za
	IF J < (\1) - 1
	inc l
	ENDC
	ENDR
	ret
ENDM

MACRO M_S                        ; hQa = qubit
	ldh a, [hQa]
	XBASE_HL a
	FOR J, \1
	ld a, [hl]                  ; Xa
	ld b, a
	set 4, h
	ld a, [hl]                  ; Za
	ld c, a
	and b
	ld e, a
	ldh a, [RVEC + J]
	xor e
	ldh [RVEC + J], a          ; R ^= Xa & Za
	ld a, c
	xor b
	ld [hl], a                  ; Za ^= Xa
	res 4, h
	IF J < (\1) - 1
	inc l
	ENDC
	ENDR
	ret
ENDM

MACRO M_PX                       ; Pauli X: R ^= Za
	ldh a, [hQa]
	XBASE_HL a
	set 4, h                    ; -> Za
	FOR J, \1
	ld a, [hl]
	ld b, a
	ldh a, [RVEC + J]
	xor b
	ldh [RVEC + J], a
	IF J < (\1) - 1
	inc l
	ENDC
	ENDR
	ret
ENDM

MACRO M_PZ                       ; Pauli Z: R ^= Xa
	ldh a, [hQa]
	XBASE_HL a
	FOR J, \1
	ld a, [hl]
	ld b, a
	ldh a, [RVEC + J]
	xor b
	ldh [RVEC + J], a
	IF J < (\1) - 1
	inc l
	ENDC
	ENDR
	ret
ENDM

MACRO M_PY                       ; Pauli Y: R ^= Xa ^ Za
	ldh a, [hQa]
	XBASE_HL a
	FOR J, \1
	ld a, [hl]                  ; Xa
	ld b, a
	set 4, h
	ld a, [hl]                  ; Za
	xor b
	ld b, a
	ldh a, [RVEC + J]
	xor b
	ldh [RVEC + J], a
	res 4, h
	IF J < (\1) - 1
	inc l
	ENDC
	ENDR
	ret
ENDM

SECTION "Gate slices", ROM0

CNot_c0:  M_CNOT 5, CNot_c0
CNot_c1:  M_CNOT 13, CNot_c1
H_c0:     M_H 5, H_c0
H_c1:     M_H 13, H_c1
S_c0:     M_S 5
S_c1:     M_S 13
PX_c0:    M_PX 5
PX_c1:    M_PX 13
PZ_c0:    M_PZ 5
PZ_c1:    M_PZ 13
PY_c0:    M_PY 5
PY_c1:    M_PY 13

; --- config dispatch (hCfg: 0 = d3, 1 = d5) ---
MACRO M_DISPATCH
	ldh a, [hCfg]
	and a
	jp z, \1
	jp \2
ENDM

DoCNOT::   M_DISPATCH CNot_c0, CNot_c1
DoH::      M_DISPATCH H_c0, H_c1
DoS::      M_DISPATCH S_c0, S_c1
DoPX::     M_DISPATCH PX_c0, PX_c1
DoPY::     M_DISPATCH PY_c0, PY_c1
DoPZ::     M_DISPATCH PZ_c0, PZ_c1

; Apply Pauli by 4-code in A (0=I, 1=X, 2=Y, 3=Z) to qubit hQa.
; Clobbers all.
ApplyPauliCode::
	and a
	ret z
	cp 1
	jp z, DoPX
	cp 2
	jp z, DoPY
	jp DoPZ
