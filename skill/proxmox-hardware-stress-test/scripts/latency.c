/*
 * latency.c - single-thread random pointer-chase load latency
 * for the proxmox-hardware-stress-test skill (used by ram.sh).
 *
 * Build:  gcc -O2 -o latency latency.c
 * Usage:  [taskset -c CPU] ./latency BUFFER_KB [ITERATIONS]
 *           BUFFER_KB   working-set size in KiB (e.g. 32, 1024, 4194304)
 *           ITERATIONS  dependent loads to time (default 20,000,000)
 *
 * One pointer per 64-byte cache line, linked in a random cyclic order
 * (Sattolo shuffle), so every load depends on the previous one and hardware
 * prefetchers cannot help. Buffers that fit in L1/L2/L3 measure cache
 * latency; buffers many times larger than L3 measure DRAM latency. With
 * normal 4 KiB pages large buffers also include TLB-miss cost, so the DRAM
 * figure is typically 5-15 ns higher than vendor "idle latency" numbers.
 *
 * Output (parsed by ram.sh):
 *   buffer_KB=<n> ns_per_load=<x>
 */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s BUFFER_KB [ITERATIONS]\n", argv[0]); return 2; }
  size_t kb = (size_t)strtoull(argv[1], NULL, 10);
  size_t iters = (argc > 2) ? (size_t)strtoull(argv[2], NULL, 10) : 20000000UL;
  const size_t line = 64;
  size_t n = kb * 1024 / line;
  if (n < 4) { fprintf(stderr, "latency: buffer too small\n"); return 2; }
  if (iters < 1000) iters = 1000;

  char *buf = NULL;
  if (posix_memalign((void **)&buf, 4096, n * line) != 0) { fprintf(stderr, "latency: cannot allocate %zu KB\n", kb); return 3; }
  size_t *idx = malloc(n * sizeof(size_t));
  if (!idx) { fprintf(stderr, "latency: cannot allocate index\n"); free(buf); return 3; }
  for (size_t i = 0; i < n; i++) idx[i] = i;

  /* Sattolo's algorithm -> a single cycle through all lines */
  uint64_t r = 88172645463325252ULL;
  for (size_t i = n - 1; i > 0; i--) {
    r ^= r << 13; r ^= r >> 7; r ^= r << 17;
    size_t j = (size_t)(r % i);
    size_t t = idx[i]; idx[i] = idx[j]; idx[j] = t;
  }
  for (size_t i = 0; i < n; i++)
    *(void **)(buf + idx[i] * line) = (void *)(buf + idx[(i + 1) % n] * line);
  free(idx);

  void **p = (void **)buf;
  /* warm-up: one lap (bounded) */
  for (size_t i = 0; i < n && i < iters; i++) p = (void **)*p;
  double t = now();
  for (size_t i = 0; i < iters; i++) p = (void **)*p;
  t = now() - t;

  /* print p so the chase cannot be optimised away */
  printf("buffer_KB=%zu ns_per_load=%.2f (%p)\n", kb, t / (double)iters * 1e9, (void *)p);
  free(buf);
  return 0;
}
