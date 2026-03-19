; Morse playback for PIC18F87K22.
; UART samples are replayed on RH0; connect RH0 to RD0.

PROCESSOR 18F87K22
#include <xc.inc>

extrn   LCD_Setup, LCD_Write_Message, LCD_Send_Byte_D, LCD_Send_Byte_I

WARMUP_COUNT    EQU 10
END_BYTE        EQU 0xFF
RX_MASK         EQU 0x3F

; Vectors
PSECT resetVec, class=CODE, reloc=2
resetVec:
    goto    start

PSECT ivec_hi, class=CODE, abs
org 0x0008
    goto    ISR_High

; RAM
PSECT udata_acs

d1:             ds 1
d2:             ds 1
d3:             ds 1

press_cnt:      ds 1
gap_cnt:        ds 1
key_state:      ds 1
morse_code:     ds 1
got_element:    ds 1

t_est:          ds 1
threshold:      ds 1
ema_meas:       ds 1

sum_lo:         ds 1
sum_hi:         ds 1
div_tmp:        ds 1

lcd_pos:        ds 1
press_total:    ds 1

run_active:     ds 1
stop_pending:   ds 1
rx_overrun:     ds 1
rx_next:        ds 1
isr_tmp:        ds 1
ready_tick:     ds 1

w_save:         ds 1
status_save:    ds 1
bsr_save:       ds 1
fsr0l_save:     ds 1
fsr0h_save:     ds 1

rx_head:        ds 1
rx_tail:        ds 1

PSECT udata_bank4
rx_buf:         ds 64

; Code
PSECT code, class=CODE, reloc=2

start:
    movlw   0xFF
    movwf   ANCON0, a
    movlw   0xFF
    movwf   ANCON1, a

    movlw   0x62
    movwf   OSCCON, a
WaitForClock:
    btfss   OSCCON, 2, a
    goto    WaitForClock

    bsf     TRISD, 0, a
    bcf     TRISE, 0, a
    bcf     LATE, 0, a
    bcf     TRISC, 6, a
    bsf     TRISC, 7, a
    bcf     TRISJ, 3, a
    bcf     TRISG, 0, a
    bcf     TRISH, 0, a
    bcf     LATH, 0, a

    bsf     LATJ, 3, a
    movlw   100
    movwf   d3, a
_led_1s:
    call    Delay10ms
    decfsz  d3, f, a
    goto    _led_1s
    bcf     LATJ, 3, a

    movlw   0x08
    movwf   BAUDCON1, a
    movlw   0x00
    movwf   SPBRGH1, a
    movlw   0xCF
    movwf   SPBRG1, a
    movlw   0x24
    movwf   TXSTA1, a
    movlw   0x90
    movwf   RCSTA1, a

    bcf     PIR1, 5, a
    bsf     PIE1, 5, a

    call    LCD_Setup

    clrf    press_cnt, a
    clrf    gap_cnt, a
    clrf    key_state, a
    clrf    got_element, a
    clrf    t_est, a
    clrf    threshold, a
    clrf    ema_meas, a
    clrf    sum_lo, a
    clrf    sum_hi, a
    clrf    div_tmp, a
    clrf    lcd_pos, a
    clrf    press_total, a
    clrf    run_active, a
    clrf    stop_pending, a
    clrf    rx_overrun, a
    clrf    rx_next, a
    clrf    isr_tmp, a
    clrf    ready_tick, a
    clrf    rx_head, a
    clrf    rx_tail, a
    movlw   0x01
    movwf   morse_code, a

    movlw   0x81
    movwf   T0CON, a
    movlw   0xEC
    movwf   TMR0H, a
    movlw   0x78
    movwf   TMR0L, a
    bcf     INTCON, 2, a

    bsf     INTCON, 5, a
    bsf     INTCON, 6, a
    bsf     INTCON, 7, a

    call    CRLF
    call    EmitReady
    call    LCD_ShowWarmup

; Main loop
MainLoop:
    bsf     LATG, 0, a
    call    Delay10ms
    bcf     LATG, 0, a

    movf    rx_overrun, w, a
    bz      _sample_key
    clrf    rx_overrun, a
    call    EmitOverrun

_sample_key:
    btfsc   PORTD, 0, a
    goto    KeyIsPressed

KeyIsReleased:
    bcf     LATE, 0, a

    movf    key_state, w, a
    bz      StillReleased

    clrf    key_state, a
    clrf    gap_cnt, a

    movf    press_cnt, w, a
    bnz     HaveMeasuredPress
    movlw   0x01
    movwf   press_cnt, a

HaveMeasuredPress:
    movlw   255
    cpfslt  press_total, a
    goto    _press_total_sat
    incf    press_total, f, a
_press_total_sat:

    movf    t_est, w, a
    bnz     CompareWithThreshold

    movf    press_cnt, w, a
    movwf   t_est, a
    goto    IsDot

CompareWithThreshold:
    call    UpdateThreshold
    movf    threshold, w, a
    cpfslt  press_cnt, a
    goto    IsDash

IsDot:
    movf    press_cnt, w, a
    movwf   ema_meas, a

    movf    press_total, w, a
    sublw   WARMUP_COUNT
    bn      _dot_live
    bz      _dot_last_warmup

    call    EmitWarmupDot
    call    UpdateEstimate
    clrf    press_cnt, a
    movlw   0x01
    movwf   got_element, a
    goto    MainLoop

_dot_last_warmup:
    call    EmitWarmupDot
    call    UpdateEstimate
    clrf    press_cnt, a
    movlw   0x01
    movwf   got_element, a
    call    LCD_ClearForDecode
    goto    MainLoop

_dot_live:
    call    EmitDot
    bcf     STATUS, 0, a
    rlcf    morse_code, f, a
    goto    DoneElement

IsDash:
    call    NormalizeDashForEma

    movf    press_total, w, a
    sublw   WARMUP_COUNT
    bn      _dash_live
    bz      _dash_last_warmup

    call    EmitWarmupDash
    call    UpdateEstimate
    clrf    press_cnt, a
    movlw   0x01
    movwf   got_element, a
    goto    MainLoop

_dash_last_warmup:
    call    EmitWarmupDash
    call    UpdateEstimate
    clrf    press_cnt, a
    movlw   0x01
    movwf   got_element, a
    call    LCD_ClearForDecode
    goto    MainLoop

_dash_live:
    call    EmitDash
    bcf     STATUS, 0, a
    rlcf    morse_code, f, a
    bsf     morse_code, 0, a

DoneElement:
    call    UpdateEstimate
    clrf    press_cnt, a
    movlw   0x01
    movwf   got_element, a
    goto    MainLoop

StillReleased:
    movf    got_element, w, a
    bz      _released_finish_check

    movlw   255
    cpfslt  gap_cnt, a
    goto    _released_finish_check
    incf    gap_cnt, f, a

    movlw   200
    cpfseq  gap_cnt, a
    goto    _released_finish_check

    movf    press_total, w, a
    sublw   WARMUP_COUNT
    bnn     _skip_decode

    call    DecodeMorse

_skip_decode:
    call    ResetCharacter

_released_finish_check:
    call    MaybeFinishPlayback
    call    MaybeEmitIdleReady
    goto    MainLoop

KeyIsPressed:
    bsf     LATE, 0, a

    movf    key_state, w, a
    bnz     StillPressed

    movlw   0x01
    movwf   key_state, a
    clrf    press_cnt, a
    goto    MainLoop

StillPressed:
    movlw   255
    cpfslt  press_cnt, a
    goto    MainLoop
    incf    press_cnt, f, a
    goto    MainLoop

; ISR
ISR_High:
    movwf   w_save, a
    movff   STATUS, status_save
    movff   BSR, bsr_save
    movff   FSR0L, fsr0l_save
    movff   FSR0H, fsr0h_save

    btfsc   PIR1, 5, a
    call    ISR_UART_RX

    btfsc   INTCON, 2, a
    call    ISR_Timer0

    movff   fsr0h_save, FSR0H
    movff   fsr0l_save, FSR0L
    movff   bsr_save, BSR
    movff   status_save, STATUS
    movf    w_save, w, a
    retfie

ISR_UART_RX:
    btfss   RCSTA1, 1, a
    goto    _rx_no_overrun_err
    bcf     RCSTA1, 4, a
    bsf     RCSTA1, 4, a
    movf    RCREG1, w, a
    movlw   0x01
    movwf   rx_overrun, a
    return

_rx_no_overrun_err:
    movf    RCREG1, w, a
    movwf   isr_tmp, a

    movf    rx_head, w, a
    addlw   0x01
    andlw   RX_MASK
    movwf   rx_next, a

    movf    rx_tail, w, a
    xorwf   rx_next, w, a
    bz      _rx_buffer_full

    lfsr    0, rx_buf
    movf    rx_head, w, a
    addwf   FSR0L, f, a
    movlw   0
    addwfc  FSR0H, f, a

    movf    isr_tmp, w, a
    movwf   INDF0, a

    movf    rx_next, w, a
    movwf   rx_head, a
    return

_rx_buffer_full:
    movlw   0x01
    movwf   rx_overrun, a
    return

ISR_Timer0:
    bcf     INTCON, 2, a
    movlw   0xEC
    movwf   TMR0H, a
    movlw   0x78
    movwf   TMR0L, a

    movf    rx_head, w, a
    xorwf   rx_tail, w, a
    bz      _tmr0_done

    lfsr    0, rx_buf
    movf    rx_tail, w, a
    addwf   FSR0L, f, a
    movlw   0
    addwfc  FSR0H, f, a
    movf    INDF0, w, a
    movwf   isr_tmp, a

    incf    rx_tail, f, a
    movlw   RX_MASK
    andwf   rx_tail, f, a

    movf    isr_tmp, w, a
    sublw   END_BYTE
    bz      _tmr0_stop

    movlw   0x01
    movwf   run_active, a
    btfsc   isr_tmp, 0, a
    goto    _tmr0_high

    bcf     LATH, 0, a
    goto    _tmr0_done

_tmr0_high:
    bsf     LATH, 0, a
    goto    _tmr0_done

_tmr0_stop:
    bcf     LATH, 0, a
    clrf    run_active, a
    movlw   0x01
    movwf   stop_pending, a

_tmr0_done:
    return

; Playback finish
MaybeFinishPlayback:
    movf    stop_pending, w, a
    bz      _finish_return

    movf    key_state, w, a
    bnz     _finish_return

    movf    got_element, w, a
    bz      _emit_done_now

    movf    press_total, w, a
    sublw   WARMUP_COUNT
    bnn     _finish_reset

    call    DecodeMorse

_finish_reset:
    call    ResetCharacter

_emit_done_now:
    clrf    stop_pending, a
    call    EmitDone

_finish_return:
    return

ResetCharacter:
    movlw   0x01
    movwf   morse_code, a
    clrf    got_element, a
    clrf    gap_cnt, a
    return

MaybeEmitIdleReady:
    movf    stop_pending, w, a
    bnz     _idle_ready_return
    movf    run_active, w, a
    bnz     _idle_ready_return
    movf    key_state, w, a
    bnz     _idle_ready_return
    movf    got_element, w, a
    bnz     _idle_ready_return

    movf    rx_head, w, a
    xorwf   rx_tail, w, a
    bnz     _idle_ready_return

    movlw   200
    cpfslt  ready_tick, a
    goto    _idle_emit_ready
    incf    ready_tick, f, a
    return

_idle_emit_ready:
    clrf    ready_tick, a
    call    EmitReady

_idle_ready_return:
    return

; Decode
DecodeMorse:
    movlw   ' '
    call    TX
    movlw   '='
    call    TX
    movlw   ' '
    call    TX

    movf    morse_code, w, a
    sublw   0x3F
    bn      DecodeUnknown

    movlw   LOW(mt_base)
    movwf   TBLPTRL, a
    movlw   HIGH(mt_base)
    movwf   TBLPTRH, a
    movlw   (mt_base >> 16) & 0xFF
    movwf   TBLPTRU, a

    movf    morse_code, w, a
    addwf   TBLPTRL, f, a
    movlw   0
    addwfc  TBLPTRH, f, a
    movlw   0
    addwfc  TBLPTRU, f, a

    tblrd*
    movf    TABLAT, w, a
    call    TX
    call    CRLF

    movf    TABLAT, w, a
    call    LCD_Write_Char
    return

DecodeUnknown:
    movlw   '?'
    call    TX
    call    CRLF
    movlw   '?'
    call    LCD_Write_Char
    return

; LCD
LCD_Write_Char:
    call    LCD_Send_Byte_D
    incf    lcd_pos, f, a

    movlw   16
    cpfseq  lcd_pos, a
    goto    _lcd_check_full
    movlw   0xC0
    call    LCD_Send_Byte_I
    movlw   10
    call    LCD_delay_x4us_w
    return

_lcd_check_full:
    movlw   32
    cpfseq  lcd_pos, a
    return
    movlw   0x01
    call    LCD_Send_Byte_I
    movlw   2
    call    LCD_delay_ms_w
    clrf    lcd_pos, a
    return

LCD_ShowWarmup:
    movlw   0x80
    call    LCD_Send_Byte_I
    movlw   10
    call    LCD_delay_x4us_w
    movlw   'W'
    call    LCD_Send_Byte_D
    movlw   'A'
    call    LCD_Send_Byte_D
    movlw   'R'
    call    LCD_Send_Byte_D
    movlw   'M'
    call    LCD_Send_Byte_D
    movlw   'U'
    call    LCD_Send_Byte_D
    movlw   'P'
    call    LCD_Send_Byte_D
    return

LCD_ClearForDecode:
    movlw   0x01
    call    LCD_Send_Byte_I
    movlw   2
    call    LCD_delay_ms_w
    clrf    lcd_pos, a
    return

LCD_delay_ms_w:
    movwf   d1, a
_dms_lp:
    call    Delay10ms
    decfsz  d1, f, a
    goto    _dms_lp
    return

LCD_delay_x4us_w:
    movwf   d1, a
_d4u_lp:
    nop
    nop
    nop
    decfsz  d1, f, a
    goto    _d4u_lp
    return

; Morse table
mt_base:
    DB      '?', '?', 'E', 'T', 'I', 'A', 'N', 'M'
    DB      'S', 'U', 'R', 'W', 'D', 'K', 'G', 'O'
    DB      'H', 'V', 'F', '?', 'L', '?', 'P', 'J'
    DB      'B', 'X', 'C', 'Y', 'Z', 'Q', '?', '?'
    DB      '5', '4', '?', '3', '?', '?', '?', '2'
    DB      '?', '?', '?', '?', '?', '?', '?', '1'
    DB      '6', '?', '?', '?', '?', '?', '?', '?'
    DB      '7', '?', '?', '?', '8', '?', '9', '0'

; EMA helpers
UpdateThreshold:
    movf    t_est, w, a
    addwf   t_est, w, a
    bnc     StoreThreshold
    setf    threshold, a
    return
StoreThreshold:
    movwf   threshold, a
    return

UpdateEstimate:
    clrf    sum_hi, a
    movf    t_est, w, a
    movwf   sum_lo, a
    addwf   sum_lo, f, a
    movlw   0x00
    addwfc  sum_hi, f, a
    movf    t_est, w, a
    addwf   sum_lo, f, a
    movlw   0x00
    addwfc  sum_hi, f, a
    movf    ema_meas, w, a
    addwf   sum_lo, f, a
    movlw   0x00
    addwfc  sum_hi, f, a

    movf    t_est, w, a
    cpfslt  ema_meas, a
    goto    _no_bias
    movlw   3
    addwf   sum_lo, f, a
    movlw   0
    addwfc  sum_hi, f, a
_no_bias:
    bcf     STATUS, 0, a
    rrcf    sum_hi, f, a
    rrcf    sum_lo, f, a
    bcf     STATUS, 0, a
    rrcf    sum_hi, f, a
    rrcf    sum_lo, f, a

    movf    sum_lo, w, a
    movwf   t_est, a
    movf    t_est, w, a
    bnz     UpdateEstimateDone
    movlw   0x01
    movwf   t_est, a
UpdateEstimateDone:
    return

NormalizeDashForEma:
    clrf    ema_meas, a
    movf    press_cnt, w, a
    movwf   div_tmp, a

NormalizeDashLoop:
    movlw   3
    cpfslt  div_tmp, a
    goto    NormalizeDashSubtract
    goto    NormalizeDashDone

NormalizeDashSubtract:
    movlw   3
    subwf   div_tmp, f, a
    incf    ema_meas, f, a
    goto    NormalizeDashLoop

NormalizeDashDone:
    movf    ema_meas, w, a
    bnz     NormalizeDashReturn
    movlw   0x01
    movwf   ema_meas, a

NormalizeDashReturn:
    return

; UART
TX:
WaitTX:
    btfss   PIR1, 4, a
    goto    WaitTX
    movwf   TXREG1, a
    return

CRLF:
    movlw   0x0D
    call    TX
    movlw   0x0A
    call    TX
    return

EmitDot:
    movlw   'D'
    call    TX
    movlw   'O'
    call    TX
    movlw   'T'
    call    TX
    call    CRLF
    return

EmitDash:
    movlw   'D'
    call    TX
    movlw   'A'
    call    TX
    movlw   'S'
    call    TX
    movlw   'H'
    call    TX
    call    CRLF
    return

EmitWarmupDot:
    movlw   'W'
    call    TX
    movlw   '.'
    call    TX
    movlw   'D'
    call    TX
    movlw   'O'
    call    TX
    movlw   'T'
    call    TX
    call    CRLF
    return

EmitWarmupDash:
    movlw   'W'
    call    TX
    movlw   '.'
    call    TX
    movlw   'D'
    call    TX
    movlw   'A'
    call    TX
    movlw   'S'
    call    TX
    movlw   'H'
    call    TX
    call    CRLF
    return

EmitDone:
    movlw   'D'
    call    TX
    movlw   'O'
    call    TX
    movlw   'N'
    call    TX
    movlw   'E'
    call    TX
    call    CRLF
    call    EmitReady
    return

EmitOverrun:
    movlw   'O'
    call    TX
    movlw   'V'
    call    TX
    movlw   'E'
    call    TX
    movlw   'R'
    call    TX
    movlw   'R'
    call    TX
    movlw   'U'
    call    TX
    movlw   'N'
    call    TX
    call    CRLF
    return

EmitReady:
    clrf    ready_tick, a
    movlw   'R'
    call    TX
    movlw   'E'
    call    TX
    movlw   'A'
    call    TX
    movlw   'D'
    call    TX
    movlw   'Y'
    call    TX
    call    CRLF
    return

; Delay
Delay10ms:
    movlw   65
    movwf   d1, a
_d10_outer:
    movlw   100
    movwf   d2, a
_d10_inner:
    decfsz  d2, f, a
    goto    _d10_inner
    decfsz  d1, f, a
    goto    _d10_outer
    movlw   78
    movwf   d2, a
_d10_pad:
    decfsz  d2, f, a
    goto    _d10_pad
    return

    end
