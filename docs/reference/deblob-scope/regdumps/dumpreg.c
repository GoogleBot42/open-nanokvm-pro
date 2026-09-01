#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
int main(int argc, char **argv){
    unsigned long base = strtoul(argv[1],0,0);
    unsigned long len  = strtoul(argv[2],0,0);
    int fd = open("/dev/mem", O_RDONLY|O_SYNC);
    if(fd<0){perror("open");return 1;}
    unsigned long pg = base & ~0xFFFUL, off = base - pg, mlen = off+len;
    void *m = mmap(0, mlen, PROT_READ, MAP_SHARED, fd, pg);
    if(m==MAP_FAILED){perror("mmap");return 1;}
    volatile unsigned int *r = (volatile unsigned int*)((char*)m+off);
    for(unsigned long i=0;i<len/4;i++){ unsigned int v=r[i]; fwrite(&v,4,1,stdout);} 
    return 0;
}
