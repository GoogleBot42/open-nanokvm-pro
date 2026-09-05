/* regpoll.c -- READ-ONLY: mmap the VCMD block at 0x04010000 and poll the
 * encoder-core register window (+0x1000..+0x1200) until it is not
 * clock-gated (0xdeadbeef); save the first live snapshot and N more.
 * usage: regpoll <outfile> <max_seconds> */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/mman.h>
#define BASE 0x04010000UL
#define OFF  0x1000
#define NW   128
int main(int argc,char**argv){
    const char *fn=argc>1?argv[1]:"/tmp/axwork/E5/regs.bin"; int secs=argc>2?atoi(argv[2]):20;
    int fd=open("/dev/mem",O_RDONLY|O_SYNC); if(fd<0){perror("mem");return 1;}
    volatile uint32_t *m=mmap(NULL,0x2000,PROT_READ,MAP_SHARED,fd,BASE); if(m==MAP_FAILED){perror("mmap");return 1;}
    uint32_t snap[NW], best[NW]; int got=0; long polls=0; struct timespec t0,t; clock_gettime(CLOCK_MONOTONIC,&t0);
    uint32_t vc[8]; for(int i=0;i<8;i++) vc[i]=m[i];
    printf("VCMD engine +0x00..0x1c:"); for(int i=0;i<8;i++) printf(" %08x",vc[i]); printf("\n");
    FILE *all=fopen(argc>3?argv[3]:"/tmp/axwork/E5/samples.txt","w");
    int nsamp=0;
    for(;;){
        polls++;
        uint32_t w80=m[OFF/4+80];
        if(w80!=0xdeadbeef){
            for(int i=0;i<NW;i++) snap[i]=m[OFF/4+i];
            if(!got){ for(int i=0;i<NW;i++) best[i]=snap[i]; got=1;
                FILE*f=fopen(fn,"wb"); fwrite(best,4,NW,f); fclose(f);
                printf("live after %ld polls: sw0=%08x sw80=%08x sw214=? (beyond window) \n",polls,best[0],best[80]); }
            if(all && nsamp<64){ fprintf(all,"poll %ld:",polls); for(int i=0;i<NW;i++) fprintf(all," %08x",snap[i]); fprintf(all,"\n"); nsamp++; }
        }
        clock_gettime(CLOCK_MONOTONIC,&t);
        if(t.tv_sec-t0.tv_sec>secs) break;
    }
    if(all) fclose(all);
    printf("polls=%ld got=%d\n",polls,got);
    /* also the wider window 0x1000..0x1800 (sw0..511) once, if live */
    if(m[OFF/4+80]!=0xdeadbeef){ uint32_t wide[512]; for(int i=0;i<512;i++) wide[i]=m[OFF/4+i];
        char wf[512]; snprintf(wf,sizeof wf,"%s.wide",fn); FILE*f=fopen(wf,"wb"); fwrite(wide,4,512,f); fclose(f); printf("wide snapshot saved\n"); }
    return got?0:5;
}
