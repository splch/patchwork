; Kernel HRAM map - fixed EQUs so every LDH offset is a compile-time
; constant (no linker-placed HRAM sections anywhere in this ROM; keep it
; that way or addresses will collide). RVEC ($FF80) is defined in the
; generated circuit_defs.inc; everything else lives here.

IF !DEF(KERNEL_INC)
DEF KERNEL_INC EQU 1

INCLUDE "generated/circuit_defs.inc"

; $FF80-$FF8F: RVEC (phase vector R, bit i = row i)

; --- RNG ---
; The state doubles as the output buffer (a step's output IS its new state,
; low byte first): consumers read hRngS0+((4-hRngCnt)) via hRngCnt.
; $FF94-$FF97 (the old separate output mirror) are free.
DEF hRngS0   EQU $FF90          ; xorshift32 state, little-endian
DEF hRngS1   EQU $FF91
DEF hRngS2   EQU $FF92
DEF hRngS3   EQU $FF93
DEF hRngCnt  EQU $FF98          ; bytes remaining (0..4)

; --- current config ---
DEF hCfg      EQU $FF99         ; config id (CfgNTab index; 0 = d3, 1 = d5, 2+ Act 2)
DEF hCfgN     EQU $FF9A         ; n
DEF hCfgRowB  EQU $FF9B         ; ceil(n/8): bytes per extracted row
DEF hCfgSlice EQU $FF9C         ; ceil((2n+1)/8): bytes per column slice
DEF hMaskLo   EQU $FF9D         ; -> WMASKS (stab; +16 destab; +32 full)
DEF hMaskHi   EQU $FF9E

; --- executor ---
DEF hStreamLo EQU $FF9F
DEF hStreamHi EQU $FFA0
DEF hMeasLo   EQU $FFA1         ; measurement bit counter
DEF hMeasHi   EQU $FFA2
DEF hHerald   EQU $FFA3         ; herald triple count
DEF hHeraldOv EQU $FFA4
DEF hGroup    EQU $FFA5         ; current PW_ERASE group
DEF hPlo      EQU $FFA6         ; current noise p16
DEF hPhi      EQU $FFA7

; --- gate/measure scratch ---
DEF hQa   EQU $FFA8
DEF hQb   EQU $FFA9
DEF hP    EQU $FFAA             ; anticommuting stabilizer row p
DEF hCoin EQU $FFAB
DEF hRp   EQU $FFAC             ; phase of extracted row p
DEF hK    EQU $FFAD             ; g-sum accumulator (mod 4 handling)
DEF hTmp1 EQU $FFAE
DEF hTmp2 EQU $FFAF
DEF hTmp3 EQU $FFB0
DEF hTmp4 EQU $FFB1

; --- timing rig ---
DEF hOvfLo EQU $FFB2            ; TIMA overflow counter
DEF hOvfHi EQU $FFB3

; --- console detection (main.asm) ---
DEF hConsoleA EQU $FFB4
DEF hConsoleB EQU $FFB5

; --- random-collapse target iteration ---
DEF hIterByte EQU $FFB6         ; current TBUF byte index
DEF hIterBits EQU $FFB7         ; remaining bits of the current byte
DEF hRow      EQU $FFB8         ; current target row index
DEF hScanOff  EQU $FFB9         ; first column byte holding stabilizer rows (n>>3)
DEF hScanCnt  EQU $FFBA         ; slice bytes from there on

; --- engine (Phase 2) hot vars ---
DEF hBudLo    EQU $FFBB         ; per-frame kernel budget (M-cycle allowance)
DEF hBudHi    EQU $FFBC
DEF hSite     EQU $FFBD         ; round-relative site counter, LOW byte
DEF hFaultIdx EQU $FFBE         ; next WFAULTS entry index
DEF hSynIdx   EQU $FFBF         ; bit position in the syndrome staging buffer
DEF hNoYield  EQU $FFC0         ; nonzero: KCharge never yields (timing windows)
; Phase 8: Act 3 rounds carry up to ~400 sites, so the site counter is
; 16-bit. These live past the shell's HRAM block ($FFC1-$FFD4) - the first
; free HRAM. hLim* hold SitesApply's window limit (must survive
; ApplySiteFault, which clobbers hTmp2-4).
DEF hSiteHi   EQU $FFD5         ; site counter, HIGH byte
DEF hLimLo    EQU $FFD6         ; SitesApply window limit (16-bit)
DEF hLimHi    EQU $FFD7

; --- WRAM scratch buffers (fixed; no WRAM sections either) ---
DEF TBUF     EQU $C500          ; 16 B: random-measure target row mask
DEF PROW_X   EQU $C510          ; 8 B: extracted row p, X part
DEF PROW_Z   EQU $C518          ; 8 B
DEF IROW_X   EQU $C520          ; 8 B: extracted target/fold row
DEF IROW_Z   EQU $C528          ; 8 B
DEF SCR_X    EQU $C530          ; 8 B: determinate-fold scratch row
DEF SCR_Z    EQU $C538          ; 8 B
DEF CBUF     EQU $C540          ; 8 B: determinate destabilizer-hit bytes
; Measurement cache (executor-level; SPEC-equivalent fast path): a qubit
; measured and untouched since has a guaranteed-determinate next measurement
; equal to the recorded outcome, and determinate measures are side-effect
; free - so M/R on a cache-valid qubit skips the tableau entirely.
DEF MVALID   EQU $C548          ; 8 B bitmap: cache valid per qubit
DEF MVALUE   EQU $C550          ; 8 B bitmap: last outcome per qubit
; MeasurePP mask staging (Phase 7). $C560-$C5D7 is time-shared: WFAULTS
; during production (below), the autopsy's UF_DEG borrow in the end state
; (the kernel is frozen there and its pending faults are never read again).
DEF MPX_BUF  EQU $C5E0          ; 8 B: generalized-measurement X mask (qubit bits)
DEF MPZ_BUF  EQU $C5E8          ; 8 B: Z mask
; Generated row masks (SetConfig writes; stab +0, destab +16, full +32).
; WRAM so they are readable under ANY mapped ROM bank; $D4C0-$D4EF sits
; between the EHER ring (ends $D4C0) and the gfx blob home ($D500).
DEF WMASKS   EQU $D4C0

; --- engine (Phase 2) state ---
DEF ERING       EQU $C600       ; detector ring: 16 slots x 4 B
DEF RING_ROUNDS EQU 16
DEF ERING_MASK  EQU 15
DEF WSYN_PREV   EQU $C640       ; 4 B syndrome of previous round
DEF WSYN_CUR    EQU $C644       ; 4 B syndrome staging (current round)
DEF WTRUE_FX    EQU $C648       ; 4 B true-error frame, X part (data qubits)
DEF WTRUE_FZ    EQU $C64C       ; 4 B
DEF WCORR_X     EQU $C650       ; 4 B player-correction frame (engine never reads)
DEF WCORR_Z     EQU $C654       ; 4 B
DEF WFAULT_CNT  EQU $C658       ; sampled faults this round
; Phase 8: entries are (site lo, site hi, choice) - 16-bit sites - so the
; buffer moved to the $C560 kernel-scratch hole (time-shared with UF_DEG,
; see above); 40 x 3 = 120 B = exactly the old UF_DEG span.
DEF WFAULTS     EQU $C560       ; 40 x (site lo, site hi, choice)
DEF WFAULT_MAX  EQU 40
DEF wMainSP     EQU $C6B0
DEF wKernSP     EQU $C6B2
DEF wEngMode    EQU $C6B4       ; 0 = tableau, 1 = DEM (Pauli-frame layer)
DEF wEngT       EQU $C6B5       ; rounds to produce
DEF wProd       EQU $C6B6       ; completed rounds
DEF wCons       EQU $C6B7       ; consumed rounds (shell side)
DEF wEngDone    EQU $C6B8
DEF wBudLo      EQU $C6B9       ; per-frame budget parameter
DEF wBudHi      EQU $C6BA
DEF wEngPlo     EQU $C6BB       ; gate-class p16
DEF wEngPhi     EQU $C6BC
DEF wEngQlo     EQU $C6BD       ; measurement-class q16
DEF wEngQhi     EQU $C6BE
DEF wFrameLo    EQU $C6BF
DEF wFrameHi    EQU $C6C0
DEF wOverruns   EQU $C6C1       ; VBlank-already-pending count (missed frames)
DEF wConsRate   EQU $C6C2       ; 0 = consume instantly, N = one round per N frames
DEF wConsCntr   EQU $C6C3
DEF wRound      EQU $C6C4
DEF wRingT      EQU $C6C5       ; ring slot ptr (current round), 2 B
DEF wRingT1     EQU $C6C7       ; ring slot ptr (next round), 2 B
DEF wSitesLo    EQU $C6C9       ; per-config table bases (from EngineCfgTab)
DEF wSitesHi    EQU $C6CA
DEF wIdsLo      EQU $C6CB
DEF wIdsHi      EQU $C6CC
DEF wMechsLo    EQU $C6CD
DEF wMechsHi    EQU $C6CE
DEF wPclsLo     EQU $C6CF
DEF wPclsHi     EQU $C6D0
DEF wStreamLo   EQU $C6D1
DEF wStreamHi   EQU $C6D2
; Phase 8: nsites is 16-bit (Act 3 rounds carry up to ~400 sites), so the
; cfgtab copy block is 14 bytes and the fields after it shifted; the debug
; slice-capture bytes moved past the (test-visible, immovable) wEngMpp trio.
DEF wNSites     EQU $C6D3       ; 16-bit site count (lo, hi)
DEF wNSitesHi   EQU $C6D4
DEF wNXck      EQU $C6D5
DEF wNErase     EQU $C6D6       ; erasure site count (sites 0..n-1)
DEF wEngElo     EQU $C6D7       ; erasure-class e16
DEF wEngEhi     EQU $C6D8
DEF wNMain      EQU $C6D9       ; wNSites - wNErase, 16-bit (lo, hi)
DEF wNMainHi    EQU $C6DA
DEF wFrmT       EQU $C6DB       ; EFRAME slot ptr (current round), 2 B
DEF wHerT       EQU $C6DD       ; EHER slot ptr (current round), 2 B
; Engine surgery hook (Phase 7): ONE pending generalized measurement, run by
; the PRODUCER in kernel context at the top of round wEngMppRnd (charged +
; yieldable, so the frame contract holds through a MERGING beat). Tableau
; mode only. Masks staged at WMPP_X/Z; outcome published in wEngMppOut.
DEF wEngMpp     EQU $C6E2       ; 0 none, 1 pending, 2 done
DEF wEngMppRnd  EQU $C6E3       ; run before producing this round
DEF wEngMppOut  EQU $C6E4       ; outcome (valid when wEngMpp == 2)
; WMPP_X ($D4F0) / WMPP_Z ($D4F8) come from the generated circuit_defs.inc
; (romproto.py owns test-visible addresses).
DEF wDbgSlice   EQU $C6E5       ; worst slice-end LY seen (debug)
DEF wDbgSliceR  EQU $C6E6       ; round of the worst slice (debug)
DEF wDbgSliceS  EQU $C6E7       ; hSite low byte at the worst slice end (debug)
; Phase 8: a config's mechanism table may live in its own bank (Act 3 tables
; outgrow one 16 KiB bank); PreDrawHit maps wMechBank around its mech reads
; and restores wSiteBank (EngBankTab carries the pair).
DEF wSiteBank   EQU $C6E8
DEF wMechBank   EQU $C6E9
; One-loop-top overrun grace, armed by the round-0 wOverruns reset: the frame
; that COMPLETES round 0 is still CAL-beat work, but its pending-VBlank is
; only visible at the loop top after the reset (and after wRound advanced) -
; without the grace one CAL overrun leaks into the steady-state count
; whenever round 0's cost lands near a frame boundary (surfaced by the
; 2026-08-20 charge retune; the shell's wGrace covers its loop the same way).
DEF wOvrGrace   EQU $C6EA
DEF wDbgLY      EQU $C6DF       ; LY at the last overrun (debug)
DEF wDbgRound   EQU $C6E0       ; wRound at the last overrun (debug)
DEF ESTAMPS     EQU $C700       ; per-round completion frame (low byte)
DEF EDETHIST    EQU $C800       ; detector history mirror: 60 rounds x 4 B
DEF EDETHIST_MAX EQU 60
; EFRAME ($D400, 16 x 8 B) and EHER ($D480, 16 x 4 B) come from the generated
; circuit_defs.inc (romproto.py is the source of truth for test-visible
; addresses). Same ring discipline as ERING: the NEXT slot is cleared each
; round; XOR of all EFRAME slots == WTRUE_FX/FZ.
DEF KSTACK_TOP  EQU $DC00       ; kernel coroutine stack (grows down)

ENDC
