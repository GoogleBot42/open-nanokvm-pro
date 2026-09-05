/* v4lrec.c -- record N consecutive raw YUYV frames from the OPEN V4L2 capture
 * driver (/dev/video0, open_vin_capture: S_FMT YUYV, stride == width) into RAM,
 * then write them to one file, plus a sidecar with the V4L2 sequence numbers
 * and timestamps (proves the frames are consecutive).  Plain V4L2 MMAP
 * streaming, nothing vendor-specific.  Run with nanokvm stopped.
 *
 * usage: v4lrec <dev> <W> <H> <nframes> <skip> <out.yuyv>
 *   skip = frames discarded after STREAMON before recording starts. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <poll.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/videodev2.h>
#define NBUF 4
int main(int argc, char **argv){
    if(argc<7){ fprintf(stderr,"usage: v4lrec <dev> <W> <H> <nframes> <skip> <out.yuyv>\n"); return 2; }
    const char *dev=argv[1]; int W=atoi(argv[2]), H=atoi(argv[3]), N=atoi(argv[4]), SKIP=atoi(argv[5]); const char *out=argv[6];
    int fd=open(dev,O_RDWR|O_CLOEXEC); if(fd<0){perror("open");return 1;}
    struct v4l2_capability cap; memset(&cap,0,sizeof cap);
    if(ioctl(fd,VIDIOC_QUERYCAP,&cap)){perror("QUERYCAP");return 1;}
    printf("driver=%s card=%s\n",cap.driver,cap.card);
    struct v4l2_format f; memset(&f,0,sizeof f); f.type=V4L2_BUF_TYPE_VIDEO_CAPTURE;
    f.fmt.pix.width=W; f.fmt.pix.height=H; f.fmt.pix.pixelformat=V4L2_PIX_FMT_YUYV; f.fmt.pix.field=V4L2_FIELD_NONE;
    if(ioctl(fd,VIDIOC_S_FMT,&f)){perror("S_FMT");return 1;}
    printf("S_FMT -> %ux%u fourcc=%.4s bytesperline=%u sizeimage=%u\n",f.fmt.pix.width,f.fmt.pix.height,(char*)&f.fmt.pix.pixelformat,f.fmt.pix.bytesperline,f.fmt.pix.sizeimage);
    if(f.fmt.pix.width!=(unsigned)W||f.fmt.pix.height!=(unsigned)H||f.fmt.pix.pixelformat!=V4L2_PIX_FMT_YUYV){fprintf(stderr,"format refused\n");return 1;}
    size_t fsz=(size_t)W*H*2; if(f.fmt.pix.sizeimage<fsz){fprintf(stderr,"sizeimage too small\n");return 1;}
    struct v4l2_requestbuffers rb; memset(&rb,0,sizeof rb); rb.count=NBUF; rb.type=V4L2_BUF_TYPE_VIDEO_CAPTURE; rb.memory=V4L2_MEMORY_MMAP;
    if(ioctl(fd,VIDIOC_REQBUFS,&rb)||rb.count==0){perror("REQBUFS");return 1;}
    void *map[NBUF]; size_t mlen[NBUF];
    for(unsigned i=0;i<rb.count;i++){ struct v4l2_buffer b; memset(&b,0,sizeof b); b.type=V4L2_BUF_TYPE_VIDEO_CAPTURE; b.memory=V4L2_MEMORY_MMAP; b.index=i;
        if(ioctl(fd,VIDIOC_QUERYBUF,&b)){perror("QUERYBUF");return 1;}
        mlen[i]=b.length; map[i]=mmap(NULL,b.length,PROT_READ,MAP_SHARED,fd,b.m.offset); if(map[i]==MAP_FAILED){perror("mmap");return 1;}
        if(ioctl(fd,VIDIOC_QBUF,&b)){perror("QBUF");return 1;} }
    uint8_t *ram=malloc(fsz*(size_t)N); if(!ram){fprintf(stderr,"malloc %zu failed\n",fsz*N);return 1;}
    uint32_t *seq=calloc(N,4); uint64_t *ts=calloc(N,8);
    int type=V4L2_BUF_TYPE_VIDEO_CAPTURE; if(ioctl(fd,VIDIOC_STREAMON,&type)){perror("STREAMON");return 1;}
    int got=0, skipped=0;
    while(got<N){
        struct pollfd p={.fd=fd,.events=POLLIN}; int r=poll(&p,1,2000); if(r<=0){fprintf(stderr,"poll timeout/err after %d frames\n",got);break;}
        struct v4l2_buffer b; memset(&b,0,sizeof b); b.type=V4L2_BUF_TYPE_VIDEO_CAPTURE; b.memory=V4L2_MEMORY_MMAP;
        if(ioctl(fd,VIDIOC_DQBUF,&b)){perror("DQBUF");break;}
        if(skipped<SKIP){ skipped++; }
        else { memcpy(ram+fsz*(size_t)got,map[b.index],fsz); seq[got]=b.sequence; ts[got]=(uint64_t)b.timestamp.tv_sec*1000000ull+b.timestamp.tv_usec; got++; }
        if(ioctl(fd,VIDIOC_QBUF,&b)){perror("QBUF");break;}
    }
    ioctl(fd,VIDIOC_STREAMOFF,&type);
    FILE *o=fopen(out,"wb"); if(!o){perror("fopen");return 1;}
    size_t wr=fwrite(ram,1,fsz*(size_t)got,o); fclose(o);
    char sc[512]; snprintf(sc,sizeof sc,"%s.seq",out); FILE *s=fopen(sc,"w");
    fprintf(s,"# frame v4l2_sequence timestamp_us dt_us\n");
    for(int i=0;i<got;i++) fprintf(s,"%d %u %llu %lld\n",i,seq[i],(unsigned long long)ts[i],(long long)(i?ts[i]-ts[i-1]:0));
    fclose(s);
    printf("recorded %d frames (%zu bytes each, %zu written) skipped %d; seq %u..%u\n",got,fsz,wr,skipped,got?seq[0]:0,got?seq[got-1]:0);
    for(unsigned i=0;i<rb.count;i++) munmap(map[i],mlen[i]);
    close(fd); return got==N?0:5;
}
