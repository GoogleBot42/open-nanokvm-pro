/* capmeas.c -- measure the RAW V4L2 capture rate of the open driver and say
 * where the missing frames go.  Plain V4L2 MMAP streaming on the open
 * capture node; nothing vendor-specific.  Issue #107.
 *
 * usage: capmeas <dev> <W> <H> <seconds> <nbuf> <mode>
 *   mode = none   -- DQBUF/QBUF only, the frame is never read (the floor)
 *          word   -- volatile 32-bit word loop over the whole frame
 *          copy   -- memcpy() the whole frame into malloc'd RAM
 *          page   -- read one word per 4 KiB page
 *
 * Reports frames, elapsed, fps, the V4L2 sequence span, how many frames the
 * DRIVER dropped (sequence gaps: the WDMA re-armed on the same buffer because
 * nothing was queued), and the split of wall time between waiting in poll()
 * and working on the frame.  A source at F fps gives
 *   sequence span / elapsed ~= F        (the hardware ran at the source rate)
 *   dequeued  / elapsed     == fps      (what the consumer got)
 * and their difference is exactly the driver-side drop count.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <poll.h>
#include <time.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/videodev2.h>

#define MAXBUF 8

static double now_s(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
	if (argc < 7) {
		fprintf(stderr, "usage: capmeas <dev> <W> <H> <seconds> <nbuf> <none|word|copy|page>\n");
		return 2;
	}
	const char *dev = argv[1];
	unsigned W = atoi(argv[2]), H = atoi(argv[3]);
	double secs = atof(argv[4]);
	unsigned nbuf = atoi(argv[5]);
	const char *mode = argv[6];
	if (nbuf > MAXBUF) nbuf = MAXBUF;

	int fd = open(dev, O_RDWR | O_CLOEXEC);
	if (fd < 0) { perror("open"); return 1; }

	struct v4l2_capability cap;
	memset(&cap, 0, sizeof cap);
	if (ioctl(fd, VIDIOC_QUERYCAP, &cap)) { perror("QUERYCAP"); return 1; }
	printf("driver=%s card=%s\n", cap.driver, cap.card);

	struct v4l2_format f;
	memset(&f, 0, sizeof f);
	f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	f.fmt.pix.width = W; f.fmt.pix.height = H;
	f.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
	f.fmt.pix.field = V4L2_FIELD_NONE;
	if (ioctl(fd, VIDIOC_S_FMT, &f)) { perror("S_FMT"); return 1; }
	printf("fmt %ux%u bpl=%u size=%u\n", f.fmt.pix.width, f.fmt.pix.height,
	       f.fmt.pix.bytesperline, f.fmt.pix.sizeimage);
	if (f.fmt.pix.width != W || f.fmt.pix.height != H) {
		fprintf(stderr, "geometry refused\n"); return 1;
	}
	size_t fsz = f.fmt.pix.sizeimage;

	struct v4l2_requestbuffers rb;
	memset(&rb, 0, sizeof rb);
	rb.count = nbuf; rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; rb.memory = V4L2_MEMORY_MMAP;
	if (ioctl(fd, VIDIOC_REQBUFS, &rb) || rb.count == 0) { perror("REQBUFS"); return 1; }
	printf("reqbufs asked %u -> got %u\n", nbuf, rb.count);
	nbuf = rb.count > MAXBUF ? MAXBUF : rb.count;

	void *map[MAXBUF]; size_t mlen[MAXBUF];
	for (unsigned i = 0; i < nbuf; i++) {
		struct v4l2_buffer b;
		memset(&b, 0, sizeof b);
		b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; b.memory = V4L2_MEMORY_MMAP; b.index = i;
		if (ioctl(fd, VIDIOC_QUERYBUF, &b)) { perror("QUERYBUF"); return 1; }
		mlen[i] = b.length;
		map[i] = mmap(NULL, b.length, PROT_READ, MAP_SHARED, fd, b.m.offset);
		if (map[i] == MAP_FAILED) { perror("mmap"); return 1; }
		if (ioctl(fd, VIDIOC_QBUF, &b)) { perror("QBUF"); return 1; }
	}

	void *sink = NULL;
	if (!strcmp(mode, "copy")) {
		sink = malloc(fsz);
		if (!sink) { fprintf(stderr, "malloc %zu failed\n", fsz); return 1; }
		memset(sink, 0, fsz);
	}

	int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (ioctl(fd, VIDIOC_STREAMON, &type)) { perror("STREAMON"); return 1; }

	unsigned long frames = 0;
	uint32_t seq_first = 0, seq_last = 0;
	int have_first = 0;
	unsigned long gaps = 0, gap_frames = 0, max_gap = 0;
	double t_poll = 0, t_work = 0;
	double worst_work = 0;
	uint64_t sink_acc = 0;

	double t0 = now_s(), t = t0;
	while (t - t0 < secs) {
		struct pollfd p = { .fd = fd, .events = POLLIN };
		double a = now_s();
		int r = poll(&p, 1, 2000);
		double b_t = now_s();
		t_poll += b_t - a;
		if (r <= 0) { fprintf(stderr, "poll timeout/err after %lu frames\n", frames); break; }

		struct v4l2_buffer b;
		memset(&b, 0, sizeof b);
		b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; b.memory = V4L2_MEMORY_MMAP;
		if (ioctl(fd, VIDIOC_DQBUF, &b)) { perror("DQBUF"); break; }

		if (!have_first) { seq_first = b.sequence; have_first = 1; }
		else if (b.sequence != seq_last + 1) {
			unsigned long d = b.sequence - seq_last - 1;
			gaps++; gap_frames += d;
			if (d > max_gap) max_gap = d;
		}
		seq_last = b.sequence;

		if (sink) {
			memcpy(sink, map[b.index], fsz);
		} else if (!strcmp(mode, "word")) {
			const volatile uint32_t *s = map[b.index];
			uint64_t acc = 0;
			for (size_t i = 0; i < fsz / 4; i++) acc += s[i];
			sink_acc += acc;
		} else if (!strcmp(mode, "page")) {
			const volatile uint32_t *s = map[b.index];
			uint64_t acc = 0;
			for (size_t i = 0; i < fsz / 4; i += 1024) acc += s[i];
			sink_acc += acc;
		}

		if (ioctl(fd, VIDIOC_QBUF, &b)) { perror("QBUF"); break; }
		frames++;
		double c = now_s();
		if (c - b_t > worst_work) worst_work = c - b_t;
		t_work += c - b_t;
		t = c;
	}
	double elapsed = now_s() - t0;
	ioctl(fd, VIDIOC_STREAMOFF, &type);

	unsigned long span = have_first ? (unsigned long)(seq_last - seq_first) + 1 : 0;
	printf("mode=%s nbuf=%u frame=%zu B\n", mode, nbuf, fsz);
	printf("elapsed   %.2f s\n", elapsed);
	printf("dequeued  %lu frames -> %.2f fps\n", frames, frames / elapsed);
	printf("seq span  %lu (first=%u last=%u) -> %.2f fps produced by the hardware\n",
	       span, seq_first, seq_last, span / elapsed);
	printf("driver drops %lu frames in %lu gaps (max gap %lu)\n", gap_frames, gaps, max_gap);
	printf("time      poll %.2f s (%.1f%%)  work %.2f s (%.1f%%)  worst work %.1f ms\n",
	       t_poll, 100 * t_poll / elapsed, t_work, 100 * t_work / elapsed, worst_work * 1e3);
	if (frames)
		printf("per frame work %.2f ms (%.0f MB/s over %zu B)\n",
		       1e3 * t_work / frames, frames * (double)fsz / t_work / 1e6, fsz);
	if (sink_acc) printf("acc %llu\n", (unsigned long long)sink_acc);
	(void)mlen;
	return 0;
}
