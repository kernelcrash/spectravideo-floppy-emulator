#include "defines.h"
/*
   interrupt.S
   kernel@kernelcrash.com 2020

   Spectravideo SV-318/328 version

   - _MREQ interrupt processing
     - currently does nothing,but left the INT processinging to make it easier to add stuff later
   - _IORQ interrupt processing
     - Emulation of WD2793 Floppy controller (based on WD1793.c in fmsx by Marat Fayzullin)




*/
// Reminders (to me)
//   - Dont put instructions that change status inside an IT block!!
//   - Dont use the 1f, 2b etc style local labels. Use the 1$:, 2$: ones as they have scope between
//     regular labels, whereas 1:, 2: are actually scoped to the whole file
//   - Do the PR bit clear early. Is hard to guarantee it works later. And I don't think a dsb in the
//     IRQ exit does anything 100% useful
//   - Be careful of the optimiser (in the C code, not the assembler code). Best idea is to get things
//     working with -O0, then turn the optimiser on when its all working.
//   - It is obvious to me that this code is super duper time critical. Adding features to the code
//     will eventually make it stop working because 'your code takes to long'. A 'read' from the Z80 side
//     is more time critical as you need to get data on the bus by a certain point and leave it there. Things
//     that I try to remember;
//       - avoid accessing RAM. No push/pop, subroutine calls
//       - try not to stuff up the pipeline

// PC0 is _IORQ

// PC2 is _MREQ

// PC3 is _RD


/* *********************************** */
	.syntax unified
	.cpu cortex-m4
//	.fpu softvfp
    	.fpu fpv4-sp-d16
	.thumb


	// expose init_fpu_regs so we can call it from main()
	.global	init_fpu_regs
	.global	init_fdc
	.global	deactivate_fdc

	.global EXTI0_IRQHandler
	.global EXTI2_IRQHandler
	.global rom_base
	.global low_64k_base
	.global high_64k_base
	.global track_buffer
        .global main_thread_command
        .global main_thread_data
        .global main_thread_actual_track
	.global fdc_write_flush_count


	.extern (rowcache)

/* *********************************** */

/* MACROS */

.macro mov32, reg, val
    movw \reg, #:lower16:\val
    movt \reg, #:upper16:\val
.endm

.macro unrolled_exit_EXTI0
	//dsb
#if defined(DEBUG_EXTI0_END)
        vstr     reg_bit8_high,[r11,ODR]
#endif
	vmov 	r11,reg_fake_stack		// pop r11
	bx	lr
.endm



.macro unrolled_exit_EXTI2
	//dsb
#if defined(DEBUG_EXTI2_END) || defined(DEBUG_EXTI2_ROM_ACCESS) 
	vstr     reg_bit8_high,[r11,ODR]
        
#endif
	vmov 	r11,reg_fake_stack		// pop r11
	bx	lr
.endm


// We probably dont need any delay here as _WR seems to go low when _IORQ goes low
.macro iorq_databus_write_delay
	//.rept 10
	.rept 40
		nop
	.endr
.endm

.macro clear_EXTI0_RTSR
	vstr	reg_zero,[r3,RTSR]
	//ldr	r0,[r3,RTSR]
	//and	r0,#0xfffffffe
	//str	r0,[r3,RTSR]
.endm

.macro set_EXTI0_RTSR
	vstr	reg_bit0_high,[r3,RTSR]
	//ldr	r0,[r3,RTSR]
	//orr	r0,#0x0001
	//str	r0,[r3,RTSR]
.endm

.macro clear_EXTI2_RTSR
	vstr	reg_zero,[r3,RTSR]
	//ldr	r0,[r3,RTSR]
	//and	r0,#0xfffffffb
	//str	r0,[r3,RTSR]
.endm

.macro set_EXTI2_RTSR
	vstr	reg_bit2_high,[r3,RTSR]
	//ldr	r0,[r3,RTSR]
	//orr	r0,#0x0004
	//str	r0,[r3,RTSR]
.endm

.macro mreq_databus_write_delay
	//.rept 25
	.rept 40
		nop
	.endr
.endm

.macro databus_read_extra_delay
	.rept 2
        	nop
	.endr
.endm

.macro mreq_test_delay
	.rept 20
        	nop
	.endr
.endm

// Use the 64K CCM ram as a sort of circular buffer for debugging
.macro log_r0_r1_to_ccm_uses_r12
        vmov    r12,reg_ccmram_log
	tst	r12,#0x8000
	ITTT	EQ
        strbeq    r0,[r12],#1     // store the address 30 to XX 
        strbeq    r1,[r12],#1     // store the byte written
        bfceq     r12,#16,#8      // Really only need to clear bit 16
        vmov    reg_ccmram_log,r12
.endm

.section .rodata

rom_base:
// early versions of the code allowed you to embed a rom file here at compile time. I am now pulling roms from SD card
// and copying to ram
// be careful if you add roms and later delete them. The old ones might be still in the STM32 flash
//.incbin "roms/blank.rom"
//.incbin "roms/NMS8250-DISK.ROM"

.section ccmram
low_64k_base:
	//.lcomm low_64k_base,0x10000

.section bss
	.lcomm high_64k_base,0x10000
	.lcomm track_buffer,2*17*256		// one MFM track double sided
	


        .equ BACKUP_SRAM ,   0x40024000

        .equ PERIPH_BB_BASE     ,   0x42000000                                                                

        .equ PERIPH_BASE     ,   0x40000000                                                                
        .equ PERIPH_BASE_APB1,   (PERIPH_BASE + 0x00000)
        .equ PERIPH_BASE_APB2,   (PERIPH_BASE + 0x10000)
        .equ PERIPH_BASE_AHB1,   (PERIPH_BASE + 0x20000)
        .equ PERIPH_BASE_AHB2,   0x50000000
        .equ PERIPH_BASE_AHB3,   0x60000000

        .equ GPIOA_BASE,   (PERIPH_BASE_AHB1 + 0x0000)                                           
        .equ GPIOB_BASE,   (PERIPH_BASE_AHB1 + 0x0400)
        .equ GPIOC_BASE,   (PERIPH_BASE_AHB1 + 0x0800)
        .equ GPIOD_BASE,   (PERIPH_BASE_AHB1 + 0x0C00)
        .equ GPIOE_BASE,   (PERIPH_BASE_AHB1 + 0x1000)
        .equ GPIOF_BASE,   (PERIPH_BASE_AHB1 + 0x1400)
        .equ GPIOG_BASE,   (PERIPH_BASE_AHB1 + 0x1800)
        .equ GPIOH_BASE,   (PERIPH_BASE_AHB1 + 0x1C00)
        .equ GPIOI_BASE,   (PERIPH_BASE_AHB1 + 0x2000)

	.equ A_TO_B_OFFSET,     (GPIOB_BASE - GPIOA_BASE)

	.equ C_TO_D_OFFSET,     (GPIOD_BASE - GPIOC_BASE)
	.equ C_TO_E_OFFSET,     (GPIOE_BASE - GPIOC_BASE)

        .equ GPIOA_MODER     ,   GPIOA_BASE + 0x00
        .equ GPIOA_OTYPER    ,   GPIOA_BASE + 0x04
        .equ GPIOA_OSPEEDR   ,   GPIOA_BASE + 0x08
        .equ GPIOA_PUPDR     ,   GPIOA_BASE + 0x0C
        .equ GPIOA_IDR       ,   GPIOA_BASE + 0x10
        .equ GPIOA_ODR       ,   GPIOA_BASE + 0x14
        .equ GPIOA_BSRR      ,   GPIOA_BASE + 0x18
        .equ GPIOA_LCKR      ,   GPIOA_BASE + 0x1C
        .equ GPIOA_AFRL      ,   GPIOA_BASE + 0x20
        .equ GPIOA_AFRH      ,   GPIOA_BASE + 0x24

        .equ GPIOB_MODER     ,   GPIOB_BASE + 0x00
        .equ GPIOB_OTYPER    ,   GPIOB_BASE + 0x04
        .equ GPIOB_OSPEEDR   ,   GPIOB_BASE + 0x08
        .equ GPIOB_PUPDR     ,   GPIOB_BASE + 0x0C
        .equ GPIOB_IDR       ,   GPIOB_BASE + 0x10
        .equ GPIOB_ODR       ,   GPIOB_BASE + 0x14
        .equ GPIOB_BSRR      ,   GPIOB_BASE + 0x18
        .equ GPIOB_LCKR      ,   GPIOB_BASE + 0x1C
        .equ GPIOB_AFRL      ,   GPIOB_BASE + 0x20
        .equ GPIOB_AFRH      ,   GPIOB_BASE + 0x24

        .equ GPIOC_MODER     ,   GPIOC_BASE + 0x00
        .equ GPIOC_OTYPER    ,   GPIOC_BASE + 0x04
        .equ GPIOC_OSPEEDR   ,   GPIOC_BASE + 0x08
        .equ GPIOC_PUPDR     ,   GPIOC_BASE + 0x0C
        .equ GPIOC_IDR       ,   GPIOC_BASE + 0x10
        .equ GPIOC_ODR       ,   GPIOC_BASE + 0x14
        .equ GPIOC_BSRR      ,   GPIOC_BASE + 0x18
        .equ GPIOC_LCKR      ,   GPIOC_BASE + 0x1C
        .equ GPIOC_AFRL      ,   GPIOC_BASE + 0x20
        .equ GPIOC_AFRH      ,   GPIOC_BASE + 0x24

        .equ GPIOD_MODER     ,   GPIOD_BASE + 0x00
        .equ GPIOD_OTYPER    ,   GPIOD_BASE + 0x04
        .equ GPIOD_OSPEEDR   ,   GPIOD_BASE + 0x08
        .equ GPIOD_PUPDR     ,   GPIOD_BASE + 0x0C
        .equ GPIOD_IDR       ,   GPIOD_BASE + 0x10
        .equ GPIOD_ODR       ,   GPIOD_BASE + 0x14
        .equ GPIOD_BSRR      ,   GPIOD_BASE + 0x18
        .equ GPIOD_LCKR      ,   GPIOD_BASE + 0x1C
        .equ GPIOD_AFRL      ,   GPIOD_BASE + 0x20
        .equ GPIOD_AFRH      ,   GPIOD_BASE + 0x24

        .equ GPIOE_MODER     ,   GPIOE_BASE + 0x00
        .equ GPIOE_OTYPER    ,   GPIOE_BASE + 0x04
        .equ GPIOE_OSPEEDR   ,   GPIOE_BASE + 0x08
        .equ GPIOE_PUPDR     ,   GPIOE_BASE + 0x0C
        .equ GPIOE_IDR       ,   GPIOE_BASE + 0x10
        .equ GPIOE_ODR       ,   GPIOE_BASE + 0x14
        .equ GPIOE_BSRR      ,   GPIOE_BASE + 0x18
        .equ GPIOE_LCKR      ,   GPIOE_BASE + 0x1C
        .equ GPIOE_AFRL      ,   GPIOE_BASE + 0x20
        .equ GPIOE_AFRH      ,   GPIOE_BASE + 0x24

        .equ MODER           ,   0x00
        .equ OTYPER          ,   0x04
        .equ OSPEEDR         ,   0x08
        .equ IDR             ,   0x10
        .equ ODR             ,   0x14

        .equ SCB_AIRCR       , 0xE000ED0C


        .equ    EXTI_Line0      ,       0x00001
        .equ    EXTI_Line1      ,       0x00002
        .equ    EXTI_Line2      ,       0x00004
        .equ    EXTI_Line4      ,       0x00010
        .equ    EXTI            ,       0x40013c00
        .equ    EXTI_IMR        ,       EXTI + 0x00
        .equ    EXTI_PR         ,       EXTI + 0x14

	.equ	IMR		,	0x00
	.equ	EMR		,	0x04
	.equ	RTSR		,	0x08
	.equ	FTSR		,	0x0c
	.equ	PR		,	0x14


    .equ        SYSCFG_BASE,    0x40013800
    .equ        SYSCFG_EXTICR1, SYSCFG_BASE + 0x08




.section .data
// main_thread_command is actually a register now
main_thread_command:
        .word   0x00000000                      // command word
main_thread_data:
        .word   0x00000000                      // command arg
main_thread_actual_track:
        .word   0x00000000                      // command arg
fdc_write_flush_count:
        .word   0x00000000


.section .text

.type init_fpu_regs, %function
.align 4
.thumb_func
init_fpu_regs:
	movs	r0,#0
	vmov	reg_zero,r0

	movs	r0,#1
	vmov	reg_bit0_high,r0

	movs	r0,#2
	vmov	reg_bit1_high,r0

	mov32	r0,GPIOC_BASE
	vmov	reg_gpioc_base,r0

	movs	r0,#4
	vmov	reg_bit2_high,r0

	mov32	r0,GPIOA_BASE
	vmov	reg_gpioa_base,r0

	mov32	r0, high_64k_base
	vmov	reg_high_64k_base,r0

	mov32	r0, EXTI
	vmov	reg_exti_base,r0

	mov32	r0,0x55550020
	vmov	reg_moder_dataout,r0

	mov32	r0,0x00000020
	vmov	reg_moder_datain,r0


#ifdef ENABLE_KEYBOARD_EMULATION
	mov32	r0,rowcache
	vmov	reg_rowcache,r0
#endif

	mov32	r0,GPIOB_BASE
	vmov	reg_gpiob_base,r0

	movs	r0,#0x40
	vmov	reg_bit6_high,r0

	movs	r0,#0x100
	vmov	reg_bit8_high,r0

	mov32	r0,0x10000000
	vmov	reg_ccmram_log,r0

	// bit31 of reg_fdc_system is used to work out if the fdc is actually active. Default is off
	movs	r0,#0
	vmov	reg_fdc_system,r0

	bx	lr


.type init_fdc, %function
.align 4
.thumb_func
init_fdc:
	movs	r0,#F_TRACK0
	vmov	reg_fdc_status,r0

	movs	r0,#0
	vmov	reg_fdc_track,r0
	vmov	reg_fdc_actual_track,r0

	movs	r0,#0
	vmov	reg_fdc_sector,r0

	movs	r0,#0
	vmov	reg_fdc_data,r0

	movs	r0,#0
	vmov	reg_fdc_irq_drq,r0

	movs	r0,#0
	vmov	reg_fdc_command,r0

	movs	r0,#0
	vmov	reg_fdc_read_length,r0
	vmov	reg_fdc_write_length,r0

	movs	r0,#0
	vmov	reg_track_buffer_ptr,r0

	movs	r0,#(S_RESET|S_HALT)
	orrs	r0,#S_FDC_PRESENT
	vmov	reg_fdc_system,r0

	bx	lr

.type deactivate_fdc, %function
.align 4
.thumb_func
deactivate_fdc:
	movs	r0,#0			// set bit 31 low
	vmov	reg_fdc_system,r0
	bx	lr

// _IORQ Handler. Int on -ve edge
.type EXTI0_IRQHandler, %function
.align 4
.thumb_func
EXTI0_IRQHandler:
	vmov	reg_fake_stack,r11		// effectively s30 is our 'stack'
	vmov	r11,reg_gpioa_base
#ifdef DEBUG_EXTI0_START
        vstr     reg_zero,[r11,ODR]
#endif
	
	
	vmov	r2,reg_gpioc_base
clear_pending_iorq_int:
	vmov	r3,reg_exti_base		// s7 = EXTI
	vstr	reg_bit0_high,[r3,PR]	// clear interrupt

	ldr     r0,[r2, C_TO_E_OFFSET + IDR]            // GPIOE->IDR get the address 
	ldr     r1,[r2,IDR]     // get the portc control pins , but we'll retrieve them again later as _WR may not be stable yet
	tst	r1,#IORQ_MASK
	bne	io_unused	// ignore bogus glitchy interrupts
	
	// Need to ignore the top 8 bits of address bus
	ands	r0,#0x00ff
	tst	r1,#RD_MASK
	IT	NE
	orrne	r0,#0x0100	// set bit 8 if a write
low_io_addresses:
	// big jump table
        tbh.w   [pc,r0,lsl #1]
.include "svi_io_branchtable.S"

io_unused:
        unrolled_exit_EXTI0

// --------------------------------------------------------
// _MREQ Handler. Int on -ve edge
.type EXTI2_IRQHandler, %function
.align 4
.thumb_func
EXTI2_IRQHandler:
	vmov	reg_fake_stack,r11		// effectively s30 is our 'stack'
	vmov	r11,reg_gpioa_base
#ifdef DEBUG_EXTI2_START
	vstr     reg_zero,[r11,ODR]		
#endif
	
	vmov	r2,reg_gpioc_base
clear_pending_mreq_int:
	vmov	r3,reg_exti_base		// s7 = EXTI
	vstr	reg_bit2_high,[r3,PR]	// clear interrupt

mreq_low:
	// read _MREQ and _SLOTSELECT
	ldr	r1,[r2,IDR]     // portC. 
	tst	r1,#MREQ_MASK	// False ints can be generated on rough signal edges. Mitigate
	bne	exit_EXTI2

	// TODO logic here to do something during a mem request

	// We fall through to the exit here because when we get the chance to exit the ISR we really really want to exit quickly to give time back to the main thread
exit_EXTI2:
	unrolled_exit_EXTI2

fdc_unused_read:
        unrolled_exit_EXTI0

fdc_status_read:
#ifdef DEBUG_FDC_STATUS_READ2
	vstr	reg_bit8_high,[r11,ODR]
#endif

	vmov	r1,reg_fdc_status
	mov	r12,r1			// r1 is the value to return on the bus

// see if a seek just finished. Clear BUSY if it has
	mov	r3,reg_main_thread_command
// Make sure 2nd drive reports not ready
	vmov	r0,reg_fdc_system
	
	//tst	r0,#0x02		// bit 1 is drive 1
	//ITE	EQ
	//orreq	r1,#F_NOTREADY		// set drive 1 to not ready
	//andne	r1,#~(F_NOTREADY)	// assume drive 0 selected so make sure F_NOTREADY=0

	ands	r1,#~(F_NOTREADY)	// assume both drives always ready. TODO. Make this better


// check if the command is complete
	lsls	r3,#1		// bit 31 -> C, bit 30 -> N
	bcc	no_command_just_finished
// bit 31 set, so a command just completed

// Is a bit odd, but at this point r1 has the value we want to put on the bus, so we do it now 
// to get it on the bus for as long as possible


	vmov	r3,reg_fdc_irq_drq
	orrs	r3,#WD1793_DRQ
	vmov	reg_fdc_irq_drq,r3

	ands	r1,#~(F_BUSY)		// r1 is the status to shove on the bus now
	ands	r12,#~(F_BUSY)		// r12 is the status to save for next time
	movs	r0,#0
	mov	reg_main_thread_command,r0
	//vstr	reg_zero,[r0]	// clear the main_thread_command
no_command_just_finished:
	lsls	r1,#8
	vmov	r0,reg_moder_dataout
        str     r1,[r2, C_TO_D_OFFSET + ODR] // GPIOD ODR
        str     r0,[r2, C_TO_D_OFFSET + MODER]  // MODER set to outputs
#ifdef DEBUG_FDC_STATUS_READ
	vstr	reg_bit8_high,[r11,ODR]
#endif

// mod the status bits for the next time it is read
	vmov	r0,reg_fdc_command	// check what the last command was
	tst	r0,#0x80
	ITE	NE
	andne    r12,#(F_BUSY|F_NOTREADY|F_READONLY|F_DRQ)	//CMD >= 0x80
	eoreq	r12,#F_INDEX					//CMD < 0x80

2$:	vmov	reg_fdc_status,r12

#ifdef ENABLE_FDC_CCM_LOGGING
	movs	r0,#0x30
	lsrs	r1,#8
	log_r0_r1_to_ccm_uses_r12
#endif

#ifdef DEBUG_FDC_STATUS_READ
	vstr	reg_zero,[r11,ODR]
#endif

// Now finally go back to the code to wait for _IORQ to go high
	vmov	r3,reg_exti_base
	set_EXTI0_RTSR

        vstr     reg_bit0_high,[r3,EMR]   // EXTI_EMR - wait for an event rather than an interrupt on PC0

        vmov	r1,reg_moder_datain
	
	dsb
        sev     // set the event register
        wfe     // clear the event register
// So the 2nd wfe is meant to wait for the +ve edge, but if you get a spurious edge at exactly the time these instructions execute, it can slip through without waiting
        wfe     // wait for +ve edge of _MREQ

	//databus_read_extra_delay

        str     r1,[r2, C_TO_D_OFFSET + MODER]  // MODER set to inputs


	clear_EXTI0_RTSR

        unrolled_exit_EXTI0

fdc_track_read:
	vmov	r1,reg_fdc_track

// get it out on the bus early

	lsls	r1,#8
	vmov	r0,reg_moder_dataout
        str     r1,[r2, C_TO_D_OFFSET + ODR] // GPIOD ODR
        str     r0,[r2, C_TO_D_OFFSET + MODER]  // MODER set to outputs

#ifdef ENABLE_FDC_CCM_LOGGING
	movs	r0,#0x31
	lsrs	r1,#8
	log_r0_r1_to_ccm_uses_r12
#endif

	vmov	r3,reg_exti_base
	set_EXTI0_RTSR

        vstr     reg_bit0_high,[r3,EMR]   // EXTI_EMR - wait for an event rather than an interrupt on PC0

        vmov	r1,reg_moder_datain
	
	dsb
        sev     // set the event register
        wfe     // clear the event register
// So the 2nd wfe is meant to wait for the +ve edge, but if you get a spurious edge at exactly the time these instructions execute, it can slip through without waiting
        wfe     // wait for +ve edge of _MREQ

	//databus_read_extra_delay

        str     r1,[r2, C_TO_D_OFFSET + MODER]  // MODER set to inputs

	clear_EXTI0_RTSR
        unrolled_exit_EXTI0

fdc_sector_read:
	vmov	r1,reg_fdc_sector

	lsls	r1,#8
	vmov	r0,reg_moder_dataout
        str     r1,[r2, C_TO_D_OFFSET + ODR] // GPIOD ODR
        str     r0,[r2, C_TO_D_OFFSET + MODER]  // MODER set to outputs

#ifdef ENABLE_FDC_CCM_LOGGING
	movs	r0,#0x32
	lsrs	r1,#8
	log_r0_r1_to_ccm_uses_r12
#endif

	vmov	r3,reg_exti_base
	set_EXTI0_RTSR

        vstr     reg_bit0_high,[r3,EMR]   // EXTI_EMR - wait for an event rather than an interrupt on PC0

        vmov	r1,reg_moder_datain
	
	dsb
        sev     // set the event register
        wfe     // clear the event register
// So the 2nd wfe is meant to wait for the +ve edge, but if you get a spurious edge at exactly the time these instructions execute, it can slip through without waiting
        wfe     // wait for +ve edge of _MREQ

	//databus_read_extra_delay

        str     r1,[r2, C_TO_D_OFFSET + MODER]  // MODER set to inputs

	clear_EXTI0_RTSR
        unrolled_exit_EXTI0

fdc_data_read:
	vmov	r12,reg_fdc_read_length
	cmp	r12,#0
	bne	1$
// read length is zero so just return the data register. This is an EXTRA DATA READ
	vmov	r1,reg_fdc_data
	lsls	r1,#8
	vmov	r0,reg_moder_dataout
        str     r1,[r2, C_TO_D_OFFSET + ODR] // GPIOD ODR
        str     r0,[r2, C_TO_D_OFFSET + MODER]  // MODER set to outputs
	b	2$

// non zero read length
1$:
	mov32	r0,#track_buffer
	vmov	r3,reg_track_buffer_ptr
	movs	r1,#0
	ldrb	r1,[r0,r3]		// get byte from the track buffer
	vmov	reg_fdc_data,r1		// update the data register

	lsls	r1,#8
	vmov	r0,reg_moder_dataout
        str     r1,[r2, C_TO_D_OFFSET + ODR] // GPIOD ODR
        str     r0,[r2, C_TO_D_OFFSET + MODER]  // MODER set to outputs

	adds	r3,#1			// incr the track_buffer_ptr
	subs	r12,#1			// decr the read length
	vmov	reg_track_buffer_ptr,r3	// update the track_buffer_ptr
	vmov	r3,reg_fdc_sector	// get current sector num
	vmov	reg_fdc_read_length,r12
	mov	r0,#0x1ff
	tst	r12,r0		// see if bottom 9 bits are clear
	//IT	EQ
// must have crossed a sector boundary
	//addseq	r3,#1		// incr the sector number
	vmov	reg_fdc_sector,r3
	cmp	r12,#0
	bne	2$
// All data read
	vmov	r12,reg_fdc_status
	ands	r12,#~(F_DRQ|F_BUSY)
	vmov	reg_fdc_status,r12
	movs	r12,#WD1793_IRQ
	vmov	reg_fdc_irq_drq,r12

// Put some data on the databus
2$:


#ifdef ENABLE_FDC_CCM_LOGGING
	movs	r0,#0x33
	lsrs	r1,#8
	log_r0_r1_to_ccm_uses_r12
#endif

	vmov	r3,reg_exti_base
	set_EXTI0_RTSR

        vstr     reg_bit0_high,[r3,EMR]   // EXTI_EMR - wait for an event rather than an interrupt on PC0

        vmov	r1,reg_moder_datain
	
	dsb
        sev     // set the event register
        wfe     // clear the event register
// So the 2nd wfe is meant to wait for the +ve edge, but if you get a spurious edge at exactly the time these instructions execute, it can slip through without waiting
        wfe     // wait for +ve edge of _MREQ

	//databus_read_extra_delay

        str     r1,[r2, C_TO_D_OFFSET + MODER]  // MODER set to inputs

	clear_EXTI0_RTSR
        unrolled_exit_EXTI0

fdc_ready_read:
	vmov	r1,reg_fdc_irq_drq

	lsls	r1,#8
	vmov	r0,reg_moder_dataout
        str     r1,[r2, C_TO_D_OFFSET + ODR] // GPIOD ODR
        str     r0,[r2, C_TO_D_OFFSET + MODER]  // MODER set to outputs

#ifdef ENABLE_FDC_CCM_LOGGING
        movs    r0,#0x34
	lsrs	r1,#8
        log_r0_r1_to_ccm_uses_r12
#endif

	vmov	r3,reg_exti_base
	set_EXTI0_RTSR

        vstr     reg_bit0_high,[r3,EMR]   // EXTI_EMR - wait for an event rather than an interrupt on PC0

        vmov	r1,reg_moder_datain
	
	dsb
        sev     // set the event register
        wfe     // clear the event register
// So the 2nd wfe is meant to wait for the +ve edge, but if you get a spurious edge at exactly the time these instructions execute, it can slip through without waiting
        wfe     // wait for +ve edge of _MREQ

	//databus_read_extra_delay

        str     r1,[r2, C_TO_D_OFFSET + MODER]  // MODER set to inputs
	clear_EXTI0_RTSR

        unrolled_exit_EXTI0

// TODO: remove this fdc_0x7ffd_read
fdc_0x7ffd_read:

	movs	r1,#0xff	// read FF, because fMSX does this
	//vmov	r3,reg_fdc_system
	//ands	r3,#S_DRIVE
	//IT	EQ
	//andseq	r1,#0xfe	// clear bit 0 for drive 0

	lsls	r1,#8
	vmov	r0,reg_moder_dataout
        str     r1,[r2, C_TO_D_OFFSET + ODR] // GPIOD ODR
        str     r0,[r2, C_TO_D_OFFSET + MODER]  // MODER set to outputs


#ifdef ENABLE_FDC_CCM_LOGGING
	movs    r0,#0x1d
	lsrs	r1,#8
	log_r0_r1_to_ccm_uses_r12
#endif

	vmov	r3,reg_exti_base
	set_EXTI0_RTSR

        vstr     reg_bit0_high,[r3,EMR]   // EXTI_EMR - wait for an event rather than an interrupt on PC0

        vmov	r1,reg_moder_datain
	
	dsb
        sev     // set the event register
        wfe     // clear the event register
// So the 2nd wfe is meant to wait for the +ve edge, but if you get a spurious edge at exactly the time these instructions execute, it can slip through without waiting
        wfe     // wait for +ve edge of _MREQ

	//databus_read_extra_delay

        str     r1,[r2, C_TO_D_OFFSET + MODER]  // MODER set to inputs
	clear_EXTI0_RTSR
	//vstr	reg_zero,[r11,ODR]
        unrolled_exit_EXTI0


fdc_unused_write:
        unrolled_exit_EXTI0



fdc_command_write:
	// D->IRQ=0
	iorq_databus_write_delay
	movs	r3,#0
	vmov	reg_fdc_irq_drq,r3	// reset IRQ request

	ldr	r1,[r2,C_TO_D_OFFSET+IDR]	// read databus again
	lsrs	r1,r1,#8

#ifdef ENABLE_FDC_CCM_LOGGING
	orrs	r0,#0x80
        log_r0_r1_to_ccm_uses_r12
#endif

	mov	r0,r1

	ands	r0,#0xf0
	cmp	r0,#0xD0	// Force interrupt
	bne	1$
// D0 Force interrupt
	//D->RDLength = 0
	movs	r12,#0
	vmov	reg_fdc_read_length,r12

	// D->Cmd=0xD0;
	vmov 	reg_fdc_command,r0

	vmov	r0,reg_fdc_status
	tst	r0,#F_BUSY
	beq	5$
// busy was set, so clear it
	ands	r0,#~F_BUSY		// clear busy bit
	vmov 	reg_fdc_status,r0
	b	6$
// busy was clear
5$:
	//clear all bits. D->R[0]=D->Track[D->Drive]? 0:F_TRACK0
	movs	r0,#0
	vmov	r1,reg_fdc_actual_track
	cmp	r1, #0
	IT	EQ
	moveq	r0,#F_TRACK0
	vmov	reg_fdc_status,r0

// if(V&C_IRQ) D->IRQ=WD1793_IRQ;
6$:	tst	r3,#C_IRQ
	ITT	NE
	movne	r0,#WD1793_IRQ
	vmovne	reg_fdc_irq_drq,r0

7$:	ldr	r1,[r2,IDR]
	tst	r1,#IORQ_MASK
	beq	7$

        unrolled_exit_EXTI0

// all commands except D0
1$:
	vmov	r12,reg_fdc_status
	tst	r12, #F_BUSY
	beq	2$
	// exit if busy
        unrolled_exit_EXTI0
2$:
	movs	r12,#0
	vmov	reg_fdc_status,r12	// reset status
	vmov	reg_fdc_command,r1	// save the full command
	// r0 bits 7 to 4 should be the command
	lsrs	r0,#4
        tbh.w   [pc,r0,lsl #1]
.include "svi_fdc_command_branchtable.S"

fdc_command_unused:
	unrolled_exit_EXTI0

fdc_command_restore:
	movs	r12,#0
	vmov	reg_fdc_track,r12
	vmov	reg_fdc_actual_track,r12
	movs	r12,#0
	orrs	r12,#(F_INDEX|F_TRACK0)
	tst	r1,#C_LOADHEAD
	beq	1$
	orrs	r12,#F_HEADLOAD
1$:	vmov	reg_fdc_status,r12

	movs	r12,#WD1793_IRQ
	vmov	reg_fdc_irq_drq,r12

	ldr	r3,=main_thread_command
	//ldr	r1,[r3,0x08]		// get main thread track num
	//cmp 	r1,r0
	//beq	2$

	movs	r1,#MAIN_THREAD_SEEK_COMMAND
        str     r0,[r3, 0x04]           // write cylinder to seek to 
	mov	reg_main_thread_command,r1
        //str     r1,[r3]                 // write 'SEEK' command

	vmov	r12,reg_fdc_status
	orrs	r12,#F_BUSY
	vmov	reg_fdc_status,r12
2$:
	unrolled_exit_EXTI0

fdc_command_seek:
	vmov	reg_fdc_read_length,reg_zero
	movs	r12,#0
	tst	r1,#C_LOADHEAD
	beq	1$
	orrs	r12,#F_HEADLOAD
1$:	orrs	r12,#F_INDEX
	vmov	r0,reg_fdc_data		// The track num would have been loaded into 'data'
	cmp	r0,#0
	bne	2$
	orrs	r12,#F_TRACK0
2$:	vmov	reg_fdc_status,r12
	vmov	reg_fdc_track,r0	// save 'data' reg into 'track' register
	vmov	reg_fdc_actual_track,r0	// save 'data' reg into actual 'track'
	movs	r12,#WD1793_IRQ
	vmov	reg_fdc_irq_drq,r12

	ldr	r3,=main_thread_command
	ldr	r1,[r3,0x08]		// get main thread track num
	cmp 	r1,r0
	beq	3$

	movs	r1,#MAIN_THREAD_SEEK_COMMAND
        str     r0,[r3, 0x04]           // write cylinder to seek to 
	mov	reg_main_thread_command,r1
        //str     r1,[r3]                 // write 'SEEK' command

	vmov	r12,reg_fdc_status
	orrs	r12,#F_BUSY
	vmov	reg_fdc_status,r12
3$:
// TODO: Need to trigger track loader to load reg_fdc_track
	unrolled_exit_EXTI0

fdc_command_step:
fdc_command_step_and_update:
fdc_command_step_in:
fdc_command_step_in_and_update:
fdc_command_step_out:
fdc_command_step_out_and_update:
	tst	r1,#0x40
	bne	1$
// step . V=(V&~0x20)|D->LastS;
	ands	r1, #~0x20	// clear bit 5
	// 
	vmov	r12,reg_fdc_system
	tst	r12,#S_LASTSTEPDIR
	IT	NE
	orrne	r1,#0x20	// set bit 5 based on the last step
	b	2$

// step in or out . D->LastS=V&0x20
1$:
	vmov	r12,reg_fdc_system
	tst	r3,#0x20	// get the step direction
	ITE	NE
	orrne	r12,#S_LASTSTEPDIR
	andeq	r12,#~S_LASTSTEPDIR
	vmov	reg_fdc_system,r12
2$:
	vmov	r0,reg_fdc_actual_track
	//tst	r12,#S_DRIVE	// check if drive 0 or 1
	//tst	r12,#0x01	// check if drive 0 or 1. TODO. DISABLING FOR NOW
	//bne	3$
	tst	r1,#0x20
	ITE	NE
	subne	r0,#1		// decr track num
	addeq	r0,#1		// incr track num
	tst	r0,#0x80000000		//check if we just went negative
	IT	NE
	movne	r0,#0			// reset to track0

	vmov	reg_fdc_actual_track,r0
3$:
	tst	r1,#C_SETTRACK
	IT	NE
	vmovne	reg_fdc_track,r0

// zero most of fdc_status
	movs	r1,#F_INDEX
	//tst	r12,#S_DRIVE		// r12 still has the system register
	//tst	r12,#0x01
	//bne	4$			// skip checking for track0 if 2nd drive
	cmp	r0,#0
	IT	EQ
	orreq	r1,#F_TRACK0
4$:
	vmov	reg_fdc_status,r1

	movs	r12,#WD1793_IRQ
	vmov	reg_fdc_irq_drq,r12
	
	ldr	r3,=main_thread_command
	ldr	r1,[r3,0x08]		// get main thread track num
	cmp 	r1,r0
	beq	5$

	movs	r1,#MAIN_THREAD_SEEK_COMMAND
        str     r0,[r3, 0x04]           // write cylinder to seek to 
        mov	reg_main_thread_command,r1
        //str     r1,[r3]                 // write 'SEEK' command

	vmov	r12,reg_fdc_status
	orrs	r12,#F_BUSY
	vmov	reg_fdc_status,r12
5$:
	unrolled_exit_EXTI0


fdc_command_read_sector:
	// assume 256 byte sector
	movs	r0,#0		// set to beginning of track
	vmov	r3,reg_fdc_track


	tst	r1,#C_SIDECOMP
	beq	2$
// SIDECOMP is set so work out the side from the C_SIDE bit
	tst	r1,#C_SIDE
	beq	2$
	cmp	r3,#0		// track = is 18 x 128 byte sectors
	ITE	EQ
	addeq	r0,#(18*128)
	addne	r0,#(17*256)
	b	3$

2$:	vmov	r12,reg_fdc_system
	tst	r12,#S_SIDE
	beq	3$
	cmp	r3,#0		// track = is 18 x 128 byte sectors
	ITE	EQ
	addeq	r0,#(18*128)
	addne	r0,#(17*256)

3$:	vmov	r12,reg_fdc_sector
	subs	r12, #1		// sectors are 1 to 17. We need 0 to 16
	IT	MI
	movmi	r12,#0		// adjust it back to zero if it went negative

	cmp	r3,#0
	ITE	EQ
	lsleq	r12,#7		// * 128
	lslne	r12,#8		// * 256

	adds	r0,r12
	vmov	reg_track_buffer_ptr,r0

	movs	r0,#256		// one sector
	cmp	r3,#0
	IT	EQ
	movseq	r0,#128

	tst	r1,#0x10	// Are we reading multiple sectors which I think is 'all sectors until end of track on one side
	beq	1$
	movs	r0,#17		// only implement multiple sectors for 256 byte sectors
	vmov	r3,reg_fdc_sector
	subs	r0,r3
	adds	r0,#1
	lsls	r0,#8		// * 256
1$:	vmov	reg_fdc_read_length,r0

// flags
	vmov	r0,reg_fdc_status
// I think normally BUSY and DRQ are ignored by a Z80 disk driver when doing a read sector. Basically
// if SYSTEM has DRQ high, it assumes data is ready to read. However, if DRQ is not high straight away
// the Z80 program starts polling the STATUS possibly checking the BUSY bit
	orrs	r0,#(F_BUSY|F_DRQ)
	vmov	reg_fdc_status,r0

//2:
	movs	r12,#WD1793_DRQ
	vmov	reg_fdc_irq_drq,r12

	unrolled_exit_EXTI0

fdc_command_write_sector:
	// assume 256 byte sector
	movs	r0,#0		// set to beginning of track

	tst	r1,#C_SIDECOMP
	beq	2$
// SIDECOMP is set so work out the side from the C_SIDE bit
	tst	r1,#C_SIDE
	IT	NE
	addne	r0,#(17*256)
	b	3$

2$:	vmov	r12,reg_fdc_system
	tst	r12,#S_SIDE
	IT	NE
	addne	r0,#(17*256)
3$:	vmov	r12,reg_fdc_sector
	subs	r12, #1		// sectors are 1 to 17. We need 0 to 16
	IT	MI
	movmi	r12,#0		// adjust it back to zero if it went negative

	lsls	r12,#8		// * 256
	adds	r0,r12
	vmov	reg_track_buffer_ptr,r0

	movs	r0,#256		// one sector
	tst	r1,#0x10	// Are we writing multiple sectors which I think is 'all sectors until end of track on one side
	beq	1$
	movs	r0,#17
	vmov	r3,reg_fdc_sector
	subs	r0,r3
	adds	r0,#1
	lsls	r0,#8		// * 256
1$:	vmov	reg_fdc_write_length,r0

// flags
	vmov	r0,reg_fdc_status
// I think normally BUSY and DRQ are ignored by a Z80 disk driver when doing a read sector. Basically
// if SYSTEM has DRQ high, it assumes data is ready to read. However, if DRQ is not high straight away
// the Z80 program starts polling the STATUS possibly checking the BUSY bit
	orrs	r0,#(F_BUSY|F_DRQ)
	vmov	reg_fdc_status,r0

	movs	r12,#WD1793_DRQ
	vmov	reg_fdc_irq_drq,r12

        unrolled_exit_EXTI0

fdc_command_read_address:
	
        unrolled_exit_EXTI0


// ---------------------

fdc_track_write:
	iorq_databus_write_delay
	ldr	r1,[r2,C_TO_D_OFFSET+IDR]	// read databus again
	lsrs	r1,r1,#8

#ifdef ENABLE_FDC_CCM_LOGGING
	orrs	r0,#0x80
	log_r0_r1_to_ccm_uses_r12
#endif

	vmov	r0,reg_fdc_status
	tst	r0,#F_BUSY
	IT	EQ
	vmoveq	reg_fdc_track,r1		// upate track if not busy
        unrolled_exit_EXTI0

fdc_sector_write:
	iorq_databus_write_delay
	ldr	r1,[r2,C_TO_D_OFFSET+IDR]	// read databus again
	lsrs	r1,r1,#8

#ifdef ENABLE_FDC_CCM_LOGGING
	movs	r0,#0x32
	orrs	r0,#0x80
	log_r0_r1_to_ccm_uses_r12
#endif

	vmov	r0,reg_fdc_status
	tst	r0,#F_BUSY
	IT	EQ
	vmoveq	reg_fdc_sector,r1

        unrolled_exit_EXTI0

fdc_data_write:
	iorq_databus_write_delay
	ldr	r1,[r2,C_TO_D_OFFSET+IDR]	// read databus again
	lsrs	r1,r1,#8

#ifdef ENABLE_FDC_CCM_LOGGING
	movs	r0,#0x33
	orrs	r0,#0x80
	log_r0_r1_to_ccm_uses_r12
#endif

	vmov	reg_fdc_data,r1
	vmov	r12,reg_fdc_write_length
	cmp	r12,#0
	bne	1$
	unrolled_exit_EXTI0

// WRITE DATA TO SECTOR. non zero write length
1$:
	mov32	r0,#track_buffer
	vmov	r3,reg_track_buffer_ptr
	strb	r1,[r0,r3]		// store byte in track buffer

	adds	r3,#1			// incr the track_buffer_ptr
	subs	r12,#1			// decr the write length
	vmov	reg_track_buffer_ptr,r3	// update the track_buffer_ptr
	vmov	r3,reg_fdc_sector	// get current sector num
	vmov	reg_fdc_write_length,r12
	mov	r0,#0xff
	tst	r12,r0		// see if bottom 8 bits are clear (wont work for track 0)
	//IT	EQ
// must have crossed a sector boundary
	//addseq	r3,#1		// incr the sector number
	vmov	reg_fdc_sector,r3
	cmp	r12,#0
	bne	2$
// All data written
	vmov	r12,reg_fdc_status
	ands	r12,#~(F_DRQ|F_BUSY)
	vmov	reg_fdc_status,r12
	movs	r12,#WD1793_IRQ
	vmov	reg_fdc_irq_drq,r12
	mov32	r0,#FDC_WRITE_FLUSH_DEFAULT
	ldr	r1,=fdc_write_flush_count
	str	r0,[r1]				// trigger write after some delay
2$:
        unrolled_exit_EXTI0

// -----------------
fdc_density_side_write:
	iorq_databus_write_delay
	ldr	r1,[r2,C_TO_D_OFFSET+IDR]	// read databus again
	lsrs	r1,r1,#8

#ifdef ENABLE_FDC_CCM_LOGGING
	orrs	r0,#0x80
	log_r0_r1_to_ccm_uses_r12
#endif

	vmov	r12,reg_fdc_system
	tst	r1,#1		// density
	ITE	NE
	orrne	r12,#S_DENSITY
	andeq	r12,#~(S_DENSITY)
	tst	r1,#2		// side
	ITE	NE
	orrne	r12,#S_SIDE
	andeq	r12,#~(S_SIDE)
	vmov	reg_fdc_system,r12

        unrolled_exit_EXTI0

fdc_driveselect_write:
	iorq_databus_write_delay
	ldr	r1,[r2,C_TO_D_OFFSET+IDR]	// read databus again
	lsrs	r1,r1,#8
#ifdef ENABLE_FDC_CCM_LOGGING
	orrs	r0,#0x80
	log_r0_r1_to_ccm_uses_r12
#endif

	vmov	r12,reg_fdc_system
	and	r12,#~(0x03)			// bits 0 and 1 are drive select. bit0=0 for drive 0, bit1=0 for drive 1
	and	r1,#(0x03)			
	orrs	r12,r1
	vmov	reg_fdc_system,r12

        unrolled_exit_EXTI0




