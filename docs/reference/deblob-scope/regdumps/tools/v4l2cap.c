/* v4l2cap -- minimal V4L2 mmap capture test: S_FMT, REQBUFS(3), QBUF, STREAMON,
 * wait for N frames with a timeout, report sequence/bytesused, save one frame
 * decimated (Y plane, /8) for viewing.  usage: v4l2cap /dev/video0 W H NFRAMES [out.y]
 */
#include <stdio.h>
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
	if (argc < 5) { fprintf(stderr, "usage: v4l2cap dev W H N [out.y]\n"); return 1; }
	int fd = open(argv[1], O_RDWR);
	if (fd < 0) { perror("open"); return 1; }
	unsigned W = atoi(argv[2]), H = atoi(argv[3]), N = atoi(argv[4]);

	struct v4l2_format f = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE };
	f.fmt.pix.width = W; f.fmt.pix.height = H;
	f.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV; f.fmt.pix.field = V4L2_FIELD_NONE;
	if (ioctl(fd, VIDIOC_S_FMT, &f)) { perror("S_FMT"); return 1; }
	printf("fmt %ux%u bpl=%u size=%u\n", f.fmt.pix.width, f.fmt.pix.height,
	       f.fmt.pix.bytesperline, f.fmt.pix.sizeimage);

	struct v4l2_requestbuffers rb = { .count = 3, .type = V4L2_BUF_TYPE_VIDEO_CAPTURE, .memory = V4L2_MEMORY_MMAP };
	if (ioctl(fd, VIDIOC_REQBUFS, &rb)) { perror("REQBUFS"); return 1; }
	printf("reqbufs -> %u\n", rb.count);
	void *map[8]; size_t len[8];
	for (unsigned i = 0; i < rb.count; i++) {
		struct v4l2_buffer b = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE, .memory = V4L2_MEMORY_MMAP, .index = i };
		if (ioctl(fd, VIDIOC_QUERYBUF, &b)) { perror("QUERYBUF"); return 1; }
		len[i] = b.length;
		map[i] = mmap(0, b.length, PROT_READ, MAP_SHARED, fd, b.m.offset);
		if (map[i] == MAP_FAILED) { perror("mmap"); return 1; }
		if (ioctl(fd, VIDIOC_QBUF, &b)) { perror("QBUF"); return 1; }
	}
	int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (ioctl(fd, VIDIOC_STREAMON, &type)) { perror("STREAMON"); return 1; }
	printf("streaming\n"); fflush(stdout);

	unsigned got = 0, saved = 0;
	while (got < N) {
		struct pollfd p = { .fd = fd, .events = POLLIN };
		int r = poll(&p, 1, 2000);
		if (r <= 0) { printf("poll timeout/err after %u frames (r=%d errno=%d)\n", got, r, errno); break; }
		struct v4l2_buffer b = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE, .memory = V4L2_MEMORY_MMAP };
		if (ioctl(fd, VIDIOC_DQBUF, &b)) { perror("DQBUF"); break; }
		const volatile unsigned char *d = map[b.index];
		unsigned long nz = 0;
		for (unsigned long i = 0; i < b.bytesused; i += 4096) nz += d[i] != 0;
		printf("frame seq=%u idx=%u used=%u flags=%#x nz-pages=%lu first=%02x%02x%02x%02x\n",
		       b.sequence, b.index, b.bytesused, b.flags, nz, d[0], d[1], d[2], d[3]);
		fflush(stdout);
		if (argc > 5 && !saved && got >= 2) {
			FILE *o = fopen(argv[5], "wb");
			for (unsigned y = 0; y < H; y += 8)
				for (unsigned x = 0; x < W; x += 8)
					fputc(d[(unsigned long)y * W * 2 + x * 2], o);
			fclose(o); saved = 1;
		}
		got++;
		if (ioctl(fd, VIDIOC_QBUF, &b)) { perror("QBUF"); break; }
	}
	ioctl(fd, VIDIOC_STREAMOFF, &type);
	printf("done: %u frames\n", got);
	return got ? 0 : 2;
}
