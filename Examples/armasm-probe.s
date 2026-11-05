; armasm encoding probe for ARM Sim.
; Assemble with Keil (Cortex-M3 target, e.g. LPC1768) and send back Listings\armasm-probe.lst.
; Each line checks one encoding choice where the native assembler is not yet verified.
; The code is never executed: only the encodings matter.

                AREA    |.text|, CODE, READONLY
                THUMB
                EXPORT  probe
probe           PROC
; 1. STMFD/STMDB SP! and LDMFD with low registers + LR/PC: 16-bit PUSH/POP or 32-bit?
                STMFD   SP!, {R4, LR}
                STMDB   SP!, {R0-R7, LR}
                LDMFD   SP!, {R4, PC}
                LDMIA   SP!, {R0-R3}
                STMFD   SP!, {R8}               ; single high register
                PUSH    {R8}
                STMIA   R0!, {R1, R2}
                LDMIA   R0, {R0, R1}

; 2. MOV with an immediate that is BOTH a modified immediate and a 16-bit value: MOV.W or MOVW?
                MOV     R0, #0x5600
                MOV     R0, #0xFF00
                MOV     R0, #0x1234             ; only MOVW possible
                MOV     R8, #255
                LDR     R0, =0x5600             ; LDR= with MOV-able constant
                LDR     R0, =0x1234             ; LDR= with MOVW-only constant
                LDR     R0, =0xFFFFFFFE         ; MVN-able
                MOVS    R0, #0x5600

; 3. Conditional instructions without IT: one implicit IT each, or merged blocks?
                CMP     R0, #1
                MOVEQ   R1, #1
                MOVEQ   R2, #2
                CMP     R0, #2
                MOVEQ   R1, #1
                MOVNE   R1, #2
                CMP     R0, #3
                ADDGT   R1, R1, #1
                ADDGT   R2, R2, #1
                ADDGT   R3, R3, #1
                ADDGT   R4, R4, #1
                ADDGT   R5, R5, #1              ; 5th: a new block?
                CMP     R0, #4
                MOVEQ   R1, #1
                BEQ     probe_end               ; branch after a conditional
                MOVLT   R1, #3
label_in_between
                MOVLT   R2, #3                  ; label between two conditionals

; 4. Other choices worth checking
                ADDS    R0, R0, #1              ; imm3 or imm8 encoding
                ADDS    R0, #1
                SUBS    R1, R1, #7
                ADD     R0, R0, #-4             ; SUB substitution
                CMP     R0, #-1                 ; CMP.W #-1 or CMN #1
                AND     R0, R0, #0xFFFFFF00     ; BIC substitution
                ALIGN   8                       ; padding in code
probe_end       BX      LR
                ENDP
                END
