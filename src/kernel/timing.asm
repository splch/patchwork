; TIMA-based cycle counter (PLAN.md sec 3.3 timing rig) + micro workloads.
;
; TAC = start | 262144 Hz -> one TIMA tick per 4 M-cycles; 8-bit overflows
; are counted by the ISR (26 M-cycles per overflow on the common path, +6
; when the 16-bit software counter carries). The harness converts raw
; (tima, ovf) to M-cycles and subtracts ISR overhead exactly.
;
; Slots (romproto.py TSLOT_*): raw 4-byte records [tima][ovfLo][ovfHi][0]
; at TIMING_BUF + slot*4.

INCLUDE "hardware.inc"
INCLUDE "kernel/kernel.inc"

SECTION "Timer vector", ROM0[$0050]
	jp TimerISR

SECTION "Timing rig", ROM0

TimerISR:
	push af
	ldh a, [hOvfLo]
	inc a
	ldh [hOvfLo], a
	jr nz, .done
	ldh a, [hOvfHi]
	inc a
	ldh [hOvfHi], a
.done
	pop af
	reti

; Reset and start the counter. Clobbers AF.
TimerStart::
	xor a
	ldh [rTAC], a               ; stop while resetting
	ldh [rTIMA], a
	ldh [rTMA], a
	ldh [hOvfLo], a
	ldh [hOvfHi], a
	ldh [rIF], a
	ld a, IE_TIMER
	ldh [rIE], a
	ld a, TAC_START | TAC_262KHZ
	ldh [rTAC], a
	ei
	ret

; Stop the counter and store the raw record into slot C. Clobbers AF, B, HL.
TimerStop::
	di
	xor a
	ldh [rTAC], a
	; account an overflow that fired but was never serviced
	ldh a, [rIF]
	bit B_IF_TIMER, a
	jr z, .nofix
	ldh a, [hOvfLo]
	inc a
	ldh [hOvfLo], a
	jr nz, .nofix
	ldh a, [hOvfHi]
	inc a
	ldh [hOvfHi], a
.nofix
	xor a
	ldh [rIE], a
	ld a, c                     ; slot * 4
	add a
	add a
	ld l, a
	ld h, HIGH(TIMING_BUF)      ; TIMING_BUF = $DE00 (LOW = 0)
	ldh a, [rTIMA]
	ld [hli], a
	ldh a, [hOvfLo]
	ld [hli], a
	ldh a, [hOvfHi]
	ld [hli], a
	xor a
	ld [hl], a
	ret

; --- CMD_TIMING: micro workloads ---------------------------------------------
; Every loop body is wrapped in push bc / pop bc and 256 iterations; the
; empty slot calls a bare ret so (slot - empty) = 256 * (call + routine).
; Bank 1: reads no banked data (pure code + ROM0 helpers), so it stays in
; bank 1; the ISR and TimerStart/Stop above stay in ROM0 for the engine's
; round-1 rig.

SECTION "Timing workloads", ROMX, BANK[1]

RetStub:
	ret

; \1 = slot, \2 = routine to call 256 times
MACRO TIME256
	ld c, \1
	call TimerStart
	ld b, 0                     ; 256 iterations
.loop\@
	push bc
	call \2
	pop bc
	dec b
	jr nz, .loop\@
	ld c, \1
	call TimerStop
ENDM

RunTiming::
	; ---- d3 config (n = 17) ----
	xor a
	call SetConfig
	call TimingInitState
	TIME256 0, RetStub          ; TSLOT_EMPTY_LOOP (shared calibration)
	ld a, 0
	ldh [hQa], a
	ld a, 1
	ldh [hQb], a
	TIME256 1, DoCNOT           ; TSLOT_CNOT_D3
	TIME256 2, DoH              ; TSLOT_H_D3 (parks q0 in |+> ... state is
	                            ; irrelevant: slices are branch-free)
	TIME256 3, DoS
	TIME256 4, DoPX
	call TimingInitState        ; fresh |0^n> so measure(0) is determinate k=1
	TIME256 5, MeasureZ         ; TSLOT_MEAS_D3
	; ---- d5 config (n = 49) ----
	ld a, 1
	call SetConfig
	call TimingInitState
	ld a, 0
	ldh [hQa], a
	ld a, 1
	ldh [hQb], a
	TIME256 6, DoCNOT
	TIME256 7, DoH
	TIME256 8, DoS
	TIME256 9, DoPX
	call TimingInitState
	TIME256 10, MeasureZ        ; k=1 fast path
	; ---- single random-branch collapse at d5 ----
	call TimingInitState
	ld a, 0
	ldh [hQa], a
	call DoH                    ; |+> on qubit 0: next measure is random
	ld c, 11                    ; TSLOT_RANDMEAS_D5
	call TimerStart
	call MeasureZ
	ld c, 11
	call TimerStop
	ret

; |0^n> + a fixed RNG seed (coins for any random paths). Clobbers everything.
TimingInitState:
	ld de, $0000
	call RngSeed
	jp TableauInit
