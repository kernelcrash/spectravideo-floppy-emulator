spectravideo-floppy-emulator
===========================

More info at https://www.kernelcrash.com/blog/emulating-floppy-drives-on-the-spectravideo-sv-318/


Overview
--------

For the Spectravideo SV-318 and SV-328 home computers.

- Makes your SV-318/328 think it has a Floppy Disk Controller and Floppy Drive attached.
- Uses a cheap STM32F407 board connected directly to the expansion port.
- Emulates the WD179x floppy controller at IO address 0x30.
- Put disk images on a micro SD card
- based on msx-floppy-and-rom-emulator

Notes
-----

Disks are like this 

```
172032 bytes = track 0 with 18 sectors of 128 bytes and
               track 1 to 39 with 17 sectors of 256 bytes
346112 bytes = track 0 side 0 with 18 sectors of 128 bytes and
               track 0 side 1 with 17 sectors of 256 bytes
               track 1 to 39 with both sides 17 sectors of 256 bytes
```

I haven't found that many disk images for the SV-318/328 so testing
is quite minimal (the Disk BASIC disk, and a couple of CPM disks). You should
be able to save back to the disk image. 
 
Wiring it
---------

Using a STM32F407VET6 or STM32F407VGT6 board 
```
   PA2         - wire a button between it and GND. No need for a pullup. This is 'NEXT'
   PA3         - wire a button between it and GND. No need for a pullup. This is 'PREV'
   PE0 to PE15 - A0 to A15
   PD8 to PD15 - D0 to D7
   PC0         - _IORQ

   PC2         - _MREQ

   PC3         - _RD

   GND         - GND
```
If you get a board with a microSD card slot, then this 'standard' wiring of the SD adapter
is fine.

I used a DevEbox stm32f407 board for this project. It has an LED connected to PA1. So there
are various error/failure routines that will attempt to blink this LED. This is easy to change
if your board uses other pins for a status LED. You'd need to update config_gpio_dbg() to 
configure another GPIO as the LED. the blink_pa1 and fancy_blank_pa1 routines are in util.c

Setting up the micro SD card
----------------------------

I tend to format a micro SD card with a smallish partition (less than 1GB) with 
FAT32. Create a spectravideo directory in the root and add disk images 
to that directory (They have to end in .dsk, not .DSK). The order in which you
copy the files to this directory determines the order in which you can cycle
through them (ie. its not alphabetical). 

The WD2793 floppy disk controller support was based on WD1793.c in fMSX by Marat Fayzullin. Note that:

 - Not all the chip is implemented. But most of the stuff you want is.
 - It pretends to be only one drive. But the OS will think it has two.
 - You probably have to power off/on after pressing the NEXT or PREV buttons.


Copying the firmware to the stm32f407 board
-------------------------------------------

There are lots of options for writing firmware with the stm32 chips. There is 
an example of using dfu-util in the transfer.sh script. In order for this to 
work you would need to set the BOOT0 and or BOOT1 settings such that plugging
the board in via usb will show a DFU device. Then you can run transfer.sh. Remove
the BOOT0 or BOOT1 jumpers after you do this.


Technical
---------

It's the same setup as the msx-floppy-and-rom-emulator . Go read the technical detail 
there.



