; xorshift32 (13, 17, 5) - the gameplay RNG per tools/refsim/SPEC.md "RNG".
; State little-endian in hRngS0..3; the output of a step IS the new state
; (low byte first), so the state bytes double as the 4-byte output buffer,
; consumed [hRngS0] first with hRngCnt bytes remaining. Seeding:
; 0x5057_0000 | seed16, then 8 warm-up steps with output discarded.
;
; Byte identities used throughout (single rotate serves both):
;   a<<5 == (swap a, rlca) & $E0        a>>3 == (swap a, rlca) & $1F
; Update order inside a shift stage is DESCENDING so every r_k is computed
; from not-yet-modified source bytes.

INCLUDE "hardware.inc"
INCLUDE "kernel/kernel.inc"

SECTION "RNG", ROM0

; DE = seed16 (D = hi, E = lo). Clobbers AF, BC.
RngSeed::
	ld a, e
	ldh [hRngS0], a
	ld a, d
	ldh [hRngS1], a
	ld a, $57
	ldh [hRngS2], a
	ld a, $50
	ldh [hRngS3], a
	ld b, 8                     ; warm-up, output discarded
.warm
	push bc
	call RngStep
	pop bc
	dec b
	jr nz, .warm
	xor a
	ldh [hRngCnt], a            ; discard warm-up output
	ret

; One xorshift32 step; the stored state is the refilled output buffer
; (hRngCnt = 4). Clobbers AF, BC, DE.
; State held in registers for the whole step: b=s3, c=s2, d=s1, e=s0.
RngStep::
	ldh a, [hRngS3]
	ld b, a
	ldh a, [hRngS2]
	ld c, a
	ldh a, [hRngS1]
	ld d, a
	ldh a, [hRngS0]
	ld e, a
	; --- stage 1: x ^= x << 13 (targets s3, s2, s1; sources old s0..s2) ---
	ld a, c                     ; r3 = (s1>>3) | (s2<<5)
	swap a
	rlca
	and $E0
	ld h, a
	ld a, d
	swap a
	rlca
	and $1F
	or h
	xor b
	ld b, a                     ; s3 ^= r3
	ld a, d                     ; r2 = (s0>>3) | (s1<<5)
	swap a
	rlca
	and $E0
	ld h, a
	ld a, e
	swap a
	rlca
	and $1F
	or h
	xor c
	ld c, a                     ; s2 ^= r2
	ld a, e                     ; r1 = s0 << 5
	swap a
	rlca
	and $E0
	xor d
	ld d, a                     ; s1 ^= r1
	; --- stage 2: x ^= x >> 17 (targets s0, s1; sources s2, s3) ---
	ld a, b
	srl a                       ; a = s3>>1, carry = s3 bit 0
	ld h, a
	ld a, c
	rra                         ; a = (s2>>1) | (s3.0 << 7)
	xor e
	ld e, a                     ; s0 ^= r0
	ld a, h
	xor d
	ld d, a                     ; s1 ^= r1
	; --- stage 3: x ^= x << 5 (targets s3, s2, s1, s0 descending) ---
	ld a, b                     ; r3 = (s2>>3) | (s3<<5)
	swap a
	rlca
	and $E0
	ld h, a
	ld a, c
	swap a
	rlca
	and $1F
	or h
	xor b
	ld b, a
	ld a, c                     ; r2 = (s1>>3) | (s2<<5)
	swap a
	rlca
	and $E0
	ld h, a
	ld a, d
	swap a
	rlca
	and $1F
	or h
	xor c
	ld c, a
	ld a, d                     ; r1 = (s0>>3) | (s1<<5)
	swap a
	rlca
	and $E0
	ld h, a
	ld a, e
	swap a
	rlca
	and $1F
	or h
	xor d
	ld d, a
	ld a, e                     ; r0 = s0 << 5
	swap a
	rlca
	and $E0
	xor e
	ld e, a
	; --- write back the state; it doubles as the output buffer ---
	ld a, e
	ldh [hRngS0], a
	ld a, d
	ldh [hRngS1], a
	ld a, c
	ldh [hRngS2], a
	ld a, b
	ldh [hRngS3], a
	ld a, 4
	ldh [hRngCnt], a
	ret

; Next stream byte in A. Clobbers AF only.
RngByte::
	ldh a, [hRngCnt]
	and a
	jr nz, .have
	push bc
	push de
	push hl
	call RngStep
	pop hl
	pop de
	pop bc
	ld a, 4
.have
	dec a
	ldh [hRngCnt], a
	cp 3                        ; remaining 3 -> byte 0, 2 -> 1, 1 -> 2, 0 -> 3
	jr z, .b0
	cp 2
	jr z, .b1
	cp 1
	jr z, .b2
	ldh a, [hRngS3]
	ret
.b0
	ldh a, [hRngS0]
	ret
.b1
	ldh a, [hRngS1]
	ret
.b2
	ldh a, [hRngS2]
	ret

; Fair coin in A (byte & 1). Clobbers AF.
RngBit::
	call RngByte
	and 1
	ret

; Event with probability p16/65536, p16 in hPlo/hPhi. Returns CARRY on hit.
; p16 == 0 draws nothing. Clobbers AF, BC.
Bern16::
	ldh a, [hPlo]
	ld b, a
	ldh a, [hPhi]
	ld c, a
	or b
	ret z                       ; p16 == 0: no draw, carry clear
	call RngByte                ; a = b1
	cp c                        ; b1 vs hi
	ret c                       ; b1 < hi: hit
	ret nz                      ; b1 > hi: miss (carry clear)
	call RngByte                ; b1 == hi: a = b2
	cp b                        ; carry iff b2 < lo
	ret

; Uniform values (SPEC.md: masked byte, whole-byte redraw on rejection).
Uniform3::                      ; A = 0..2. Clobbers AF.
	call RngByte
	and 3
	cp 3
	jr z, Uniform3
	ret

Uniform15::                     ; A = 0..14. Clobbers AF.
	call RngByte
	and 15
	cp 15
	jr z, Uniform15
	ret

Uniform4::                      ; A = 0..3. Clobbers AF.
	call RngByte
	and 3
	ret
