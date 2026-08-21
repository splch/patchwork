; Kernel coroutine (the "resumable kernel state machine" of PLAN.md Phase 2,
; implemented as a stack-switch coroutine): the kernel runs on its own stack
; at KSTACK_TOP and yields anywhere; the frame loop resumes it with a fresh
; M-cycle budget each VBlank. Suspension is invisible to kernel code - all
; registers and the kernel stack survive a yield, which is what makes the
; determinism-across-suspension guarantee structural.

INCLUDE "hardware.inc"
INCLUDE "kernel/kernel.inc"

SECTION "Coroutine", ROM0

; Prime the kernel stack so the first KResume enters EngineMain.
; Layout from wKernSP: [hl][de][bc][af][EngineMain]. Clobbers AF, B, HL.
KPrime::
	ld hl, KSTACK_TOP - 10
	ld a, l
	ld [wKernSP], a
	ld a, h
	ld [wKernSP + 1], a
	xor a
	ld b, 8                     ; dummy register frame
.zero
	ld [hli], a
	dec b
	jr nz, .zero
	ld a, LOW(EngineMain)
	ld [hli], a
	ld a, HIGH(EngineMain)
	ld [hl], a
	ret

; Main -> kernel. Returns (to the caller in the MAIN context) when the kernel
; yields or parks. Main-context registers are NOT preserved across this call.
KResume::
	ld [wMainSP], sp
	ld a, [wKernSP]
	ld l, a
	ld a, [wKernSP + 1]
	ld h, a
	ld sp, hl
	pop hl
	pop de
	pop bc
	pop af
	ret                         ; into the kernel, after its KYield

; Kernel -> main. All kernel registers survive to the next KResume.
KYield::
	push af
	push bc
	push de
	push hl
	ld [wKernSP], sp
	ld a, [wMainSP]
	ld l, a
	ld a, [wMainSP + 1]
	ld h, a
	ld sp, hl
	ret                         ; into the main context, after its KResume

; Charge DE M-cycles against the frame budget; when it runs out, yield
; (the frame loop refreshes hBud before resuming) and then proceed.
; Preserves all registers except AF.
KCharge::
	ldh a, [hBudLo]
	sub e
	ldh [hBudLo], a
	ldh a, [hBudHi]
	sbc d
	ldh [hBudHi], a
	ret nc
	ldh a, [hNoYield]
	and a
	ret nz                      ; timing window: never suspend
	jp KYield                   ; tail call: resume returns to our caller
