; Phase 9 audio pass 2: the music driver. RECORDED DEVIATION from the plan's
; fortISSimO (rationale in tools/music/gen.py, PLAN Phase 9): a minimal
; in-house sequencer on the channels Phase 6 reserved for music - CH2
; (melody) + CH3 (wave bass, one octave under for free via CH3's divider).
; CH1/CH4 stay the SFX lanes; the handoff needs no arbitration because the
; lanes never overlap.
;
; Context rules:
; - MusStart maps MUSIC_BANK and leaves it mapped: callers are the menu
;   paths (which re-map bank 4 themselves) and the game's end state (the
;   kernel freeze point, where banking is free and .apt re-maps GFX_BANK).
; - MusFrame/MusStop/MusService read only the $DC00 WRAM page + APU
;   registers - callable from ANY main-context bank (the no-ROMX rule), and
;   never from ISRs. The G1/timing paths call MusStop first and never tick,
;   so the timing screen stays silent (the Phase 6 contract).
; - Envelopes keep DAC-on upper bits and rests go through NRx2 $08 /
;   NR32 mute + retrigger, never DAC-off (no HPF pops; GAMEBOY.md sec 6).

INCLUDE "hardware.inc"
INCLUDE "shell/shell.inc"

SECTION "Music driver", ROM0

; A = track id. Copies the period table + track blob to WRAM, loads CH3's
; wave (DAC off during the write), arms the sequencer. Maps MUSIC_BANK and
; leaves it mapped. Clobbers everything.
MusStart::
	ld c, a                     ; track id
	ld a, MUSIC_BANK
	ld [$2000], a
	; period table -> MUSP
	ld hl, MusPeriods
	ld de, MUSP
	ld b, MUS_PLEN
.pcp
	ld a, [hli]
	ld [de], a
	inc e
	dec b
	jr nz, .pcp
	; MusicTab[id]: dw blob, dw len
	ld a, c
	add a
	add a                       ; * 4
	ld hl, MusicTab
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hli]
	ld e, a
	ld a, [hli]
	ld d, a                     ; de -> blob
	ld a, [hli]
	ld b, a                     ; len (< 256; gen asserts the cap)
	push bc                     ; c = track id
	ld hl, MUSW
.bcp
	ld a, [de]
	inc de
	ld [hli], a
	dec b
	jr nz, .bcp
	; header -> state
	ld a, [MUSW]
	ld [wMusEnv], a
	ld a, [MUSW + 1]
	ld [wMusVol], a
	ld a, [MUSW + 2]
	ld [wMusFlags], a
	; CH3 wave: DAC off, load 16 bytes, DAC on, len free, muted until a row
	xor a
	ldh [rAUD3ENA], a
	ld hl, MUSW + 3
	ld c, LOW(rAUD3WAVE_0)
	ld b, 16
.wcp
	ld a, [hli]
	ldh [c], a
	inc c
	dec b
	jr nz, .wcp
	ld a, AUD3ENA_ON
	ldh [rAUD3ENA], a
	xor a
	ldh [rAUD3LEN], a
	ldh [rAUD3LEVEL], a         ; mute (DAC stays on)
	; CH2: envelope staged (DAC on), duty 50%, silent until a row triggers
	ld a, [wMusEnv]
	ldh [rAUD2ENV], a
	ld a, $80
	ldh [rAUD2LEN], a
	; sequencer state
	ld a, LOW(MUS_ROWS0)
	ld [wMusPos], a
	ld a, HIGH(MUS_ROWS0)
	ld [wMusPos + 1], a
	ld a, 1
	ld [wMusTimer], a           ; first row lands on the next frame tick
	xor a
	ld [wMusSh2], a
	ld [wMusSh2 + 1], a
	ld [wMusSh3], a
	ld [wMusSh3 + 1], a
	pop bc
	ld a, c
	inc a
	ld [wMusOn], a              ; id + 1
	ret

; Stop + silence both music lanes cleanly (no pops). Clobbers AF.
MusStop::
	xor a
	ld [wMusOn], a
	ld a, $08                   ; vol 0, DAC-on bit pattern
	ldh [rAUD2ENV], a
	ld a, $80
	ldh [rAUD2HIGH], a          ; retrigger into silence
	xor a
	ldh [rAUD3LEVEL], a         ; CH3 mute (DAC untouched)
	ret

; One frame of sequencing. No-op when stopped. Main context only; reads the
; $DC00 page + writes APU registers - safe under any mapped ROM bank.
; Clobbers AF, BC, DE, HL.
MusFrame::
	ld a, [wMusOn]
	and a
	ret z
	ld hl, wMusTimer
	dec [hl]
	ret nz
.row
	ld a, [wMusPos]
	ld l, a
	ld a, [wMusPos + 1]
	ld h, a
	ld a, [hli]                 ; dur
	and a
	jr nz, .play
	; END marker: loop or stop
	ld a, [wMusFlags]
	bit 0, a
	jp nz, MusStop              ; one-shot: done
	ld a, LOW(MUS_ROWS0)
	ld [wMusPos], a
	ld a, HIGH(MUS_ROWS0)
	ld [wMusPos + 1], a
	jr .row
.play
	ld [wMusTimer], a
	ld a, [hli]                 ; CH2 note
	ld b, a
	ld a, [hli]                 ; CH3 note
	ld c, a
	ld a, l
	ld [wMusPos], a
	ld a, h
	ld [wMusPos + 1], a
	; --- CH2 ---
	ld a, b
	and a
	jr z, .ch3                  ; hold
	cp MUS_NOTE_REST
	jr nz, .n2
	ld a, $08                   ; rest: silent retrigger
	ldh [rAUD2ENV], a
	ld a, $80
	ldh [rAUD2HIGH], a
	xor a
	ld [wMusSh2], a
	ld [wMusSh2 + 1], a
	jr .ch3
.n2
	call MusPeriodDE            ; note in A -> DE = period
	ld a, [wMusEnv]
	ldh [rAUD2ENV], a
	ld a, e
	ldh [rAUD2LOW], a
	ld [wMusSh2], a
	ld a, d
	or $80                      ; trigger, length off
	ldh [rAUD2HIGH], a
	ld a, d
	ld [wMusSh2 + 1], a
.ch3
	ld a, c
	and a
	ret z                       ; hold
	cp MUS_NOTE_REST
	jr nz, .n3
	xor a
	ldh [rAUD3LEVEL], a         ; mute
	ld [wMusSh3], a
	ld [wMusSh3 + 1], a
	ret
.n3
	call MusPeriodDE
	ld a, [wMusVol]
	ldh [rAUD3LEVEL], a
	ld a, e
	ldh [rAUD3LOW], a
	ld [wMusSh3], a
	ld a, d
	or $80
	ldh [rAUD3HIGH], a
	ld a, d
	ld [wMusSh3 + 1], a
	ret

; A = 1-based note index -> DE = period from the WRAM table. Clobbers AF, HL.
MusPeriodDE:
	dec a
	add a
	add LOW(MUSP)
	ld l, a
	ld h, HIGH(MUSP)
	ld a, [hli]
	ld e, a
	ld d, [hl]
	ret

; Frame-edge tick for spin loops (menu / codex / seed panel poll cadence is
; not frame-locked): fires MusFrame exactly once per frame, on the LY
; enter-VBlank edge. Clobbers AF, BC, DE, HL.
MusService::
	ldh a, [rLY]
	ld b, a
	ld a, [wMusLyPrev]
	ld c, a
	ld a, b
	ld [wMusLyPrev], a
	cp SCREEN_HEIGHT_PX
	ret c                       ; not in VBlank
	ld a, c
	cp SCREEN_HEIGHT_PX
	ret nc                      ; already was: edge consumed
	jp MusFrame
