/********************************************************************
 *                                                                  *
 * THIS FILE IS PART OF THE OggTheora SOFTWARE CODEC SOURCE CODE.   *
 * USE, DISTRIBUTION AND REPRODUCTION OF THIS LIBRARY SOURCE IS     *
 * GOVERNED BY A BSD-STYLE SOURCE LICENSE INCLUDED WITH THIS SOURCE *
 * IN 'COPYING'. PLEASE READ THESE TERMS BEFORE DISTRIBUTING.       *
 *                                                                  *
 * THE Theora SOURCE CODE IS COPYRIGHT (C) 2002-2009                *
 * by the Xiph.Org Foundation and contributors http://www.xiph.org/ *
 *                                                                  *
 ********************************************************************

  function:
    last mod: $Id: mmxstate.c 17247 2010-05-28 05:35:32Z tterribe $

 ********************************************************************/

#include "x86enc.h"

#if defined(OC_X86_ASM)



/*The default enquant table is not quite suitable for SIMD purposes.
  First, the m and l parameters need to be separated so that an entire row full
   of m's or l's can be loaded at a time.
  Second, x86 SIMD has no element-wise arithmetic right-shift, so we have to
   emulate one with a multiply.
  Therefore we translate the shift count into a scale factor.*/
void oc_enc_enquant_table_init_x86(void *_enquant,
 const ogg_uint16_t _dequant[64]){
  ogg_int16_t *m;
  ogg_int16_t *l;
  int          zzi;
  m=(ogg_int16_t *)_enquant;
  l=m+64;
  for(zzi=0;zzi<64;zzi++){
    oc_iquant q;
    oc_iquant_init(&q,_dequant[zzi]);
    m[zzi]=q.m;
    /*q.l must be at least 2 for this to work; fortunately, once all the scale
       factors are baked in, the minimum quantizer is much larger than that.*/
    l[zzi]=1<<16-q.l;
  }
}

void oc_enc_enquant_table_fixup_x86(void *_enquant[3][3][2],int _nqis){
  int pli;
  int qii;
  int qti;
  for(pli=0;pli<3;pli++)for(qii=1;qii<_nqis;qii++)for(qti=0;qti<2;qti++){
    ((ogg_int16_t *)_enquant[pli][qii][qti])[0]=
     ((ogg_int16_t *)_enquant[pli][0][qti])[0];
    ((ogg_int16_t *)_enquant[pli][qii][qti])[64]=
     ((ogg_int16_t *)_enquant[pli][0][qti])[64];
  }
}

/*Convert DCT coefficients in %[dct] from natural order into zig-zag scan order
   and store them in %[qdct].
  The index of each output element in the original 64-element array should wind
   up in the following 8x8 matrix (the letters indicate the order we compute
   each 4-tuple below):
    A  0  1  8 16   9  2  3 10 B
    C 17 24 32 25  18 11  4  5 D
    E 12 19 26 33  40 48 41 34 I
    H 27 20 13  6   7 14 21 28 G
    K 35 42 49 56  57 50 43 36 J
    F 29 22 15 23  30 37 44 51 M
    P 58 59 52 45  38 31 39 46 L
    N 53 60 61 54  47 55 62 63 O
  The order of the coefficients within each tuple is reversed in the comments
   below to reflect the usual MSB to LSB notation.*/
#define OC_ZIG_ZAG_MMXEXT \
  "movq 0x00(%[dct]),%%mm0\n\t"  /*mm0=03 02 01 00*/ \
  "movq 0x08(%[dct]),%%mm1\n\t"  /*mm1=07 06 05 04*/ \
  "movq 0x10(%[dct]),%%mm2\n\t"  /*mm2=11 10 09 08*/ \
  "movq 0x20(%[dct]),%%mm3\n\t"  /*mm3=19 18 17 16*/ \
  "movq 0x30(%[dct]),%%mm4\n\t"  /*mm4=27 26 25 24*/ \
  "movq 0x40(%[dct]),%%mm5\n\t"  /*mm5=35 34 33 32*/ \
  "movq %%mm2,%%mm7\n\t"         /*mm7=11 10 09 08*/ \
  "punpcklwd %%mm3,%%mm2\n\t"    /*mm2=17 09 16 08*/ \
  "movq %%mm0,%%mm6\n\t"         /*mm6=03 02 01 00*/ \
  "punpckldq %%mm2,%%mm0\n\t"    /*mm0=16 08 01 00 *A*/ \
  "movq %%mm0,0x00(%[qdct])\n\t" \
  "movq 0x18(%[dct]),%%mm0\n\t"  /*mm0=15 14 13 12*/ \
  "punpckhdq %%mm6,%%mm6\n\t"    /*mm6=03 02 03 02*/ \
  "psrlq $16,%%mm7\n\t"          /*mm7=.. 11 10 09*/ \
  "punpckldq %%mm7,%%mm6\n\t"    /*mm6=10 09 03 02*/ \
  "punpckhwd %%mm7,%%mm3\n\t"    /*mm3=.. 19 11 18*/ \
  "pshufw $0xD2,%%mm6,%%mm6\n\t" /*mm6=10 03 02 09 *B*/ \
  "movq %%mm6,0x08(%[qdct])\n\t" \
  "psrlq $48,%%mm2\n\t"          /*mm2=.. .. .. 17*/ \
  "movq %%mm1,%%mm6\n\t"         /*mm6=07 06 05 04*/ \
  "punpcklwd %%mm5,%%mm2\n\t"    /*mm2=33 .. 32 17*/ \
  "movq %%mm3,%%mm7\n\t"         /*mm7=.. 19 11 18*/ \
  "punpckldq %%mm1,%%mm3\n\t"    /*mm3=05 04 11 18 *C*/ \
  "por %%mm2,%%mm7\n\t"          /*mm7=33 19 ?? ??*/ \
  "punpcklwd %%mm4,%%mm2\n\t"    /*mm2=25 32 24 17 *D**/ \
  "movq %%mm2,0x10(%[qdct])\n\t" \
  "movq %%mm3,0x18(%[qdct])\n\t" \
  "movq 0x28(%[dct]),%%mm2\n\t"  /*mm2=23 22 21 20*/ \
  "movq 0x38(%[dct]),%%mm1\n\t"  /*mm1=31 30 29 28*/ \
  "pshufw $0x9C,%%mm0,%%mm3\n\t" /*mm3=14 13 15 12*/ \
  "punpckhdq %%mm7,%%mm7\n\t"    /*mm7=33 19 33 19*/ \
  "punpckhwd %%mm3,%%mm6\n\t"    /*mm6=14 07 13 06*/ \
  "punpckldq %%mm0,%%mm0\n\t"    /*mm0=13 12 13 12*/ \
  "punpcklwd %%mm1,%%mm3\n\t"    /*mm3=29 15 28 12*/ \
  "punpckhwd %%mm4,%%mm0\n\t"    /*mm0=27 13 26 12*/ \
  "pshufw $0xB4,%%mm3,%%mm3\n\t" /*mm3=15 29 28 12*/ \
  "psrlq $48,%%mm4\n\t"          /*mm4=.. .. .. 27*/ \
  "punpcklwd %%mm7,%%mm0\n\t"    /*mm0=33 26 19 12 *E*/ \
  "punpcklwd %%mm1,%%mm4\n\t"    /*mm4=29 .. 28 27*/ \
  "punpckhwd %%mm2,%%mm3\n\t"    /*mm3=23 15 22 29 *F*/ \
  "movq %%mm0,0x20(%[qdct])\n\t" \
  "movq %%mm3,0x50(%[qdct])\n\t" \
  "movq 0x60(%[dct]),%%mm3\n\t"  /*mm3=51 50 49 48*/ \
  "movq 0x70(%[dct]),%%mm7\n\t"  /*mm7=59 58 57 56*/ \
  "movq 0x50(%[dct]),%%mm0\n\t"  /*mm0=43 42 41 40*/ \
  "punpcklwd %%mm4,%%mm2\n\t"    /*mm2=28 21 27 20*/ \
  "psrlq $32,%%mm5\n\t"          /*mm5=.. .. 35 34*/ \
  "movq %%mm2,%%mm4\n\t"         /*mm4=28 21 27 20*/ \
  "punpckldq %%mm6,%%mm2\n\t"    /*mm2=13 06 27 20*/ \
  "punpckhdq %%mm4,%%mm6\n\t"    /*mm6=28 21 14 07 *G*/ \
  "movq %%mm3,%%mm4\n\t"         /*mm4=51 50 49 48*/ \
  "pshufw $0xB1,%%mm2,%%mm2\n\t" /*mm2=06 13 20 27 *H*/ \
  "movq %%mm2,0x30(%[qdct])\n\t" \
  "movq %%mm6,0x38(%[qdct])\n\t" \
  "movq 0x48(%[dct]),%%mm2\n\t"  /*mm2=39 38 37 36*/ \
  "punpcklwd %%mm5,%%mm4\n\t"    /*mm4=35 49 34 48*/ \
  "movq 0x58(%[dct]),%%mm5\n\t"  /*mm5=47 46 45 44*/ \
  "punpckldq %%mm7,%%mm6\n\t"    /*mm6=57 56 14 07*/ \
  "psrlq $32,%%mm3\n\t"          /*mm3=.. .. 51 50*/ \
  "punpckhwd %%mm0,%%mm6\n\t"    /*mm6=43 57 42 56*/ \
  "punpcklwd %%mm4,%%mm0\n\t"    /*mm0=34 41 48 40 *I*/ \
  "pshufw $0x4E,%%mm6,%%mm6\n\t" /*mm6=42 56 43 57*/ \
  "movq %%mm0,0x28(%[qdct])\n\t" \
  "punpcklwd %%mm2,%%mm3\n\t"    /*mm3=37 51 36 50*/ \
  "punpckhwd %%mm6,%%mm4\n\t"    /*mm4=42 35 56 49*/ \
  "punpcklwd %%mm3,%%mm6\n\t"    /*mm6=36 43 50 57 *J*/ \
  "pshufw $0x4E,%%mm4,%%mm4\n\t" /*mm4=56 49 42 35 *K*/ \
  "movq %%mm4,0x40(%[qdct])\n\t" \
  "movq %%mm6,0x48(%[qdct])\n\t" \
  "movq 0x68(%[dct]),%%mm6\n\t"  /*mm6=55 54 53 52*/ \
  "movq 0x78(%[dct]),%%mm0\n\t"  /*mm0=63 62 61 60*/ \
  "psrlq $32,%%mm1\n\t"          /*mm1=.. .. 31 30*/ \
  "pshufw $0xD8,%%mm5,%%mm5\n\t" /*mm5=47 45 46 44*/ \
  "pshufw $0x0B,%%mm3,%%mm3\n\t" /*mm3=50 50 51 37*/ \
  "punpcklwd %%mm5,%%mm1\n\t"    /*mm1=46 31 44 30*/ \
  "pshufw $0xC9,%%mm6,%%mm6\n\t" /*mm6=55 52 54 53*/ \
  "punpckhwd %%mm1,%%mm2\n\t"    /*mm2=46 39 31 38 *L*/ \
  "punpcklwd %%mm3,%%mm1\n\t"    /*mm1=51 44 37 30 *M*/ \
  "movq %%mm2,0x68(%[qdct])\n\t" \
  "movq %%mm1,0x58(%[qdct])\n\t" \
  "punpckhwd %%mm6,%%mm5\n\t"    /*mm5=55 47 52 45*/ \
  "punpckldq %%mm0,%%mm6\n\t"    /*mm6=61 60 54 53*/ \
  "pshufw $0x10,%%mm5,%%mm4\n\t" /*mm4=45 52 45 45*/ \
  "pshufw $0x78,%%mm6,%%mm6\n\t" /*mm6=53 60 61 54 *N*/ \
  "punpckhdq %%mm0,%%mm5\n\t"    /*mm5=63 62 55 47 *O*/ \
  "punpckhdq %%mm4,%%mm7\n\t"    /*mm7=45 52 59 58 *P*/ \
  "movq %%mm6,0x70(%[qdct])\n\t" \
  "movq %%mm5,0x78(%[qdct])\n\t" \
  "movq %%mm7,0x60(%[qdct])\n\t" \

int oc_enc_quantize_sse2(ogg_int16_t _qdct[64],const ogg_int16_t _dct[64],
 const ogg_uint16_t _dequant[64],const void *_enquant){
  ptrdiff_t r;
  __asm__ __volatile__(
    /*Put the input in zig-zag order.*/
    OC_ZIG_ZAG_MMXEXT
    "xor %[r],%[r]\n\t"
    /*Loop through two rows at a time.*/
    ".p2align 4\n\t"
    "0:\n\t"
    /*Load the first two rows of the data and the quant matrices.*/
    "movdqa 0x00(%[qdct],%[r]),%%xmm0\n\t"
    "movdqa 0x10(%[qdct],%[r]),%%xmm1\n\t"
    "movdqa 0x00(%[dq],%[r]),%%xmm2\n\t"
    "movdqa 0x10(%[dq],%[r]),%%xmm3\n\t"
    "movdqa 0x00(%[q],%[r]),%%xmm4\n\t"
    "movdqa 0x10(%[q],%[r]),%%xmm5\n\t"
    /*Double the input and propagate its sign to the rounding factor.
      Using SSSE3's psignw would help here, but we need the mask later anyway.*/
    "movdqa %%xmm0,%%xmm6\n\t"
    "psraw $15,%%xmm0\n\t"
    "movdqa %%xmm1,%%xmm7\n\t"
    "paddw %%xmm6,%%xmm6\n\t"
    "psraw $15,%%xmm1\n\t"
    "paddw %%xmm7,%%xmm7\n\t"
    "paddw %%xmm0,%%xmm2\n\t"
    "paddw %%xmm1,%%xmm3\n\t"
    "pxor %%xmm0,%%xmm2\n\t"
    "pxor %%xmm1,%%xmm3\n\t"
    /*Add the rounding factor and perform the first multiply.*/
    "paddw %%xmm2,%%xmm6\n\t"
    "paddw %%xmm3,%%xmm7\n\t"
    "pmulhw %%xmm6,%%xmm4\n\t"
    "pmulhw %%xmm7,%%xmm5\n\t"
    "movdqa 0x80(%[q],%[r]),%%xmm2\n\t"
    "movdqa 0x90(%[q],%[r]),%%xmm3\n\t"
    "paddw %%xmm4,%%xmm6\n\t"
    "paddw %%xmm5,%%xmm7\n\t"
    /*Emulate an element-wise right-shift via a second multiply.*/
    "pmulhw %%xmm2,%%xmm6\n\t"
    "pmulhw %%xmm3,%%xmm7\n\t"
    "add $32,%[r]\n\t"
    "cmp $96,%[r]\n\t"
    /*Correct for the sign.*/
    "psubw %%xmm0,%%xmm6\n\t"
    "psubw %%xmm1,%%xmm7\n\t"
    /*Save the result.*/
    "movdqa %%xmm6,-0x20(%[qdct],%[r])\n\t"
    "movdqa %%xmm7,-0x10(%[qdct],%[r])\n\t"
    "jle 0b\n\t"
    /*Now find the location of the last non-zero value.*/
    "movdqa 0x50(%[qdct]),%%xmm5\n\t"
    "movdqa 0x40(%[qdct]),%%xmm4\n\t"
    "packsswb %%xmm7,%%xmm6\n\t"
    "packsswb %%xmm5,%%xmm4\n\t"
    "pxor %%xmm0,%%xmm0\n\t"
    "mov $-1,%k[dq]\n\t"
    "pcmpeqb %%xmm0,%%xmm6\n\t"
    "pcmpeqb %%xmm0,%%xmm4\n\t"
    "pmovmskb %%xmm6,%k[q]\n\t"
    "pmovmskb %%xmm4,%k[r]\n\t"
    "shl $16,%k[q]\n\t"
    "or %k[r],%k[q]\n\t"
    "mov $32,%[r]\n\t"
    /*We have to use xor here instead of not in order to set the flags.*/
    "xor %k[dq],%k[q]\n\t"
    "jnz 1f\n\t"
    "movdqa 0x30(%[qdct]),%%xmm7\n\t"
    "movdqa 0x20(%[qdct]),%%xmm6\n\t"
    "movdqa 0x10(%[qdct]),%%xmm5\n\t"
    "movdqa 0x00(%[qdct]),%%xmm4\n\t"
    "packsswb %%xmm7,%%xmm6\n\t"
    "packsswb %%xmm5,%%xmm4\n\t"
    "pcmpeqb %%xmm0,%%xmm6\n\t"
    "pcmpeqb %%xmm0,%%xmm4\n\t"
    "pmovmskb %%xmm6,%k[q]\n\t"
    "pmovmskb %%xmm4,%k[r]\n\t"
    "shl $16,%k[q]\n\t"
    "or %k[r],%k[q]\n\t"
    "xor %[r],%[r]\n\t"
    "not %k[q]\n\t"
    "or $1,%k[q]\n\t"
    "1:\n\t"
    "bsr %k[q],%k[q]\n\t"
    "add %k[q],%k[r]\n\t"
    :[r]"=&a"(r),[q]"+r"(_enquant),[dq]"+r"(_dequant)
    :[dct]"r"(_dct),[qdct]"r"(_qdct)
    :"cc","memory"
  );
  return (int)r;
}

#endif
