/* v4l2grab -- S_FMT WxH YUYV, stream N frames, save frame K (full YUYV) to out.
 * usage: v4l2grab /dev/videoX W H N K out.yuyv   (our own tool, no vendor code) */
#include <stdio.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/videodev2.h>
int main(int argc, char **argv)
{
	if (argc < 7) { fprintf(stderr, "usage: v4l2grab dev W H N K out\n"); return 1; }
	int fd = open(argv[1], O_RDWR); if (fd < 0) { perror("open"); return 1; }
	unsigned W = atoi(argv[2]), H = atoi(argv[3]), N = atoi(argv[4]), K = atoi(argv[5]);
	struct v4l2_format f = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE };
	f.fmt.pix.width = W; f.fmt.pix.height = H; f.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV; f.fmt.pix.field = V4L2_FIELD_NONE;
	if (ioctl(fd, VIDIOC_S_FMT, &f)) { perror("S_FMT"); return 1; }
	printf("fmt %ux%u bpl=%u size=%u\n", f.fmt.pix.width, f.fmt.pix.height, f.fmt.pix.bytesperline, f.fmt.pix.sizeimage);
	struct v4l2_requestbuffers rb = { .count = 3, .type = V4L2_BUF_TYPE_VIDEO_CAPTURE, .memory = V4L2_MEMORY_MMAP };
	if (ioctl(fd, VIDIOC_REQBUFS, &rb)) { perror("REQBUFS"); return 1; }
	void *map[8];
	for (unsigned i = 0; i < rb.count; i++) {
		struct v4l2_buffer b = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE, .memory = V4L2_MEMORY_MMAP, .index = i };
		if (ioctl(fd, VIDIOC_QUERYBUF, &b)) { perror("QUERYBUF"); return 1; }
		map[i] = mmap(0, b.length, PROT_READ, MAP_SHARED, fd, b.m.offset);
		if (map[i] == MAP_FAILED) { perror("mmap"); return 1; }
		if (ioctl(fd, VIDIOC_QBUF, &b)) { perror("QBUF"); return 1; }
	}
	int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (ioctl(fd, VIDIOC_STREAMON, &type)) { perror("STREAMON"); return 1; }
	unsigned got = 0, saved = 0; struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
	while (got < N) {
		struct pollfd p = { .fd = fd, .events = POLLIN };
		int r = poll(&p, 1, 2000);
		if (r <= 0) { printf("poll timeout after %u frames\n", got); break; }
		struct v4l2_buffer b = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE, .memory = V4L2_MEMORY_MMAP };
		if (ioctl(fd, VIDIOC_DQBUF, &b)) { perror("DQBUF"); break; }
		if (got == K && !saved) {
			FILE *o = fopen(argv[6], "wb");
			const volatile unsigned int *s = map[b.index]; unsigned n = b.bytesused / 4;
			unsigned int *tmp = malloc(b.bytesused);
			for (unsigned i = 0; i < n; i++) tmp[i] = s[i];   /* word loop: no memcpy on the mapping */
			fwrite(tmp, 1, b.bytesused, o); fclose(o); free(tmp); saved = 1;
			printf("saved frame seq=%u used=%u to %s\n", b.sequence, b.bytesused, argv[6]);
		}
		got++;
		if (ioctl(fd, VIDIOC_QBUF, &b)) { perror("QBUF"); break; }
	}
	clock_gettime(CLOCK_MONOTONIC, &t1);
	double dt = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
	printf("got %u frames in %.2fs (%.1f fps)\n", got, dt, got / dt);
	ioctl(fd, VIDIOC_STREAMOFF, &type);
	return got == N ? 0 : 2;
}
