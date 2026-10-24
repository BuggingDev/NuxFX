// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NuxFX contributors
// Build: gcc -O2 -fno-builtin -fno-tree-loop-distribute-patterns -shared -fPIC -o memcpy_probe.so memcpy_probe.c -ldl
// Use:   LD_PRELOAD=$PWD/memcpy_probe.so MCPROBE_MODE=rot wine AfterFX.exe
// LD_PRELOAD probe: times the memcpy calls of 2 KB .. 64 KB (the row copies of Mesa's
// util_copy_rect) with different copy loops, to see what makes the glTexSubImage2D path slow.
//   MCPROBE_MODE=rot   rotate through the modes every 4 s (default)
//   MCPROBE_MODE=N     fixed mode: 0 rep movsb, 1 AVX2 loop, 2 AVX2 loads + non-temporal stores,
//                      3 non-temporal loads + stores, 4 qword loop, 9 diagnosis: timed read of the
//                      source, timed write of the destination, then rep movsb
//   MCPROBE_LOG=path   where the table goes (default /tmp/mcprobe.log), dumped every 4 s
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <immintrin.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define LO 2048
#define HI 65536

static void *(*real_memcpy)(void *, const void *, size_t);
static int initing;
static int fixed_mode = -2;       /* -2 not read yet, -1 rotate */
static const char *log_path = "/tmp/mcprobe.log";
static uint64_t t_start, t_dump;
static volatile int lock;
static volatile uint64_t sink;

struct acc { uint64_t calls, bytes, ns; };
static struct acc acc_copy[10], acc_read, acc_write;

static inline uint64_t now_ns(void)
{
   struct timespec t;
   clock_gettime(CLOCK_MONOTONIC, &t);
   return t.tv_sec * 1000000000ull + t.tv_nsec;
}

static void *slow_copy(void *d, const void *s, size_t n)
{
   unsigned char *dd = d;
   const unsigned char *ss = s;
   while (n--)
      *dd++ = *ss++;
   return d;
}

static inline void copy_rep(void *d, const void *s, size_t n)
{
   __asm__ volatile("rep movsb" : "+D"(d), "+S"(s), "+c"(n) : : "memory");
}

__attribute__((target("avx2"))) static void copy_avx(unsigned char *d, const unsigned char *s, size_t n)
{
   size_t i = 0;
   for (; i + 128 <= n; i += 128) {
      __m256i a = _mm256_loadu_si256((const __m256i *)(s + i));
      __m256i b = _mm256_loadu_si256((const __m256i *)(s + i + 32));
      __m256i c = _mm256_loadu_si256((const __m256i *)(s + i + 64));
      __m256i e = _mm256_loadu_si256((const __m256i *)(s + i + 96));
      _mm256_storeu_si256((__m256i *)(d + i), a);
      _mm256_storeu_si256((__m256i *)(d + i + 32), b);
      _mm256_storeu_si256((__m256i *)(d + i + 64), c);
      _mm256_storeu_si256((__m256i *)(d + i + 96), e);
   }
   for (; i + 32 <= n; i += 32)
      _mm256_storeu_si256((__m256i *)(d + i), _mm256_loadu_si256((const __m256i *)(s + i)));
   for (; i < n; i++)
      d[i] = s[i];
}

__attribute__((target("avx2"))) static void copy_nt(unsigned char *d, const unsigned char *s, size_t n)
{
   size_t i = 0;
   while (((uintptr_t)(d + i) & 31) && i < n) {
      d[i] = s[i];
      i++;
   }
   for (; i + 64 <= n; i += 64) {
      __m256i a = _mm256_loadu_si256((const __m256i *)(s + i));
      __m256i b = _mm256_loadu_si256((const __m256i *)(s + i + 32));
      _mm256_stream_si256((__m256i *)(d + i), a);
      _mm256_stream_si256((__m256i *)(d + i + 32), b);
   }
   _mm_sfence();
   for (; i < n; i++)
      d[i] = s[i];
}

__attribute__((target("sse4.1"))) static void copy_ntload(unsigned char *d, const unsigned char *s, size_t n)
{
   size_t i = 0;
   while (((uintptr_t)(s + i) & 15) && i < n) {
      d[i] = s[i];
      i++;
   }
   for (; i + 64 <= n; i += 64) {
      __m128i a = _mm_stream_load_si128((__m128i *)(s + i));
      __m128i b = _mm_stream_load_si128((__m128i *)(s + i + 16));
      __m128i c = _mm_stream_load_si128((__m128i *)(s + i + 32));
      __m128i e = _mm_stream_load_si128((__m128i *)(s + i + 48));
      _mm_storeu_si128((__m128i *)(d + i), a);
      _mm_storeu_si128((__m128i *)(d + i + 16), b);
      _mm_storeu_si128((__m128i *)(d + i + 32), c);
      _mm_storeu_si128((__m128i *)(d + i + 48), e);
   }
   for (; i < n; i++)
      d[i] = s[i];
}

static void copy_q(unsigned char *d, const unsigned char *s, size_t n)
{
   size_t i = 0;
   for (; i + 8 <= n; i += 8)
      __builtin_memcpy(d + i, s + i, 8);
   for (; i < n; i++)
      d[i] = s[i];
}

static void put(int fd, const char *s, int n)
{
   if (write(fd, s, n) < 0)
      return;
}

static void dump(uint64_t t)
{
   int fd = open(log_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
   char buf[256];
   if (fd < 0)
      return;
   for (int m = 0; m < 10; m++) {
      if (!acc_copy[m].calls)
         continue;
      int len = snprintf(buf, sizeof buf, "t=%5.1f mode %d: %7llu calls %8.1f MB  %8.1f MB/s\n",
                         (t - t_start) / 1e9, m, (unsigned long long)acc_copy[m].calls,
                         acc_copy[m].bytes / 1e6, acc_copy[m].bytes * 1e3 / (double)acc_copy[m].ns);
      put(fd, buf, len);
      memset(&acc_copy[m], 0, sizeof acc_copy[m]);
   }
   if (acc_read.calls) {
      int len = snprintf(buf, sizeof buf, "t=%5.1f   read of source : %8.1f MB/s   write of dest: %8.1f MB/s\n",
                         (t - t_start) / 1e9, acc_read.bytes * 1e3 / (double)acc_read.ns,
                         acc_write.bytes * 1e3 / (double)acc_write.ns);
      put(fd, buf, len);
      memset(&acc_read, 0, sizeof acc_read);
      memset(&acc_write, 0, sizeof acc_write);
   }
   close(fd);
}

void *memcpy(void *d, const void *s, size_t n)
{
   if (n < LO || n > HI) {
      if (!real_memcpy) {
         if (initing)
            return slow_copy(d, s, n);
         initing = 1;
         real_memcpy = dlsym(RTLD_NEXT, "memcpy");
         initing = 0;
         if (!real_memcpy)
            return slow_copy(d, s, n);
      }
      return real_memcpy(d, s, n);
   }
   if (fixed_mode == -2) {
      const char *e = getenv("MCPROBE_MODE");
      const char *l = getenv("MCPROBE_LOG");
      if (l)
         log_path = l;
      fixed_mode = (!e || !strcmp(e, "rot")) ? -1 : atoi(e);
      t_start = t_dump = now_ns();
   }
   uint64_t t0 = now_ns();
   int m = fixed_mode >= 0 ? fixed_mode : (int)(((t0 - t_start) / 4000000000ull) % 5);
   uint64_t tr = 0, tw = 0;
   unsigned char *dd = d;
   const unsigned char *ss = s;
   switch (m) {
   case 1: copy_avx(dd, ss, n); break;
   case 2: copy_nt(dd, ss, n); break;
   case 3: copy_ntload(dd, ss, n); break;
   case 4: copy_q(dd, ss, n); break;
   case 9: {
      uint64_t a = now_ns(), sum = 0;
      for (size_t i = 0; i + 8 <= n; i += 8)
         sum += *(const volatile uint64_t *)(ss + i);
      sink = sum;
      uint64_t b = now_ns();
      for (size_t i = 0; i + 8 <= n; i += 8)
         *(volatile uint64_t *)(dd + i) = 0;
      uint64_t c = now_ns();
      tr = b - a;
      tw = c - b;
      copy_rep(dd, ss, n);
      break;
   }
   default: copy_rep(dd, ss, n); break;
   }
   uint64_t t1 = now_ns();
   while (__sync_lock_test_and_set(&lock, 1))
      ;
   acc_copy[m].calls++;
   acc_copy[m].bytes += n;
   acc_copy[m].ns += t1 - t0 - tr - tw;
   if (m == 9) {
      acc_read.calls++;
      acc_read.bytes += n;
      acc_read.ns += tr;
      acc_write.bytes += n;
      acc_write.ns += tw;
   }
   if (t1 - t_dump > 4000000000ull) {
      t_dump = t1;
      dump(t1);
   }
   __sync_lock_release(&lock);
   return d;
}
