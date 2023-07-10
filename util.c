#include "util.h"

// probably have to tweak these if the processor speed changes. Just have to be rough
void delay_us(const uint16_t us)
{
   uint32_t i = us * 60;
   while (i-- > 0) {
      __asm volatile ("nop");
   }
}

void delay_ms(const uint16_t ms)
{
   //uint32_t i = ms * 27778;
   uint32_t i = ms * 30000 *2;
   while (i-- > 0) {
      __asm volatile ("nop");
   }
}

void blink_pa6_pa7(int delay) {
        while(1) {
                GPIOA->ODR = 0x0040;
                delay_ms(delay);
                GPIOA->ODR = 0x0080;
                delay_ms(delay);
        }
}

void blink_pa6(int delay) {
        while(1) {
                GPIOA->ODR = 0x0040;
                delay_ms(delay);
                GPIOA->ODR = 0x0000;
                delay_ms(delay);
        }
}

void blink_pa7(int delay) {
        while(1) {
                GPIOA->ODR = 0x0080;
                delay_ms(delay);
                GPIOA->ODR = 0x0000;
                delay_ms(delay);
        }
}

void blink_pa1(int delay) {
        while(1) {
                GPIOA->ODR = 0x0002;
                delay_ms(delay);
                GPIOA->ODR = 0x0000;
                delay_ms(delay);
        }
}

void fancy_blink_pa1(int count1, int delay1, int count2, int delay2) {
	int x,y;
        while(1) {
		for (x=0; x<count1;x++) {
                	GPIOA->ODR = 0x0002;
                	delay_ms(delay1);
                	GPIOA->ODR = 0x0000;
                	delay_ms(delay1);
		}

		for (y=0; y<count2;y++) {
                	GPIOA->ODR = 0x0002;
                	delay_ms(delay2);
                	GPIOA->ODR = 0x0000;
                	delay_ms(delay2);
		}
        }
}

void toggle_pa1() {
	GPIOA->ODR ^= 0x0002;
}

uint32_t suffix_match(char *name, char *suffix) {
	if (strlen(name)>strlen(suffix)) {
		if (strncasecmp (&name[strlen(name)-strlen(suffix)],suffix,strlen(suffix)) == 0) {
			return TRUE;
		}
	}
	return FALSE;
}


// TODO . left load_directory in but not used
// buffer[0] is the command/status
// buffer[2] is the number of entries read
// buffer[0x80 - 0xff] is where the menu program writes the rom/dsk to load
// buffer[0x100 - 0x17f] is the first file in the directory
// buffer[0x180 - 0x1ff] is the 2nd file
// buffer[0x200 - 0x27f] is the 3rd and so on
// buffer should be 16K so at 128bytes per filename you kind of are limited to 126 files
void load_directory(char *dirname, unsigned char*buffer) {
	FRESULT res;
        DIR dir;
        static FILINFO fno;
	int file_index;
	int i;

	memset(&dir, 0, sizeof(DIR));
        res = f_opendir(&dir, (TCHAR *) dirname);
        if (res != FR_OK) {
                blink_pa6_pa7(2000);
        }

	file_index=0;
	while (file_index<126) {
		res = f_readdir(&dir, &fno);
		if (res != FR_OK || fno.fname[0] == 0) {
			break;
		}
		i=0;
		do {
			buffer[0x100+(file_index*0x80)+i] = fno.fname[i];
			if (i>126) {
				buffer[0x100+(file_index*0x100)+i]=0;
				break;
			}
		} while (fno.fname[i++]!=0);
		file_index++;
	}
	buffer[0x02] = (unsigned char) file_index;	// write total number of files read
	buffer[0x03] = 0;				// this effectively makes it a 16 bit number (ie. the menu program can use an int.
	res = f_closedir(&dir);
}

