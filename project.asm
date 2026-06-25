#include p16f877a.inc
#define PORT_LCD  PORTD
#define TRIS_LCD  TRISD 
#define LCD_RST   0    ; RD0 - Reset (active low)
#define LCD_DC    1    ; RD1 - Data/Command select
#define LCD_CE    2    ; RD2 - Chip Enable (active low)
#define BTN_PORT  PORTB
#define BTN_TRIS  TRISB 
; Push Buttons (active low) 
#define BTN_SEL   4
#define BTN_ENT   5
#define BTN_BCK   6
  CBLOCK 0x20
W_TEMP,STATUS_TEMP,CURRENT_MENU,SYSTEM_MODE,FLAGS,CLEAR_CTR_HI,CLEAR_CTR_LO
  endc
  CBLOCK 0x27
TICK_COUNT,CLK_SEC,CLK_MIN,CLK_HOUR,SW_MS,SW_SEC,SW_MI,SW_HOUR,Index,Digit,FONT_TEMP,First_Digit,Second_Digit,clkTickFlag,HSLM_POS,HSLM_TICK,COLON_STATE,BTN_LOCK
  endc
#define TICK_FLG     FLAGS,0      ; set by ISR each Timer0 overflow
#define BTN_SEL_FLG  FLAGS,1      ; SELECT pressed this tick
#define BTN_ENT_FLG  FLAGS,2      ; ENTER  pressed this tick
#define BTN_BCK_FLG  FLAGS,3      ; BACK   pressed this tick
#define CLK_UPD_FLG  FLAGS,4      ; (reserved) clock update pending
#define SW_UPD_FLG   FLAGS,5      ; (reserved) stopwatch update pending
#define SW_RUNNING   FLAGS,6      ; 1 = stopwatch is counting

#define BTN_SEL_LOCK BTN_LOCK,0   ; prevents repeat-fire while held
#define BTN_ENT_LOCK BTN_LOCK,1
#define BTN_BCK_LOCK BTN_LOCK,2

;  PROJECT: Multi-Mode Display System (PIC16F877A + Nokia 5110 LCD)
;  MODES:
;    0x00 - Clock       (HH:MM:SS with blinking separators)
;    0x01 - Stopwatch   (HH:MM:SS, Start/Stop via ENTER button)
;    0x02 - HSLM        (Scrolling horizontal marquee animation)
;    0xFF - Main Menu   (SELECT cycles items, ENTER opens, BACK returns)
;  HARDWARE:
;    LCD  -> PORTD (SPI via MSSP): RST=RD0, DC=RD1, CE=RD2
;    BTNs -> PORTB (active-low):   SEL=RB4, ENT=RB5, BCK=RB6
;    Timer0 ISR fires every ~1ms  (Prescaler 1:256, Fosc=4MHz)
;    77 ticks = ~1 second

    org 0x00
    goto START_INITIALIZE  ; reset vector --> initialization
    org 0x04               ; interrupt vector
    
    ;ISR - Timer0 Overflow Handler \  Fires every ~1ms.
ISR:
    MOVWF W_TEMP                
    SWAPF STATUS, W       ; save W
    MOVWF STATUS_TEMP     ; save STATUS (swap avoids affecting flags)
    
    BTFSS INTCON,T0IF     ; was this a Timer0 interrupt?
    GOTO  ISR_EXIT        ; no  -> skip
    BCF   INTCON, T0IF    ; yes -> clear flag
    
    INCF  TICK_COUNT,F    ; count the tick
    BSF   TICK_FLG        ; signal main loop
ISR_EXIT:
    SWAPF STATUS_TEMP, W  ; restore STATUS
    MOVWF STATUS              
    SWAPF W_TEMP, F       ; restore W (swap trick: no flag change)
    SWAPF W_TEMP, W          
    RETFIE                  
      
START_INITIALIZE:
    BANKSEL TRIS_LCD
    CLRF    TRIS_LCD           ;LCD port: all outputs
    ;Timer0 setup
    CALL    INIT_TIMER0           
    ;Button pins : inputs
    BANKSEL BTN_TRIS
    BSF     BTN_TRIS, BTN_SEL   
    BSF     BTN_TRIS, BTN_ENT  
    BSF     BTN_TRIS, BTN_BCK 
    ;SPI (MSSP) + LCD init    
    call    INIT_MSSP
    call    INITIALIZE_LCD
    call    CLEAR_SCREEN
    ;Variable reset 
    MOVLW   0xFF
    MOVWF   SYSTEM_MODE        ;start in main-menu state 
    CLRF    CURRENT_MENU       ;cursor on first item (Clock)
    CLRF    FLAGS
    CLRF    BTN_LOCK
    ;Clock default: 12:00:00
    MOVLW   d'12'
    MOVWF   CLK_HOUR
    CLRF    CLK_MIN
    CLRF    CLK_SEC
    CLRF    COLON_STATE
    ;HSLM default position
    CLRF    HSLM_TICK
    MOVLW   D'60'
    MOVWF   HSLM_POS
    ;Draw main menu and enter loop 
    CALL    SHOW_MAIN_MENU
    GOTO    MAIN

    ;INIT_TIMER0:Prescaler 1:256, internal clock. 
    ;~1ms overflow at 4MHz.
    ;Enables GIE + T0IE.
INIT_TIMER0:
    BANKSEL OPTION_REG           
    MOVLW   b'00000111' ; TOCS=0 (internal), PS=111 (1:256) 
    MOVWF   OPTION_REG
    BANKSEL TMR0
    CLRF    TMR0
    BANKSEL INTCON
    MOVLW   b'11100000' ; GIE=1, PEIE=1, T0IE=1
    MOVWF   INTCON    
    RETURN 
    
    ;INIT_MSSP --> Configures hardware SPI: Master, Fosc/4, CKP=0 (idle low), CKE=0.
    ;RC3=SCLK (output), RC5=SDIN (output).    
INIT_MSSP:     
    BSF     STATUS,RP0   ; Bank1        
    BCF     TRISC, 3     ; RC3 = SCLK  OUTPUT 
    BCF     TRISC, 5     ; RC5 = SDIN  OUTPUT
    CLRF    SSPSTAT      ; SMP(bit7)=0 (sample middle) , CKE(bit6)=0 (rising edge)
    BCF     STATUS,RP0   ; Bank0
    ;SSPM3:SSPM0(bit3-0)= 0000 (SPI Master Fosc/4)
    ;SSPEN(bit5)=1 MSSP is ON / CKP(bit4)=0 LOW to HIGH
    MOVLW   B'00100000'    
    MOVWF   SSPCON
    BCF     PIR1 , SSPIF  ; clear any stale SPI flag    
    RETURN
          
    ;  INITIALIZE_LCD : Hardware reset pulse, then extended-instruction-set configuration.                
INITIALIZE_LCD:
    BCF     PORT_LCD, LCD_RST  ; pull RST low 
    NOP
    NOP
    BSF     PORT_LCD, LCD_RST  ; release RST
    
    BCF     STATUS, C          ; C=0 --- command mode
    MOVLW   0x21               ; extended instruction mode  
    CALL    SEND_CMD 
    MOVLW   0xBF               ; set VOP    
    CALL    SEND_CMD 
    MOVLW   0x04               ; temperature coefficient  
    CALL    SEND_CMD
    MOVLW   0x14               ; bias system (1:48) 
    CALL    SEND_CMD
    MOVLW   0x20               ; normal instruction mode  
    CALL    SEND_CMD 
    MOVLW   0x0C               ;display on, normal mode 
    CALL    SEND_CMD
    
    BCF     STATUS,RP0 
    RETURN 
    
    
    ;MAIN LOOP : Waits for the TICK_FLG set by the ISR, then:
    ;1. Runs per-tick math (HSLM animation + 1-second counters)
    ;2. Polls buttons and routes to actions 
MAIN: 
    BTFSS TICK_FLG            ; wait for ISR tick
    GOTO  MAIN
    BCF   TICK_FLG            ; acknowledge tick
     
    CALL  StartCounter        ; update timers / displays
    CALL  RUN_POLL_INTERFACES ; check buttons
    GOTO  MAIN
    
RUN_POLL_INTERFACES:
    GOTO    POLL_INTERFACES 
    
    ;TICK PROCESSING - StartCounter : Called every tick (~1ms).
    ;Always runs HSLM animation sub-tick.
    ;Every 77 ticks: updates clock, optionally updates stopwatch,
    ;then refreshes the active screen.        
StartCounter:
   BSF     INTCON, T0IE   ; ensure Timer0 interrupt is enabled
   CALL    HSLM_MATH      ; animation runs every tick
   
   MOVLW   d'77'          ; 77 ticks ~ 1 second
   SUBWF   TICK_COUNT, W
   BTFSS   STATUS, Z
   RETURN                 ; not a second yet
   
   CLRF    TICK_COUNT     ; reset accumulator
   
   CALL    CLOCK_MATH     ; clock always runs
   BTFSS   SW_RUNNING     ; stopwatch runs only if SW_RUNNING = 1
   GOTO    REFRESH_ACTIVE_SCREEN
   CALL    STOPWATCH_MATH
   
REFRESH_ACTIVE_SCREEN:
   MOVF    SYSTEM_MODE, W
   XORLW   0x00
   BTFSC   STATUS, Z
   CALL    UpdateClock    ; refresh clock display
   
   MOVF    SYSTEM_MODE, W
   XORLW   0x01
   BTFSC   STATUS, Z
   CALL    UpdateStopWatch ; refresh stopwatch display
   RETURN
   

;HSLM ANIMATION MATH : Fires every 8 ticks (not every second).
;Moves the HSLM sprite one pixel left; wraps at 0 back to column 48.
;Only draws when SYSTEM_MODE == 0x02 (HSLM screen is open).
HSLM_MATH:
   INCF    HSLM_TICK, F
   MOVLW   d'8'
   SUBWF   HSLM_TICK, W
   BTFSS   STATUS, Z
   RETURN                 ; not 8 ticks yet

   CLRF    HSLM_TICK      ; reset sub-tick
   
   MOVF    SYSTEM_MODE, W ; only animate on HSLM screen
   XORLW   0x02
   BTFSS   STATUS, Z
   RETURN

   DECF    HSLM_POS, F    ; move sprite left
   MOVF    HSLM_POS, F    ; check if reached 0
   BTFSS   STATUS, Z
   GOTO    HSLM_DRAW_NOW
   MOVLW   D'48'          ; wrap: reset to right edge
   MOVWF   HSLM_POS
   
HSLM_DRAW_NOW:
   CALL    DrawHSLMScreen
   RETURN
   
;CLOCK MATH(called every second)
;Increments SEC -> MIN -> HOUR with rollover (24-hour format).
;Also toggles COLON_STATE for blinking separators.
CLOCK_MATH:
   MOVLW   0x01
   XORWF   COLON_STATE, F       ; bonus: blink clock separators
   
   INCF    CLK_SEC, F
   MOVLW   d'60'
   SUBWF   CLK_SEC, W
   BTFSS   STATUS, Z
   RETURN                       ; seconds not rolled over
   
   CLRF    CLK_SEC
   INCF    CLK_MIN, F

   MOVLW   d'60'
   SUBWF   CLK_MIN, W
   BTFSS   STATUS, Z
   RETURN

   CLRF    CLK_MIN
   INCF    CLK_HOUR, F

   MOVLW   d'24'
   SUBWF   CLK_HOUR, W
   BTFSS   STATUS, Z
   RETURN

   CLRF    CLK_HOUR             ; midnight rollover
   RETURN

;STOPWATCH MATH(called every second, only when SW_RUNNING=1)
;Increments SEC -> MIN -> HOUR with same rollover logic as clock.
STOPWATCH_MATH:
   INCF    SW_SEC, F
   MOVLW   d'60'
   SUBWF   SW_SEC, W
   BTFSS   STATUS, Z
   RETURN

   CLRF    SW_SEC
   INCF    SW_MI, F

   MOVLW   d'60'
   SUBWF   SW_MI, W
   BTFSS   STATUS, Z
   RETURN

   CLRF    SW_MI
   INCF    SW_HOUR, F

   MOVLW   d'24'
   SUBWF   SW_HOUR, W
   BTFSS   STATUS, Z
   RETURN

   CLRF    SW_HOUR
   RETURN
   

;SEND_CMD   W -> PCD8544 as a command byte  (DC=0)
;SEND_DATA  W -> PCD8544 as a data byte     (DC=1)
;SEND_INV_DATA  inverts W then calls SEND_DATA  (used for highlighted text)       

SEND_CMD:
    BCF     STATUS, RP0              
    BCF     PORT_LCD, LCD_DC  ;Command Mode  DC=0
    BCF     PORT_LCD, LCD_CE  ;Enable Chip Select (Pull CE Low)
    MOVWF   SSPBUF            ;Start SPI transmission      
WAIT_SPI_CMD:
    BCF     STATUS, RP0       
    BTFSS   PIR1, SSPIF       ;Wait for transfer complete
    GOTO    WAIT_SPI_CMD      
    BCF     PIR1, SSPIF       
    BCF     STATUS, RP0       
    BSF     PORT_LCD, LCD_CE  ;Disable Chip Select (Pull CE High)
    RETURN
     
SEND_DATA:
    BCF     STATUS, RP0          
    BSF     PORT_LCD, LCD_DC  ;Data Mode DC=1  
    BCF     PORT_LCD, LCD_CE  ;Enable Chip Select (Pull CE Low)
    MOVWF   SSPBUF            ;Start ISP transmission  
WAIT_SPI_DATA:
    BCF     STATUS, RP0       
    BTFSS   PIR1, SSPIF       ;Wait for transfer complete
    GOTO    WAIT_SPI_DATA     
    BCF     PIR1, SSPIF       
    BCF     STATUS, RP0       
    BSF     PORT_LCD, LCD_CE  ;Disable Chip Select (Pull CE High)
    RETURN
    
SEND_INV_DATA:
    XORLW   0xFF              ;Invert all bits (highlight effect)
    CALL    SEND_DATA
    RETURN
  
;SET_LCD_ROW   W = row (0-5)
;Positions cursor to the start of the requested page row.  
SET_LCD_ROW:   
   MOVWF   W_TEMP              
   MOVF    W_TEMP, W           
   ANDLW   0x07                ;ensure row is strictly between 0 and 7 
   IORLW   0x40                ;PCD8544 Set Y-Address command    
   CALL    SEND_CMD                    
   MOVLW   0x80                ;PCD8544 Set X-Address command (column 0)   
   CALL    SEND_CMD                  
   RETURN
    
;CLEAR_SCREEN:Fills all 84x6 = 504 bytes with 0x00, then resets cursor to top-left.                   
CLEAR_SCREEN:
    ; Set X address = 0
    MOVLW   0x80
    CALL    SEND_CMD
    ; Set Y address = 0
    MOVLW   0x40
    CALL    SEND_CMD
    ; LCD size = 84 columns * 6 banks = 504 bytes
    MOVLW   D'6'        ; 6 pages
    MOVWF   CLEAR_CTR_HI
CLEAR_PAGE_LOOP:
    MOVLW   D'84'       ; 84 columns per page
    MOVWF   CLEAR_CTR_LO
CLEAR_COL_LOOP:
    MOVLW   0x00
    CALL    SEND_DATA      ; IMPORTANT: SEND_DATA, not SEND_CMD
    DECFSZ  CLEAR_CTR_LO, F
    GOTO    CLEAR_COL_LOOP
    DECFSZ  CLEAR_CTR_HI, F
    GOTO    CLEAR_PAGE_LOOP
    ; Put cursor back to top-left
    MOVLW   0x80
    CALL    SEND_CMD
    MOVLW   0x40
    CALL    SEND_CMD
    RETURN
       

;BUTTON HANDLING:
;1.CHECK_BUTTONS:Reads all three buttons.  
;Each button uses a lock bit so only one event
;fires per press (no auto-repeat).
;Sets BTN_xxx_FLG on falling edge.   
CHECK_BUTTONS:
    BANKSEL BTN_PORT
    
;SELECT button: (RB4/active low/one event per press).
    BTFSC   BTN_PORT, BTN_SEL
    GOTO    SEL_RELEASED
    BTFSC   BTN_SEL_LOCK      ; already locked? -> no new event
    GOTO    CHK_ENTER
    BSF     BTN_SEL_FLG       ; new press
    BSF     BTN_SEL_LOCK
    GOTO    CHK_ENTER
SEL_RELEASED:
    BCF     BTN_SEL_LOCK      ; unlock when released

;ENTER button: (RB5/active low/one event per press).
CHK_ENTER:
    BTFSC   BTN_PORT, BTN_ENT
    GOTO    ENT_RELEASED
    BTFSC   BTN_ENT_LOCK
    GOTO    CHK_BACK
    BSF     BTN_ENT_FLG
    BSF     BTN_ENT_LOCK
    GOTO    CHK_BACK
ENT_RELEASED:
    BCF     BTN_ENT_LOCK

;BACK button: (RB6/active low/one event per press).
CHK_BACK:
    BTFSC   BTN_PORT, BTN_BCK
    GOTO    BCK_RELEASED
    BTFSC   BTN_BCK_LOCK
    RETURN
    BSF     BTN_BCK_FLG
    BSF     BTN_BCK_LOCK
    RETURN
BCK_RELEASED:
    BCF     BTN_BCK_LOCK
    RETURN
    
;2.INPUT ROUTING --> (POLL_INTERFACES) 
;Priority: SELECT -> ENTER -> BACK
;SELECT: cycles CURRENT_MENU (only in main menu), redraws menu.
;ENTER:  opens the selected mode -OR- toggles stopwatch start/stop.
;BACK:   returns to main menu from any mode.  
POLL_INTERFACES:    
    CALL    CHECK_BUTTONS       ; read buttons and set BTN_SEL_FLG, BTN_ENT_FLG, BTN_BCK_FLG
    ;SELECT: cycle through menu items
    BTFSS   BTN_SEL_FLG         ; was SELECT pressed this tick?       
    GOTO    ROUTE_ENTER         ; no -> skip to ENTER check
    BCF     BTN_SEL_FLG         ; yes -> clear flag (acknowledge)
    
    ; SELECT only works when we are on the main menu (SYSTEM_MODE = 0xFF).
    ; If we're inside a mode screen, ignore SELECT completely.        
    MOVF    SYSTEM_MODE, W      ; only cycle if on main menu   
    XORLW   0xFF                ; XOR with 0xFF: result=0 only if SYSTEM_MODE=0xFF
    BTFSS   STATUS, Z           ; Z=1 -> we are on the menu
    GOTO    ROUTE_ENTER         ; Z=0 -> inside a mode, ignore SELECT    
    
    INCF    CURRENT_MENU, F     ; move cursor to next menu item
    MOVLW   D'3'                
    SUBWF   CURRENT_MENU, W     ; check if we passed the last item (3 items: 0,1,2)
    BTFSC   STATUS, Z          
    CLRF    CURRENT_MENU        ; Wrap back around to 0
    CALL    SHOW_MAIN_MENU      ; redraw menu with new selection highlighted 
   
    ;ENTER: open mode or toggle stopwatch
ROUTE_ENTER:    
    BTFSS   BTN_ENT_FLG         ; was ENTER pressed?  
    GOTO    ROUTE_BACK     
    BCF     BTN_ENT_FLG 
            
    MOVF    SYSTEM_MODE, W      
    XORLW   0xFF                ;  are we on the main menu?
    BTFSS   STATUS, Z     
    GOTO    STOPWATCH_TOGGLE    ; inside a mode -> ENTER = start/stop stopwatch
    
    ; On main menu: open the selected mode
    MOVF    CURRENT_MENU, W     ; CURRENT_MENU holds which item is selected (0/1/2)  
    MOVWF   SYSTEM_MODE         ; set SYSTEM_MODE to that mode
    CALL    CLEAR_SCREEN        
    CALL    OPEN_MODE_SCREEN    ; draw the mode's screen   
    GOTO    ROUTE_BACK
    
    ;BACK: return to main menu
ROUTE_BACK:
    BTFSS   BTN_BCK_FLG         
    GOTO    LOOP_END            
    BCF     BTN_BCK_FLG 
            
    MOVLW   0xFF                
    MOVWF   SYSTEM_MODE         ; return to main menu
    BCF     SW_RUNNING          ; stop stopwatch
    CALL    CLEAR_SCREEN        
    CALL    SHOW_MAIN_MENU 
         
LOOP_END:
    RETURN                      ; return to MAIN after CALL RUN_POLL_INTERFACES


;MAIN MENU DISPLAY  (SHOW_MAIN_MENU):
;Draws all three mode labels on the LCD.
;The currently selected item is drawn INVERTED; others are normal.
;Row layout:  Row 0 = CLOCK,  Row 2 = STOPWATCH,  Row 4 = HSLM.
SHOW_MAIN_MENU:
    CALL    CLEAR_SCREEN

    MOVF    CURRENT_MENU, W 
    XORLW   0x00
    BTFSS   STATUS, Z       
    GOTO    MENU_CHECK_STOPWATCH

CLOCK_SELECTED:
    MOVLW   D'0'
    CALL    SET_LCD_ROW
    CALL    PRINT_CLOCK_INVERTED
    MOVLW   D'2'
    CALL    SET_LCD_ROW
    CALL    PRINT_STOPWATCH_NORMAL
    MOVLW   D'4'
    CALL    SET_LCD_ROW
    CALL    PRINT_HSLM_NORMAL
    RETURN

MENU_CHECK_STOPWATCH:
    MOVF    CURRENT_MENU, W
    XORLW   0x01
    BTFSS   STATUS, Z
    GOTO    HSLM_SELECTED
    
STOPWATCH_SELECTED:
    MOVLW   D'0'
    CALL    SET_LCD_ROW
    CALL    PRINT_CLOCK_NORMAL
    MOVLW   D'2'
    CALL    SET_LCD_ROW
    CALL    PRINT_STOPWATCH_INVERTED
    MOVLW   D'4'
    CALL    SET_LCD_ROW
    CALL    PRINT_HSLM_NORMAL
    RETURN
    
HSLM_SELECTED:
    MOVLW   D'0'
    CALL    SET_LCD_ROW
    CALL    PRINT_CLOCK_NORMAL
    MOVLW   D'2'
    CALL    SET_LCD_ROW
    CALL    PRINT_STOPWATCH_NORMAL
    MOVLW   D'4'
    CALL    SET_LCD_ROW
    CALL    PRINT_HSLM_INVERTED
    RETURN
    

;MODE SCREEN OPENERS   
OPEN_MODE_SCREEN:
    MOVF    SYSTEM_MODE, W
    XORLW   0x00
    BTFSC   STATUS, Z
    GOTO    OPEN_CLOCK_MODE

    MOVF    SYSTEM_MODE, W
    XORLW   0x01
    BTFSC   STATUS, Z
    GOTO    OPEN_STOPWATCH_MODE

    MOVF    SYSTEM_MODE, W
    XORLW   0x02
    BTFSC   STATUS, Z
    GOTO    OPEN_HSLM_MODE

    RETURN
    
;Clock Mode     
OPEN_CLOCK_MODE:
    CALL    DrawClockScreen
    RETURN

DrawClockScreen:
    CALL    CLEAR_SCREEN

    MOVLW   D'0'
    CALL    SET_LCD_ROW        
    CALL    PRINT_CLOCK_NORMAL ; label on row 0
    CALL    UpdateClock        ; time digits on row 2
    RETURN


;UpdateClock:Draws HH:MM:SS on LCD page 2 (row 1).
;Column positions: HH = 0x95/0x9B, MM = 0xA5/0xAB, SS = 0xB5/0xBB.
;Separators blink based on COLON_STATE.
UpdateClock:
    MOVLW   0x42                 ; always force page 2 before drawing time
    CALL    SEND_CMD

    ; blinking separators
    MOVLW   0xA1                 
    CALL    SEND_CMD
    CALL    DRAW_CLOCK_SEPARATOR

    MOVLW   0xB1
    CALL    SEND_CMD
    CALL    DRAW_CLOCK_SEPARATOR

    ; seconds
    MOVF    CLK_SEC, W
    CALL    SPLIT_2DIGIT
    MOVLW   0xB5
    CALL    SEND_CMD
    MOVF    Second_Digit, W
    MOVWF   Digit
    CALL    Send_Font_Digit
    MOVLW   0xBB
    CALL    SEND_CMD
    MOVF    First_Digit, W
    MOVWF   Digit
    CALL    Send_Font_Digit

    ; minutes
    MOVF    CLK_MIN, W
    CALL    SPLIT_2DIGIT
    MOVLW   0xA5
    CALL    SEND_CMD
    MOVF    Second_Digit, W
    MOVWF   Digit
    CALL    Send_Font_Digit
    MOVLW   0xAB
    CALL    SEND_CMD
    MOVF    First_Digit, W
    MOVWF   Digit
    CALL    Send_Font_Digit

    ; hours
    MOVF    CLK_HOUR, W
    CALL    SPLIT_2DIGIT
    MOVLW   0x95
    CALL    SEND_CMD
    MOVF    Second_Digit, W
    MOVWF   Digit
    CALL    Send_Font_Digit
    MOVLW   0x9B
    CALL    SEND_CMD
    MOVF    First_Digit, W
    MOVWF   Digit
    CALL    Send_Font_Digit

    RETURN

;HSLM Mode 
OPEN_HSLM_MODE:
    CLRF    HSLM_TICK
    MOVLW   D'60'
    MOVWF   HSLM_POS
    CALL    CLEAR_SCREEN
    CALL    DrawHSLMScreen
    RETURN

DrawHSLMScreen:
    CALL    CLEAR_HSLM_ROW    ; erase only row 3
    MOVLW   0x43              ; set page to row 3
    CALL    SEND_CMD
    MOVF    HSLM_POS, W
    ADDLW   0x80              ; X-address command + position
    CALL    SEND_CMD
    CALL    PRINT_HSLM_NORMAL ;draw sprite
    RETURN

CLEAR_HSLM_ROW:
    MOVLW   0x43              ; page 3 only
    CALL    SEND_CMD
    MOVLW   0x80              ; X = 0 (column 0)
    CALL    SEND_CMD
    MOVLW   D'84'
    MOVWF   CLEAR_CTR_LO
CLEAR_HSLM_ROW_LOOP:
    MOVLW   0x00
    CALL    SEND_DATA
    DECFSZ  CLEAR_CTR_LO, F
    GOTO    CLEAR_HSLM_ROW_LOOP
    RETURN


;Stopwatch Mode
OPEN_STOPWATCH_MODE:             
    CLRF    TICK_COUNT                      
    CLRF    SW_SEC
    CLRF    SW_MI
    CLRF    SW_HOUR
    CALL    DrawStopWatchScreen
    RETURN
    
DrawStopWatchScreen:
    CALL    CLEAR_SCREEN
    
    MOVLW   D'0'
    CALL    SET_LCD_ROW
    CALL    PRINT_STOPWATCH_NORMAL  ; label on row 0
    MOVLW   D'3'
    CALL    SET_LCD_ROW
    CALL    UpdateStopWatch
    RETURN
        

;UpdateStopWatch:Stopwatch digits, same column layout as UpdateClock.     
UpdateStopWatch:
    MOVLW   0x42
    CALL    SEND_CMD

    MOVLW   0xA1
    CALL    SEND_CMD
    CALL    DRAW_CLOCK_SEPARATOR

    MOVLW   0xB1
    CALL    SEND_CMD
    CALL    DRAW_CLOCK_SEPARATOR

    ; seconds
    MOVF SW_SEC, W
    CALL SPLIT_2DIGIT
    MOVLW 0xB5
    CALL  SEND_CMD
    MOVF Second_Digit, W
    MOVWF Digit
    CALL Send_Font_Digit
    MOVLW 0xBB
    CALL SEND_CMD
    MOVF First_Digit, W
    MOVWF Digit
    CALL Send_Font_Digit
    
    ; minutes
    MOVF SW_MI,W
    CALL SPLIT_2DIGIT
    MOVLW 0xA5
    CALL SEND_CMD
    MOVF Second_Digit, W
    MOVWF Digit
    CALL Send_Font_Digit
    MOVLW 0xAB
    CALL SEND_CMD
    MOVF First_Digit, W
    MOVWF Digit
    CALL Send_Font_Digit
    
    ; hours
    MOVF SW_HOUR, W
    CALL SPLIT_2DIGIT
    MOVLW 0x95
    CALL SEND_CMD
    MOVF Second_Digit, W
    MOVWF Digit
    CALL Send_Font_Digit
    MOVLW 0x9B
    CALL SEND_CMD
    MOVF First_Digit, W
    MOVWF Digit
    CALL Send_Font_Digit
    
    RETURN
    

;STOPWATCH_TOGGLE:Toggles SW_RUNNING only when the stopwatch screen is active.    
STOPWATCH_TOGGLE:     
    MOVF    SYSTEM_MODE, W           
    XORLW   0x01                ; are we in stopwatch mode?  
    BTFSS   STATUS, Z           ; Z=1 --> inside the stopwatch module --> skip (not ignore)  
    GOTO    ROUTE_BACK          ; Z=0 --> not inside the stopwatch module --> ignore
    
    MOVLW   B'01000000'         ; mask for SW_RUNNING (FLAGS bit 6)  
    XORWF   FLAGS, F            ; toggle   
    GOTO    ROUTE_BACK          ; Complete action and pass down to BACK button check   


;DRAW_CLOCK_SEPARATOR:
;Draws 3 bytes: either dots (0x14) or blank (0x00) based on COLON_STATE.
;Cursor must already be at the correct X position before calling.
DRAW_CLOCK_SEPARATOR:
    ; COLON_STATE bit0 is toggled every second by CLOCK_MATH.
    ; bit0=0 -> show the dot (colon visible)
    ; bit0=1 -> send blanks (colon hidden)
    BTFSC   COLON_STATE, 0
    GOTO    DRAW_SEPARATOR_BLANK 
    
    ; Draw visible colon: space, dot, space
    MOVLW   0x00
    CALL    SEND_DATA
    MOVLW   0x14
    CALL    SEND_DATA   ; 0x14 = 00010100b = two dots (the colon shape)
    MOVLW   0x00
    CALL    SEND_DATA
    RETURN
    
DRAW_SEPARATOR_BLANK:
    ; Draw invisible colon: three blank columns (erase the dot area)
    MOVLW   0x00
    CALL    SEND_DATA
    MOVLW   0x00
    CALL    SEND_DATA
    MOVLW   0x00
    CALL    SEND_DATA
    RETURN
    
    
;FONT UTILITIES:
;1.SPLIT_2DIGIT --> value (0-99).
;Returns: First_Digit = ones,  Second_Digit = tens.
;Algorithm: subtract 10 repeatedly.
;Example: value=47 -> subtract 10 four times -> First_Digit=7, Second_Digit=4
SPLIT_2DIGIT: 
    MOVWF First_Digit     ; store the full value in First_Digit
    CLRF  Second_Digit    ; tens counter starts at 0
SPLIT_LOOP:
    MOVLW d'10'
    SUBWF First_Digit, W  ; W = First_Digit - 10
    BTFSS STATUS, C       ; C=0 means borrow occurred (First_Digit < 10) -> done
    GOTO  SPLIT_DONE
    MOVWF First_Digit     ; C=1 means result is valid, store remainder
    INCF  Second_Digit, F ; count one more ten
    GOTO  SPLIT_LOOP
SPLIT_DONE:
    ; Now: Second_Digit = tens place, First_Digit = ones place
    RETURN


;2.Send_Font_Digit --> digit (0-9).
;Looks up 5 column bytes in FONT_Table and sends them via SEND_DATA.
;Index = digit * 5.
;PCLATH must be set to 0x05 for the ORG 0x500 table.    
Send_Font_Digit:
    MOVWF   Digit
    MOVWF   W_TEMP
    BCF     STATUS, C            ; clear carry before shifting
    RLF     W_TEMP, F            ; W_TEMP = Digit * 2
    RLF     W_TEMP, F            ; W_TEMP = Digit * 4
    MOVF    W_TEMP, W
    ADDWF   Digit, W             ; W = Digit * 5
    MOVWF   Index                ; Index now points to first byte of this digit in table
    
    MOVLW   0x05
    MOVWF   W_TEMP               ; loop 5 times (one per column byte)
    
D_LOOP_OLD:
    MOVLW   0x05                 ; page 5 for FONT_Table at ORG 0x500
    MOVWF   PCLATH
    MOVF    Index, W
    CALL    FONT_Table           ; returns one column byte in W via RETLW
    CLRF    PCLATH               ; restore PCLATH to page 0 (our code page)
    CALL    SEND_DATA
    INCF    Index, F             ; advance to next byte 
    DECFSZ  W_TEMP, F            ; decrement loop counter, skip next if zero
    GOTO    D_LOOP_OLD           ; not zero -> loop again 
    RETURN
    
    
;TEXT LABEL BITMAPS  (5x8 column-format, 6 bytes per character incl. space)
;Each PRINT_xxx routine sends the raw column data for its label text.
;The Inverted versions XOR each byte with 0xFF for a highlight effect.    

;"CLOCK"
PRINT_CLOCK_INVERTED:
    ; C
    MOVLW   0x3E
    CALL    SEND_INV_DATA
    MOVLW   0x41
    CALL    SEND_INV_DATA
    MOVLW   0x41
    CALL    SEND_INV_DATA
    MOVLW   0x41
    CALL    SEND_INV_DATA
    MOVLW   0x22
    CALL    SEND_INV_DATA
    MOVLW   0x00
    CALL    SEND_INV_DATA
    ; L
    MOVLW   0x7F
    CALL    SEND_INV_DATA
    MOVLW   0x40
    CALL    SEND_INV_DATA
    MOVLW   0x40
    CALL    SEND_INV_DATA
    MOVLW   0x40
    CALL    SEND_INV_DATA
    MOVLW   0x40
    CALL    SEND_INV_DATA
    MOVLW   0x00
    CALL    SEND_INV_DATA
    ; O
    MOVLW   0x3E
    CALL    SEND_INV_DATA
    MOVLW   0x41
    CALL    SEND_INV_DATA
    MOVLW   0x41
    CALL    SEND_INV_DATA
    MOVLW   0x41
    CALL    SEND_INV_DATA
    MOVLW   0x3E
    CALL    SEND_INV_DATA
    MOVLW   0x00
    CALL    SEND_INV_DATA
    ; C
    MOVLW   0x3E
    CALL    SEND_INV_DATA
    MOVLW   0x41
    CALL    SEND_INV_DATA
    MOVLW   0x41
    CALL    SEND_INV_DATA
    MOVLW   0x41
    CALL    SEND_INV_DATA
    MOVLW   0x22
    CALL    SEND_INV_DATA
    MOVLW   0x00
    CALL    SEND_INV_DATA
    ; K
    MOVLW   0x7F
    CALL    SEND_INV_DATA
    MOVLW   0x08
    CALL    SEND_INV_DATA
    MOVLW   0x14
    CALL    SEND_INV_DATA
    MOVLW   0x22
    CALL    SEND_INV_DATA
    MOVLW   0x41
    CALL    SEND_INV_DATA
    MOVLW   0x00
    CALL    SEND_INV_DATA
    RETURN
    
PRINT_CLOCK_NORMAL:
    ; C
    MOVLW   0x3E
    CALL    SEND_DATA
    MOVLW   0x41
    CALL    SEND_DATA
    MOVLW   0x41
    CALL    SEND_DATA
    MOVLW   0x41
    CALL    SEND_DATA
    MOVLW   0x22
    CALL    SEND_DATA
    MOVLW   0x00
    CALL    SEND_DATA
    ; L
    MOVLW   0x7F
    CALL    SEND_DATA
    MOVLW   0x40
    CALL    SEND_DATA
    MOVLW   0x40
    CALL    SEND_DATA
    MOVLW   0x40
    CALL    SEND_DATA
    MOVLW   0x40
    CALL    SEND_DATA
    MOVLW   0x00
    CALL    SEND_DATA
    ; O
    MOVLW   0x3E
    CALL    SEND_DATA
    MOVLW   0x41
    CALL    SEND_DATA
    MOVLW   0x41
    CALL    SEND_DATA
    MOVLW   0x41
    CALL    SEND_DATA
    MOVLW   0x3E
    CALL    SEND_DATA
    MOVLW   0x00
    CALL    SEND_DATA
    ; C
    MOVLW   0x3E
    CALL    SEND_DATA
    MOVLW   0x41
    CALL    SEND_DATA
    MOVLW   0x41
    CALL    SEND_DATA
    MOVLW   0x41
    CALL    SEND_DATA
    MOVLW   0x22
    CALL    SEND_DATA
    MOVLW   0x00
    CALL    SEND_DATA
    ; K
    MOVLW   0x7F
    CALL    SEND_DATA
    MOVLW   0x08
    CALL    SEND_DATA
    MOVLW   0x14
    CALL    SEND_DATA
    MOVLW   0x22
    CALL    SEND_DATA
    MOVLW   0x41
    CALL    SEND_DATA
    MOVLW   0x00
    CALL    SEND_DATA
    RETURN
    
;"STOPWATCH"    
PRINT_STOPWATCH_INVERTED:
    ; S
    MOVLW   0x46
    CALL    SEND_INV_DATA
    MOVLW   0x49
    CALL    SEND_INV_DATA
    MOVLW   0x49
    CALL    SEND_INV_DATA
    MOVLW   0x49
    CALL    SEND_INV_DATA
    MOVLW   0x31
    CALL    SEND_INV_DATA
    MOVLW   0x00
    CALL    SEND_INV_DATA
    ; T
    MOVLW   0x01
    CALL    SEND_INV_DATA
    MOVLW   0x01
    CALL    SEND_INV_DATA
    MOVLW   0x7F
    CALL    SEND_INV_DATA
    MOVLW   0x01
    CALL    SEND_INV_DATA
    MOVLW   0x01
    CALL    SEND_INV_DATA
    MOVLW   0x00
    CALL    SEND_INV_DATA
    ; O
    MOVLW   0x3E
    CALL    SEND_INV_DATA
    MOVLW   0x41
    CALL    SEND_INV_DATA
    MOVLW   0x41
    CALL    SEND_INV_DATA
    MOVLW   0x41
    CALL    SEND_INV_DATA
    MOVLW   0x3E
    CALL    SEND_INV_DATA
    MOVLW   0x00
    CALL    SEND_INV_DATA
    ; P
    MOVLW   0x7F
    CALL    SEND_INV_DATA
    MOVLW   0x09
    CALL    SEND_INV_DATA
    MOVLW   0x09
    CALL    SEND_INV_DATA
    MOVLW   0x09
    CALL    SEND_INV_DATA
    MOVLW   0x06
    CALL    SEND_INV_DATA
    MOVLW   0x00
    CALL    SEND_INV_DATA
    ; W
    MOVLW   0x7F
    CALL    SEND_INV_DATA
    MOVLW   0x20
    CALL    SEND_INV_DATA
    MOVLW   0x18
    CALL    SEND_INV_DATA
    MOVLW   0x20
    CALL    SEND_INV_DATA
    MOVLW   0x7F
    CALL    SEND_INV_DATA
    MOVLW   0x00
    CALL    SEND_INV_DATA
    ; A
    MOVLW   0x7E
    CALL    SEND_INV_DATA
    MOVLW   0x11
    CALL    SEND_INV_DATA
    MOVLW   0x11
    CALL    SEND_INV_DATA
    MOVLW   0x11
    CALL    SEND_INV_DATA
    MOVLW   0x7E
    CALL    SEND_INV_DATA
    MOVLW   0x00
    CALL    SEND_INV_DATA
    ; T
    MOVLW   0x01
    CALL    SEND_INV_DATA
    MOVLW   0x01
    CALL    SEND_INV_DATA
    MOVLW   0x7F
    CALL    SEND_INV_DATA
    MOVLW   0x01
    CALL    SEND_INV_DATA
    MOVLW   0x01
    CALL    SEND_INV_DATA
    MOVLW   0x00
    CALL    SEND_INV_DATA
    ; C
    MOVLW   0x3E
    CALL    SEND_INV_DATA
    MOVLW   0x41
    CALL    SEND_INV_DATA
    MOVLW   0x41
    CALL    SEND_INV_DATA
    MOVLW   0x41
    CALL    SEND_INV_DATA
    MOVLW   0x22
    CALL    SEND_INV_DATA
    MOVLW   0x00
    CALL    SEND_INV_DATA
    ; H
    MOVLW   0x7F
    CALL    SEND_INV_DATA
    MOVLW   0x08
    CALL    SEND_INV_DATA
    MOVLW   0x08
    CALL    SEND_INV_DATA
    MOVLW   0x08
    CALL    SEND_INV_DATA
    MOVLW   0x7F
    CALL    SEND_INV_DATA
    MOVLW   0x00
    CALL    SEND_INV_DATA
    RETURN
    
PRINT_STOPWATCH_NORMAL:
    ; S
    MOVLW   0x46
    CALL    SEND_DATA
    MOVLW   0x49
    CALL    SEND_DATA
    MOVLW   0x49
    CALL    SEND_DATA
    MOVLW   0x49
    CALL    SEND_DATA
    MOVLW   0x31
    CALL    SEND_DATA
    MOVLW   0x00
    CALL    SEND_DATA
    ; T
    MOVLW   0x01
    CALL    SEND_DATA
    MOVLW   0x01
    CALL    SEND_DATA
    MOVLW   0x7F
    CALL    SEND_DATA
    MOVLW   0x01
    CALL    SEND_DATA
    MOVLW   0x01
    CALL    SEND_DATA
    MOVLW   0x00
    CALL    SEND_DATA
    ; O
    MOVLW   0x3E
    CALL    SEND_DATA
    MOVLW   0x41
    CALL    SEND_DATA
    MOVLW   0x41
    CALL    SEND_DATA
    MOVLW   0x41
    CALL    SEND_DATA
    MOVLW   0x3E
    CALL    SEND_DATA
    MOVLW   0x00
    CALL    SEND_DATA
    ; P
    MOVLW   0x7F
    CALL    SEND_DATA
    MOVLW   0x09
    CALL    SEND_DATA
    MOVLW   0x09
    CALL    SEND_DATA
    MOVLW   0x09
    CALL    SEND_DATA
    MOVLW   0x06
    CALL    SEND_DATA
    MOVLW   0x00
    CALL    SEND_DATA
    ; W
    MOVLW   0x7F
    CALL    SEND_DATA
    MOVLW   0x20
    CALL    SEND_DATA
    MOVLW   0x18
    CALL    SEND_DATA
    MOVLW   0x20
    CALL    SEND_DATA
    MOVLW   0x7F
    CALL    SEND_DATA
    MOVLW   0x00
    CALL    SEND_DATA
    ; A
    MOVLW   0x7E
    CALL    SEND_DATA
    MOVLW   0x11
    CALL    SEND_DATA
    MOVLW   0x11
    CALL    SEND_DATA
    MOVLW   0x11
    CALL    SEND_DATA
    MOVLW   0x7E
    CALL    SEND_DATA
    MOVLW   0x00
    CALL    SEND_DATA
    ; T
    MOVLW   0x01
    CALL    SEND_DATA
    MOVLW   0x01
    CALL    SEND_DATA
    MOVLW   0x7F
    CALL    SEND_DATA
    MOVLW   0x01
    CALL    SEND_DATA
    MOVLW   0x01
    CALL    SEND_DATA
    MOVLW   0x00
    CALL    SEND_DATA
    ; C
    MOVLW   0x3E
    CALL    SEND_DATA
    MOVLW   0x41
    CALL    SEND_DATA
    MOVLW   0x41
    CALL    SEND_DATA
    MOVLW   0x41
    CALL    SEND_DATA
    MOVLW   0x22
    CALL    SEND_DATA
    MOVLW   0x00
    CALL    SEND_DATA
    ; H
    MOVLW   0x7F
    CALL    SEND_DATA
    MOVLW   0x08
    CALL    SEND_DATA
    MOVLW   0x08
    CALL    SEND_DATA
    MOVLW   0x08
    CALL    SEND_DATA
    MOVLW   0x7F
    CALL    SEND_DATA
    MOVLW   0x00
    CALL    SEND_DATA
    RETURN
    
;"HSLM"    
PRINT_HSLM_INVERTED:
    ; H
    MOVLW   0x7F
    CALL    SEND_INV_DATA
    MOVLW   0x08
    CALL    SEND_INV_DATA
    MOVLW   0x08
    CALL    SEND_INV_DATA
    MOVLW   0x08
    CALL    SEND_INV_DATA
    MOVLW   0x7F
    CALL    SEND_INV_DATA
    MOVLW   0x00
    CALL    SEND_INV_DATA
    ; S
    MOVLW   0x46
    CALL    SEND_INV_DATA
    MOVLW   0x49
    CALL    SEND_INV_DATA
    MOVLW   0x49
    CALL    SEND_INV_DATA
    MOVLW   0x49
    CALL    SEND_INV_DATA
    MOVLW   0x31
    CALL    SEND_INV_DATA
    MOVLW   0x00
    CALL    SEND_INV_DATA
    ; L
    MOVLW   0x7F
    CALL    SEND_INV_DATA
    MOVLW   0x40
    CALL    SEND_INV_DATA
    MOVLW   0x40
    CALL    SEND_INV_DATA
    MOVLW   0x40
    CALL    SEND_INV_DATA
    MOVLW   0x40
    CALL    SEND_INV_DATA
    MOVLW   0x00
    CALL    SEND_INV_DATA
    ; M
    MOVLW   0x7F
    CALL    SEND_INV_DATA
    MOVLW   0x02
    CALL    SEND_INV_DATA
    MOVLW   0x0C
    CALL    SEND_INV_DATA
    MOVLW   0x02
    CALL    SEND_INV_DATA
    MOVLW   0x7F
    CALL    SEND_INV_DATA
    MOVLW   0x00
    CALL    SEND_INV_DATA
    RETURN
    
PRINT_HSLM_NORMAL:
    ; H
    MOVLW   0x7F
    CALL    SEND_DATA
    MOVLW   0x08
    CALL    SEND_DATA
    MOVLW   0x08
    CALL    SEND_DATA
    MOVLW   0x08
    CALL    SEND_DATA
    MOVLW   0x7F
    CALL    SEND_DATA
    MOVLW   0x00
    CALL    SEND_DATA
    ; S
    MOVLW   0x46
    CALL    SEND_DATA
    MOVLW   0x49
    CALL    SEND_DATA
    MOVLW   0x49
    CALL    SEND_DATA
    MOVLW   0x49
    CALL    SEND_DATA
    MOVLW   0x31
    CALL    SEND_DATA
    MOVLW   0x00
    CALL    SEND_DATA
    ; L
    MOVLW   0x7F
    CALL    SEND_DATA
    MOVLW   0x40
    CALL    SEND_DATA
    MOVLW   0x40
    CALL    SEND_DATA
    MOVLW   0x40
    CALL    SEND_DATA
    MOVLW   0x40
    CALL    SEND_DATA
    MOVLW   0x00
    CALL    SEND_DATA
    ; M
    MOVLW   0x7F
    CALL    SEND_DATA
    MOVLW   0x02
    CALL    SEND_DATA
    MOVLW   0x0C
    CALL    SEND_DATA
    MOVLW   0x02
    CALL    SEND_DATA
    MOVLW   0x7F
    CALL    SEND_DATA
    MOVLW   0x00
    CALL    SEND_DATA
    RETURN
        
    
;FONT TABLE  (ORG 0x500): Digits 0-9, each 5 bytes (columns). 
;Accessed via PCL jump + PCLATH = 0x05.
;Each RETLW returns one column byte to the caller.
    
    org 0x500
FONT_Table:
   ADDWF PCL, F     ; PCL = PCL + W -> jump to the entry at offset W
; digit 0 (index 0-4).
   RETLW 0x3E
   RETLW 0x51
   RETLW 0x49
   RETLW 0x45
   RETLW 0x3E
; digit 1 (index 5-9).
   RETLW 0x00
   RETLW 0x42
   RETLW 0x7F
   RETLW 0x40
   RETLW 0x00
; digit 2 (index 10-14).
   RETLW 0x42
   RETLW 0x61
   RETLW 0x51
   RETLW 0x49
   RETLW 0x46
; digit 3  (index 15-19).
   RETLW 0x21
   RETLW 0x41
   RETLW 0x45
   RETLW 0x4B
   RETLW 0x31
; digit 4  (index 20-24).
   RETLW 0x18
   RETLW 0x14
   RETLW 0x12
   RETLW 0x7F
   RETLW 0x10
; digit 5  (index 25-29).
   RETLW 0x27
   RETLW 0x45
   RETLW 0x45
   RETLW 0x45
   RETLW 0x39
; digit 6  (index 30-34).
   RETLW 0x3C
   RETLW 0x4A
   RETLW 0x49
   RETLW 0x49
   RETLW 0x30
; digit 7  (index 35-39).
   RETLW 0x01
   RETLW 0x71
   RETLW 0x09
   RETLW 0x05
   RETLW 0x03
; digit 8  (index 40-44).
   RETLW 0x36
   RETLW 0x49
   RETLW 0x49
   RETLW 0x49
   RETLW 0x36
; digit 9  (index 45-49).
   RETLW 0x06
   RETLW 0x49
   RETLW 0x49
   RETLW 0x29
   RETLW 0x1E

;END OF PROGRAM
loop goto loop
     end