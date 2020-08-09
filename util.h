#ifndef __UTIL_H
#define __UTIL_H

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "stm32f4xx.h"

#include "ff.h"

#include "defines.h"

void delay_us(const uint16_t us);
void delay_ms(const uint16_t ms);
void blink_pa6(int delay);
void blink_pa7(int delay);
void blink_pa1(int delay);
void toggle_pa1();

void fancy_blink_pa1(int count1, int delay1, int count2, int delay2);
void blink_pa6_pa7(int delay);

uint32_t suffix_match(char *name, char *suffix);
void load_directory(char *dirname, unsigned char *buffer);

#endif
