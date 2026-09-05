/* regpoll2.c -- READ-ONLY. Poll the VC8000E core window (VCMD 0x04010000 + 0x1000, 512 words)
 * and save the FIRST live (non-0xdeadbeef) full-512-word snapshot plus up to 32 more samples
 * of the 128-word head. usage: regpoll2 <out.bin> <seconds> */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/mman.h>
int main(int argc,char**argv){
    const char *fn=argv[1]; int secs=atoi(argv[2]);
    int fd=open("/dev/mem",O_RDONLY|O_SYNC); volatile uint32_t *m=mmap(NULL,0x2000,PROT_READ,MAP_SHARED,fd,0x04010000UL);
    if(m==MAP_FAILED){perror("mmap");return 1;}
    uint32_t v0=m[0x1000/4+80]; printf("first read sw80=%08x vcmd[0..3]=%08x %08x %08x %08x\n",v0,m[0],m[1],m[2],m[3]);
    struct timespec t0,t; clock_gettime(CLOCK_MONOTONIC,&t0); long polls=0; int got=0, ns=0;
    char sf[512]; snprintf(sf,sizeof sf,"%s.samples",fn); FILE *sa=fopen(sf,"w");
    for(;;){ polls++;
        if(m[0x1000/4+80]!=0xdeadbeef){
            uint32_t w[512]; for(int i=0;i<512;i++) w[i]=m[0x1000/4+i];
            if(!got){ FILE*f=fopen(fn,"wb"); fwrite(w,4,512,f); fclose(f); got=1;
                printf("LIVE after %ld polls: sw0=%08x sw80=%08x sw214=%08x sw226=%08x sw287=%08x sw82=%08x sw9=%08x sw191=%08x\n",polls,w[0],w[80],w[214],w[226],w[287],w[82],w[9],w[191]); }
            if(ns<32){ fprintf(sa,"poll %ld:",polls); for(int i=0;i<512;i++) fprintf(sa," %08x",w[i]); fprintf(sa,"\n"); ns++; }
        }
        clock_gettime(CLOCK_MONOTONIC,&t); if(t.tv_sec-t0.tv_sec>secs) break; }
    fclose(sa); printf("polls=%ld got=%d samples=%d\n",polls,got,ns); return got?0:5; }
