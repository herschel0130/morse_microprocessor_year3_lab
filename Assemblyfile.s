    PROCESSOR 18F87K22
    #include <xc.inc>

; =============================================================================
; Configuration Bits
; =============================================================================
    config FOSC = HS1        ; HS oscillator (medium power, 4-16 MHz)
    config PLLCFG = OFF      ; PLL off
    config FCMEN = OFF       ; Fail-safe clock monitor off
    config IESO = OFF        ; Internal/external oscillator switchover off
    config PWRTEN = ON       ; Power-up timer enabled
    config BOREN = ON        ; Brown-out reset enabled
    config BORV = 285        ; Brown-out voltage ~2.85V
    config WDTEN = OFF       ; Watchdog timer disabled
    config XINST = OFF       ; Extended instruction set disabled
    config LVP = OFF         ; Low-voltage programming disabled
    config CP0 = OFF         ; Code protection off
    config CP1 = OFF
    config CP2 = OFF
    config CP3 = OFF

; =============================================================================
; RAM Variables — Access Bank
; =============================================================================
    PSECT udata_acs

state_flags:    DS 1    ; bit0=armed (first edge discarded)
ovf_count:      DS 1    ; Timer1 overflow counter (extends to 24-bit)

; Current event scratch (set in ISR, consumed in main)
evt_type:       DS 1    ; 0x00 = pulse, 0x01 = gap
evt_dur_H:      DS 1    ; 24-bit duration, high byte
evt_dur_M:      DS 1    ; middle byte
evt_dur_L:      DS 1    ; low byte

; Ring buffer: 8 entries x 4 bytes = 32 bytes
buf_data:       DS 32
buf_head:       DS 1    ; write index (0-7)
buf_tail:       DS 1    ; read index (0-7)

; Estimator state (24-bit each)
est_pulse_H:    DS 1
est_pulse_M:    DS 1
est_pulse_L:    DS 1
est_gap_H:      DS 1
est_gap_M:      DS 1
est_gap_L:      DS 1
threshold_H:    DS 1
threshold_M:    DS 1
threshold_L:    DS 1

; Counters
pulse_evt_cnt:  DS 1    ; pulse events seen (for seeding)
gap_evt_cnt:    DS 1    ; gap events seen (for seeding)

; Morse decoder state
morse_bits:     DS 1    ; accumulated dit/dah pattern (0=dit,1=dah)
morse_len:      DS 1    ; number of symbols so far

; Dequeue scratch
deq_type:       DS 1
deq_dur_H:      DS 1
deq_dur_M:      DS 1
deq_dur_L:      DS 1

; 24-bit math scratch
math_a_H:       DS 1
math_a_M:       DS 1
math_a_L:       DS 1
math_b_H:       DS 1
math_b_M:       DS 1
math_b_L:       DS 1

; LCD position tracker
lcd_col:        DS 1
lcd_row:        DS 1

; ISR context save (low-priority)
isr_lo_w:       DS 1
isr_lo_status:  DS 1
isr_lo_bsr:     DS 1

; ISR high-priority save for regs clobbered by buf_enqueue
isr_hi_fsr0l:   DS 1
isr_hi_fsr0h:   DS 1
isr_hi_prodl:   DS 1
isr_hi_prodh:   DS 1

; =============================================================================
; Reset Vector — linker places resetVec at 0x0000
; =============================================================================
    PSECT resetVec, class=CODE, reloc=2
    goto main

; =============================================================================
; High-Priority Interrupt Vector — linker places intcode at 0x0008
; =============================================================================
    PSECT intcode, class=CODE, reloc=2
    goto isr_high

; =============================================================================
; Low-Priority Interrupt Vector — linker places intcodelo at 0x0018
; =============================================================================
    PSECT intcodelo, class=CODE, reloc=2
    goto isr_low

; =============================================================================
; Main Code Section
; =============================================================================
    PSECT code

; =============================================================================
;  MAIN — System Initialisation
; =============================================================================
main:
    ; --- Clear Access RAM variables ---
    clrf state_flags, a
    clrf ovf_count, a
    clrf buf_head, a
    clrf buf_tail, a
    clrf est_pulse_H, a
    clrf est_pulse_M, a
    clrf est_pulse_L, a
    clrf est_gap_H, a
    clrf est_gap_M, a
    clrf est_gap_L, a
    clrf threshold_H, a
    clrf threshold_M, a
    clrf threshold_L, a
    clrf pulse_evt_cnt, a
    clrf gap_evt_cnt, a
    clrf morse_bits, a
    clrf morse_len, a
    clrf lcd_col, a
    clrf lcd_row, a

    ; --- Port Direction Setup ---
    bsf TRISB, 0, a        ; RB0 = input (button / INT0)
    bcf TRISC, 6, a        ; RC6 = output (UART1 TX)
    bsf TRISC, 7, a        ; RC7 = input  (UART1 RX, unused but safe)
    clrf TRISD, a           ; PORTD = all outputs (LCD data bus)
    clrf TRISE, a           ; PORTE = all outputs (LCD control: RS, RW, EN)
    clrf LATD, a
    clrf LATE, a

    ; --- Timer1: Fosc/4, 1:8 prescaler, 16-bit R/W ---
    movlw 0x00
    movwf TMR1H, a
    movwf TMR1L, a
    ; T1CON: TMR1ON=1, T1RD16=1, T1CKPS=11 (1:8), T1OSCEN=0, TMR1CS=00
    movlw (1 << 7) | (1 << 5) | (1 << 4) | (1 << 0)  ; 0xB1
    movwf T1CON, a

    ; --- Interrupt Configuration ---
    ; Enable priority levels
    bsf RCON, 7, a          ; IPEN = 1

    ; INT0 — always high-priority on PIC18
    bcf INTCON, 1, a         ; Clear INT0IF
    bsf INTCON, 4, a         ; INT0IE = 1
    bsf INTCON2, 6, a        ; INTEDG0 = 1 (start on rising edge = press)

    ; Timer1 overflow — low priority
    bcf PIR1, 0, a           ; Clear TMR1IF
    bsf PIE1, 0, a           ; TMR1IE = 1
    bcf IPR1, 0, a           ; TMR1 = low priority

    ; Global interrupt enables
    bsf INTCON, 6, a         ; PEIE / GIEL = 1
    bsf INTCON, 7, a         ; GIE  / GIEH = 1

    ; --- Peripheral Init (UART, LCD) ---
    call uart_init
    call lcd_init

    ; --- Send startup banner over UART ---
    movlw low highword(str_banner)
    movwf TBLPTRU, a
    movlw high(str_banner)
    movwf TBLPTRH, a
    movlw low(str_banner)
    movwf TBLPTRL, a
    call uart_tx_string

; =============================================================================
;  MAIN LOOP — dequeue events, estimate, classify, log, decode
; =============================================================================
loop:
    call buf_dequeue
    btfsc STATUS, 2, a       ; Z=1 means buffer empty
    bra loop                 ; spin until event available

    ; --- Update estimator ---
    call estimate_update

    ; --- Branch on event type ---
    tstfsz deq_type, a       ; 0=pulse, 1=gap
    bra _loop_gap

    ; ===== PULSE EVENT =====
    call classify_pulse
    movwf math_b_M, a        ; save 'S'/'L' char

    ; Log: "P <dur> E:<est> T:<thr> -> S|L\r\n"
    movlw 'P'
    call uart_tx_char
    movlw ' '
    call uart_tx_char
    call uart_tx_hex24       ; duration
    movlw ' '
    call uart_tx_char
    movlw 'E'
    call uart_tx_char
    movlw ':'
    call uart_tx_char
    ; Log pulse estimate
    movf est_pulse_H, w, a
    call uart_tx_hex8
    movf est_pulse_M, w, a
    call uart_tx_hex8
    movf est_pulse_L, w, a
    call uart_tx_hex8
    movlw ' '
    call uart_tx_char
    movlw 'T'
    call uart_tx_char
    movlw ':'
    call uart_tx_char
    movf threshold_H, w, a
    call uart_tx_hex8
    movf threshold_M, w, a
    call uart_tx_hex8
    movf threshold_L, w, a
    call uart_tx_hex8
    movlw ' '
    call uart_tx_char
    movlw '-'
    call uart_tx_char
    movlw '>'
    call uart_tx_char
    movlw ' '
    call uart_tx_char
    movf math_b_M, w, a     ; 'S' or 'L'
    call uart_tx_char
    call uart_tx_newline

    ; Accumulate into Morse decoder
    call morse_accumulate
    bra loop

    ; ===== GAP EVENT =====
_loop_gap:
    ; Log: "G <dur> E:<est>\r\n"
    movlw 'G'
    call uart_tx_char
    movlw ' '
    call uart_tx_char
    call uart_tx_hex24
    movlw ' '
    call uart_tx_char
    movlw 'E'
    call uart_tx_char
    movlw ':'
    call uart_tx_char
    movf est_gap_H, w, a
    call uart_tx_hex8
    movf est_gap_M, w, a
    call uart_tx_hex8
    movf est_gap_L, w, a
    call uart_tx_hex8
    call uart_tx_newline

    ; Check for character / word gap
    call check_word_gap
    btfsc STATUS, 0, a       ; C=1 if word gap
    bra _loop_word_gap

    call check_char_gap
    btfsc STATUS, 0, a       ; C=1 if char gap
    bra _loop_char_gap

    bra loop                 ; inter-element gap, no decode yet

_loop_char_gap:
    call morse_decode
    movwf math_b_H, a        ; save decoded char
    call lcd_putchar          ; WREG still has char -> LCD
    movf math_b_H, w, a      ; reload char
    call uart_tx_char         ; decoded char to UART
    call uart_tx_newline
    bra loop

_loop_word_gap:
    call morse_decode
    movwf math_b_H, a        ; save decoded char
    call lcd_putchar          ; WREG still has char -> LCD
    movf math_b_H, w, a      ; reload char
    call uart_tx_char         ; decoded char to UART
    movlw ' '
    call lcd_putchar          ; space on LCD
    movlw ' '
    call uart_tx_char         ; space on UART
    call uart_tx_newline
    bra loop

; =============================================================================
;  UART MODULE
; =============================================================================

; uart_init — 9600 baud, 8N1, TX only
; Fosc=16MHz, BRGH=1, BRG16=1: SPBRG = Fosc/(4*(baud))-1 = 416 = 0x01A0
uart_init:
    movlw 0xA0
    movwf SPBRG1, a         ; low byte of 416
    movlw 0x01
    movwf SPBRGH1, a        ; high byte of 416
    movlw (1 << 2) | (1 << 5)  ; BRGH=1, TXEN=1
    movwf TXSTA1, a
    movlw (1 << 3)             ; BRG16=1
    movwf BAUDCON1, a
    movlw (1 << 7)             ; SPEN=1
    movwf RCSTA1, a
    return

; uart_tx_char — transmit byte in WREG
uart_tx_char:
    btfss TXSTA1, 1, a      ; wait for TRMT (TSR empty)
    bra uart_tx_char
    movwf TXREG1, a
    return

; uart_tx_hex4 — transmit low nibble of WREG as ASCII hex
uart_tx_hex4:
    andlw 0x0F
    sublw 0x09              ; 9 - nibble
    btfss STATUS, 0, a      ; C=1 if nibble <= 9
    bra _hex4_letter
    sublw 0x09              ; restore nibble
    addlw '0'
    bra uart_tx_char
_hex4_letter:
    sublw 0x09
    addlw 'A' - 10
    bra uart_tx_char

; uart_tx_hex8 — transmit byte in WREG as two hex chars
uart_tx_hex8:
    movwf math_b_L, a       ; save byte
    swapf math_b_L, w, a    ; high nibble -> low
    call uart_tx_hex4
    movf math_b_L, w, a     ; low nibble
    call uart_tx_hex4
    return

; uart_tx_newline — CR+LF
uart_tx_newline:
    movlw 0x0D
    call uart_tx_char
    movlw 0x0A
    call uart_tx_char
    return

; uart_tx_string — transmit null-terminated string from program memory
; TBLPTR must be loaded by caller before call
uart_tx_string:
    tblrd*+
    movf TABLAT, w, a
    btfsc STATUS, 2, a      ; Z=1 means null terminator
    return
    call uart_tx_char
    bra uart_tx_string

; uart_tx_hex24 — transmit 24-bit value in deq_dur_H:M:L
uart_tx_hex24:
    movf deq_dur_H, w, a
    call uart_tx_hex8
    movf deq_dur_M, w, a
    call uart_tx_hex8
    movf deq_dur_L, w, a
    call uart_tx_hex8
    return

; =============================================================================
;  LCD MODULE — HD44780, 8-bit mode on PORTD (data) / PORTE (control)
;  RE0 = RS, RE1 = R/W, RE2 = EN
; =============================================================================

; delay_5ms — busy-wait ~5 ms at 16 MHz (20000 cycles)
; outer=100, inner=200 => 100*200 = 20000 cycles
delay_5ms:
    movlw 100
    movwf math_a_H, a
_d5_outer:
    movlw 200
    movwf math_a_L, a
_d5_inner:
    decfsz math_a_L, f, a
    bra _d5_inner
    decfsz math_a_H, f, a
    bra _d5_outer
    return

; delay_200us — ~800 cycles at 16 MHz
delay_200us:
    movlw 200
    movwf math_a_L, a
_d200_lp:
    nop
    nop
    decfsz math_a_L, f, a
    bra _d200_lp
    return

; lcd_pulse_en — pulse EN high then low
lcd_pulse_en:
    bsf LATE, 2, a          ; EN = 1
    nop
    nop
    bcf LATE, 2, a          ; EN = 0
    call delay_200us
    return

; lcd_cmd — send command byte in WREG
lcd_cmd:
    movwf LATD, a
    bcf LATE, 0, a           ; RS = 0 (command)
    bcf LATE, 1, a           ; R/W = 0 (write)
    call lcd_pulse_en
    return

; lcd_data — send data byte in WREG
lcd_data:
    movwf LATD, a
    bsf LATE, 0, a           ; RS = 1 (data)
    bcf LATE, 1, a           ; R/W = 0 (write)
    call lcd_pulse_en
    return

; lcd_init — HD44780 8-bit initialisation sequence
lcd_init:
    call delay_5ms
    call delay_5ms
    call delay_5ms           ; >15 ms power-on delay

    movlw 0x38              ; Function set: 8-bit, 2-line, 5x8 font
    call lcd_cmd
    call delay_5ms
    movlw 0x38
    call lcd_cmd
    call delay_200us
    movlw 0x38
    call lcd_cmd
    call delay_200us

    movlw 0x0C              ; Display ON, cursor OFF, blink OFF
    call lcd_cmd
    call delay_200us

    movlw 0x06              ; Entry mode: increment, no shift
    call lcd_cmd
    call delay_200us

    call lcd_clear
    return

; lcd_clear — clear display
lcd_clear:
    movlw 0x01
    call lcd_cmd
    call delay_5ms           ; clear takes ~1.5 ms
    clrf lcd_col, a
    clrf lcd_row, a
    return

; lcd_set_cursor — row in lcd_row (0-1), col in lcd_col (0-15)
lcd_set_cursor:
    movf lcd_col, w, a
    btfsc lcd_row, 0, a      ; if row 1, add 0x40
    addlw 0x40
    iorlw 0x80               ; Set DDRAM address command
    call lcd_cmd
    return

; lcd_putchar — write ASCII char in WREG, auto-wrap
lcd_putchar:
    call lcd_data
    incf lcd_col, f, a
    movlw 16
    cpfseq lcd_col, a        ; skip if col == 16
    return
    clrf lcd_col, a
    btfsc lcd_row, 0, a      ; if already row 1, scroll
    bra _lcd_scroll
    incf lcd_row, f, a
    call lcd_set_cursor
    return
_lcd_scroll:
    call lcd_clear           ; simple scroll: just clear
    return

; =============================================================================
;  RING BUFFER — 8 entries x 4 bytes, circular
;  Entry layout: [type(1B), dur_H(1B), dur_M(1B), dur_L(1B)]
; =============================================================================

; buf_enqueue — enqueue event from evt_type/evt_dur_H/M/L
; Clobbers: WREG, FSR0
buf_enqueue:
    ; Compute byte offset = buf_head * 4
    movf buf_head, w, a
    mullw 4                  ; PRODL = head*4 (max 28, fits in byte)
    ; FSR0 = &buf_data + offset
    lfsr 0, buf_data
    movf PRODL, w, a
    addwf FSR0L, f, a

    movf evt_type, w, a
    movwf POSTINC0
    movf evt_dur_H, w, a
    movwf POSTINC0
    movf evt_dur_M, w, a
    movwf POSTINC0
    movf evt_dur_L, w, a
    movwf INDF0

    ; Advance head: (head + 1) & 0x07
    incf buf_head, f, a
    movlw 0x07
    andwf buf_head, f, a
    return

; buf_dequeue — dequeue event into deq_type/deq_dur_H/M/L
; Returns: Z=1 if buffer was empty (nothing dequeued)
; Clobbers: WREG, FSR0
buf_dequeue:
    ; Check empty: head == tail
    movf buf_head, w, a
    cpfseq buf_tail, a
    bra _deq_notempty
    bsf STATUS, 2, a        ; set Z = empty
    return
_deq_notempty:
    ; Compute byte offset = buf_tail * 4
    movf buf_tail, w, a
    mullw 4
    lfsr 0, buf_data
    movf PRODL, w, a
    addwf FSR0L, f, a

    movf POSTINC0, w
    movwf deq_type, a
    movf POSTINC0, w
    movwf deq_dur_H, a
    movf POSTINC0, w
    movwf deq_dur_M, a
    movf INDF0, w
    movwf deq_dur_L, a

    ; Advance tail: (tail + 1) & 0x07
    incf buf_tail, f, a
    movlw 0x07
    andwf buf_tail, f, a
    bcf STATUS, 2, a         ; clear Z = not empty
    return

; =============================================================================
;  ISR — High Priority (INT0: button edge)
;  Saves context via hardware shadow registers (FAST return).
;  Reads Timer1 + overflow, computes duration, debounces, enqueues.
; =============================================================================
isr_high:
    ; --- Snapshot timer ASAP ---
    movff TMR1L, evt_dur_L   ; read low first (latches high byte)
    movff TMR1H, evt_dur_M
    movff ovf_count, evt_dur_H

    ; --- Reset Timer1 for next interval ---
    clrf TMR1L, a
    clrf TMR1H, a
    clrf ovf_count, a

    ; --- First edge after power-on: discard (meaningless duration) ---
    btfsc state_flags, 0, a  ; bit0 = 1 means system is armed
    bra _isr_h_armed
    bsf state_flags, 0, a    ; arm the system
    btg INTCON2, 6, a        ; toggle edge for next event
    bcf INTCON, 1, a         ; clear INT0IF
    retfie FAST
_isr_h_armed:

    ; --- Debounce: reject if duration < ~20 ms = 10000 ticks = 0x002710 ---
    ; Quick check: if dur_H > 0, definitely long enough
    tstfsz evt_dur_H, a
    bra _isr_h_accept
    ; dur_H == 0, check M:L >= 0x2710
    movlw 0x27
    cpfsgt evt_dur_M, a      ; skip if dur_M > 0x27
    bra _isr_h_check_low
    bra _isr_h_accept
_isr_h_check_low:
    cpfseq evt_dur_M, a      ; skip if dur_M == 0x27
    bra _isr_h_reject        ; dur_M < 0x27 -> reject
    movlw 0x10
    cpfslt evt_dur_L, a      ; skip if dur_L < 0x10
    bra _isr_h_accept        ; dur_L >= 0x10 -> accept
_isr_h_reject:
    bcf INTCON, 1, a         ; clear INT0IF
    retfie FAST

_isr_h_accept:
    ; Save registers clobbered by buf_enqueue (FSR0, PROD)
    movff FSR0L, isr_hi_fsr0l
    movff FSR0H, isr_hi_fsr0h
    movff PRODL, isr_hi_prodl
    movff PRODH, isr_hi_prodh

    ; --- Determine event type from current edge direction ---
    ; INTEDG0=1 means we were waiting for rising edge (press just happened = end of gap)
    ; INTEDG0=0 means we were waiting for falling edge (release just happened = end of pulse)
    btfsc INTCON2, 6, a      ; test INTEDG0
    bra _isr_h_gap
    ; Falling edge caught -> pulse just ended
    clrf evt_type, a         ; 0x00 = pulse
    bra _isr_h_enqueue
_isr_h_gap:
    ; Rising edge caught -> gap just ended
    movlw 0x01
    movwf evt_type, a        ; 0x01 = gap

_isr_h_enqueue:
    call buf_enqueue

    ; --- Toggle edge direction for next event ---
    btg INTCON2, 6, a        ; flip INTEDG0

    ; Restore clobbered registers
    movff isr_hi_prodh, PRODH
    movff isr_hi_prodl, PRODL
    movff isr_hi_fsr0h, FSR0H
    movff isr_hi_fsr0l, FSR0L

    ; --- Clear interrupt flag ---
    bcf INTCON, 1, a         ; INT0IF = 0
    retfie FAST

; =============================================================================
;  ISR — Low Priority (Timer1 overflow)
; =============================================================================
isr_low:
    movff STATUS, isr_lo_status
    movff WREG, isr_lo_w
    movff BSR, isr_lo_bsr

    btfss PIR1, 0, a         ; TMR1IF?
    bra _isr_lo_done
    bcf PIR1, 0, a           ; clear TMR1IF
    incf ovf_count, f, a     ; increment overflow counter

_isr_lo_done:
    movff isr_lo_bsr, BSR
    movff isr_lo_w, WREG
    movff isr_lo_status, STATUS
    retfie 0

; =============================================================================
;  ESTIMATOR — 24-bit exponential smoothing (alpha = 7/8)
;  T_new = T_old + (T_meas - T_old) >> 3
;  Input: deq_type (0=pulse,1=gap), deq_dur_H/M/L
;  Uses math_a (difference), math_b (scratch)
; =============================================================================
estimate_update:
    ; Decide which estimate to update
    tstfsz deq_type, a
    bra _est_gap

    ; --- Pulse estimate ---
    incf pulse_evt_cnt, f, a
    movlw 4
    cpfsgt pulse_evt_cnt, a  ; skip if count > 4 (past seeding)
    bra _est_seed_pulse
    ; Normal update: diff = T_meas - T_old
    movf est_pulse_L, w, a
    subwf deq_dur_L, w, a
    movwf math_a_L, a
    movf est_pulse_M, w, a
    subwfb deq_dur_M, w, a
    movwf math_a_M, a
    movf est_pulse_H, w, a
    subwfb deq_dur_H, w, a
    movwf math_a_H, a
    ; Arithmetic right shift by 3
    call asr24_3
    ; T_new = T_old + (diff >> 3)
    movf math_a_L, w, a
    addwf est_pulse_L, f, a
    movf math_a_M, w, a
    addwfc est_pulse_M, f, a
    movf math_a_H, w, a
    addwfc est_pulse_H, f, a
    return

_est_seed_pulse:
    ; Seeding: just copy measurement directly
    movff deq_dur_H, est_pulse_H
    movff deq_dur_M, est_pulse_M
    movff deq_dur_L, est_pulse_L
    return

_est_gap:
    ; --- Gap estimate ---
    incf gap_evt_cnt, f, a
    movlw 4
    cpfsgt gap_evt_cnt, a
    bra _est_seed_gap
    ; Normal update
    movf est_gap_L, w, a
    subwf deq_dur_L, w, a
    movwf math_a_L, a
    movf est_gap_M, w, a
    subwfb deq_dur_M, w, a
    movwf math_a_M, a
    movf est_gap_H, w, a
    subwfb deq_dur_H, w, a
    movwf math_a_H, a
    call asr24_3
    movf math_a_L, w, a
    addwf est_gap_L, f, a
    movf math_a_M, w, a
    addwfc est_gap_M, f, a
    movf math_a_H, w, a
    addwfc est_gap_H, f, a
    return

_est_seed_gap:
    movff deq_dur_H, est_gap_H
    movff deq_dur_M, est_gap_M
    movff deq_dur_L, est_gap_L
    return

; asr24_3 — arithmetic right shift math_a_H:M:L by 3 (signed)
asr24_3:
    ; Shift 1
    btfsc math_a_H, 7, a    ; preserve sign
    bsf STATUS, 0, a        ; set C if negative
    btfss math_a_H, 7, a
    bcf STATUS, 0, a
    rrcf math_a_H, f, a
    rrcf math_a_M, f, a
    rrcf math_a_L, f, a
    ; Shift 2
    btfsc math_a_H, 7, a
    bsf STATUS, 0, a
    btfss math_a_H, 7, a
    bcf STATUS, 0, a
    rrcf math_a_H, f, a
    rrcf math_a_M, f, a
    rrcf math_a_L, f, a
    ; Shift 3
    btfsc math_a_H, 7, a
    bsf STATUS, 0, a
    btfss math_a_H, 7, a
    bcf STATUS, 0, a
    rrcf math_a_H, f, a
    rrcf math_a_M, f, a
    rrcf math_a_L, f, a
    return

; =============================================================================
;  CLASSIFIER — Adaptive threshold, short/long classification
;  threshold = 2 * est_gap (left shift by 1)
;  Result: WREG = 'S' (short/dit) or 'L' (long/dah)
;  Input: deq_dur_H/M/L holds pulse duration
; =============================================================================
update_threshold:
    ; threshold = est_gap << 1
    bcf STATUS, 0, a        ; clear carry
    rlcf est_gap_L, w, a
    movwf threshold_L, a
    rlcf est_gap_M, w, a
    movwf threshold_M, a
    rlcf est_gap_H, w, a
    movwf threshold_H, a
    return

; classify_pulse — compare deq_dur to threshold
; Returns WREG = 'S' or 'L', also stores in deq_type as 0=short 1=long
classify_pulse:
    call update_threshold
    ; 24-bit unsigned compare: deq_dur > threshold => LONG
    movf threshold_H, w, a
    subwf deq_dur_H, w, a   ; dur_H - thr_H
    btfss STATUS, 2, a      ; Z? (equal so far)
    bra _cls_decide
    movf threshold_M, w, a
    subwf deq_dur_M, w, a
    btfss STATUS, 2, a
    bra _cls_decide
    movf threshold_L, w, a
    subwf deq_dur_L, w, a
_cls_decide:
    ; C=1 if dur >= thr (no borrow), C=0 if dur < thr
    btfss STATUS, 0, a
    bra _cls_short
    ; LONG (dah)
    movlw 0x01
    movwf deq_type, a        ; reuse deq_type: 1=long
    movlw 'L'
    return
_cls_short:
    clrf deq_type, a         ; 0=short
    movlw 'S'
    return

; =============================================================================
;  MORSE DECODER — binary-tree lookup
;  morse_bits accumulates classification: bit=0 for dit, bit=1 for dah
;  morse_len counts symbols collected so far
;  On character gap: lookup morse_bits/morse_len, output char, reset
;  On word gap: also insert space
; =============================================================================

; morse_accumulate — add dit(0) or dah(1) based on deq_type (0=short,1=long)
morse_accumulate:
    bcf STATUS, 0, a        ; clear carry
    btfsc deq_type, 0, a    ; if dah, set carry
    bsf STATUS, 0, a
    rlcf morse_bits, f, a   ; shift in from right
    incf morse_len, f, a
    return

; morse_decode — look up current morse_bits/morse_len, output char
; Returns decoded ASCII in WREG ('?' if unknown)
morse_decode:
    movf morse_len, w, a
    btfsc STATUS, 2, a      ; if len==0, nothing to decode
    retlw '?'

    ; Compute tree index: (1 << morse_len) + morse_bits - 1
    ; This maps to a flat binary tree: root=0, children of node i at 2i+1, 2i+2
    ; But simpler: use (1<<len)-1+bits as offset into table
    movf morse_len, w, a
    call _pow2               ; WREG = (1 << morse_len), max len ~6 so fits byte
    addwf morse_bits, w, a   ; + morse_bits
    addlw -1                 ; -1 to make 0-based
    ; Bounds check: offset must be < 63
    sublw 62
    btfss STATUS, 0, a      ; C=1 if offset <= 62
    retlw '?'               ; out of bounds
    sublw 62                 ; restore offset

    ; Table read
    movwf math_b_H, a       ; save offset
    movlw low highword(morse_table)
    movwf TBLPTRU, a
    movlw high(morse_table)
    movwf TBLPTRH, a
    movlw low(morse_table)
    movwf TBLPTRL, a
    movf math_b_H, w, a
    addwf TBLPTRL, f, a
    btfsc STATUS, 0, a
    incf TBLPTRH, f, a
    tblrd*
    movf TABLAT, w, a

    ; Reset state for next character
    clrf morse_bits, a
    clrf morse_len, a
    return

; _pow2 — returns 1 << WREG (WREG 0-7). Result in WREG.
_pow2:
    movwf math_b_L, a       ; save shift count
    movlw 1
    movwf math_b_M, a       ; accumulator = 1
    tstfsz math_b_L, a
    bra _pow2_lp
    movf math_b_M, w, a     ; count was 0, return 1
    return
_pow2_lp:
    bcf STATUS, 0, a
    rlcf math_b_M, f, a     ; accumulator <<= 1
    decfsz math_b_L, f, a
    bra _pow2_lp
    movf math_b_M, w, a
    return

; morse_reset — clear decoder state
morse_reset:
    clrf morse_bits, a
    clrf morse_len, a
    return

; check_char_gap — returns C=1 if deq_dur >= 3*est_gap
check_char_gap:
    ; 3*est_gap = est_gap + (est_gap << 1)
    ; Compute in math_a = est_gap << 1
    bcf STATUS, 0, a
    rlcf est_gap_L, w, a
    movwf math_a_L, a
    rlcf est_gap_M, w, a
    movwf math_a_M, a
    rlcf est_gap_H, w, a
    movwf math_a_H, a
    ; math_a += est_gap
    movf est_gap_L, w, a
    addwf math_a_L, f, a
    movf est_gap_M, w, a
    addwfc math_a_M, f, a
    movf est_gap_H, w, a
    addwfc math_a_H, f, a
    ; Compare deq_dur >= math_a (3*est_gap)
    movf math_a_H, w, a
    subwf deq_dur_H, w, a
    btfss STATUS, 2, a
    bra _ccg_decide
    movf math_a_M, w, a
    subwf deq_dur_M, w, a
    btfss STATUS, 2, a
    bra _ccg_decide
    movf math_a_L, w, a
    subwf deq_dur_L, w, a
_ccg_decide:
    return                   ; C=1 if dur >= 3*gap

; check_word_gap — returns C=1 if deq_dur >= 7*est_gap
check_word_gap:
    ; 7*est_gap = (est_gap << 3) - est_gap
    ; est_gap << 3
    movff est_gap_L, math_a_L
    movff est_gap_M, math_a_M
    movff est_gap_H, math_a_H
    bcf STATUS, 0, a
    rlcf math_a_L, f, a
    rlcf math_a_M, f, a
    rlcf math_a_H, f, a     ; x2
    bcf STATUS, 0, a
    rlcf math_a_L, f, a
    rlcf math_a_M, f, a
    rlcf math_a_H, f, a     ; x4
    bcf STATUS, 0, a
    rlcf math_a_L, f, a
    rlcf math_a_M, f, a
    rlcf math_a_H, f, a     ; x8
    ; Subtract est_gap: math_a = 8*gap - gap = 7*gap
    movf est_gap_L, w, a
    subwf math_a_L, f, a
    movf est_gap_M, w, a
    subwfb math_a_M, f, a
    movf est_gap_H, w, a
    subwfb math_a_H, f, a
    ; Compare deq_dur >= math_a
    movf math_a_H, w, a
    subwf deq_dur_H, w, a
    btfss STATUS, 2, a
    bra _cwg_decide
    movf math_a_M, w, a
    subwf deq_dur_M, w, a
    btfss STATUS, 2, a
    bra _cwg_decide
    movf math_a_L, w, a
    subwf deq_dur_L, w, a
_cwg_decide:
    return                   ; C=1 if dur >= 7*gap

; =============================================================================
;  STRING CONSTANTS (program memory)
; =============================================================================
    PSECT strings, class=CODE, reloc=2

str_banner:
    DB 'M','O','R','S','E',' ','D','E','C','O','D','E','R',' '
    DB 'v','0','.','1',0x0D,0x0A,0x00

; =============================================================================
;  MORSE BINARY-TREE LOOKUP TABLE (program memory)
;  Index = (1 << len) + bits - 1,  0-based, 63 entries
;  Tree layout:
;    depth 1: index 0-1   (E, T)
;    depth 2: index 2-5   (I, A, N, M)
;    depth 3: index 6-13  (S, U, R, W, D, K, G, O)
;    depth 4: index 14-29 (H, V, F, _, L, _, P, J, B, X, C, Y, Z, Q, _, _)
;    depth 5: index 30-61 (5, 4, _, 3, _, _, _, 2, _, _, +, _, _, _, _, 1,
;                           6, =, /, _, _, _, _, _, 7, _, _, _, 8, _, 9, 0)
;    index 62: padding
;  '?' = invalid / unused code
; =============================================================================
    PSECT morsetbl, class=CODE, reloc=2

morse_table:
    ; depth 1 (index 0-1): dit=E, dah=T
    DB 'E','T'
    ; depth 2 (index 2-5): I A N M
    DB 'I','A','N','M'
    ; depth 3 (index 6-13): S U R W D K G O
    DB 'S','U','R','W','D','K','G','O'
    ; depth 4 (index 14-29)
    DB 'H','V','F','?','L','?','P','J'
    DB 'B','X','C','Y','Z','Q','?','?'
    ; depth 5 (index 30-61)
    DB '5','4','?','3','?','?','?','2'
    DB '?','?','+','?','?','?','?','1'
    DB '6','=','/','?','?','?','?','?'
    DB '7','?','?','?','8','?','9','0'
    ; index 62: padding
    DB '?'

    END
