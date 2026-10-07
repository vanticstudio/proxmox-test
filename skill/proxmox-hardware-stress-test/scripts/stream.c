/*
 * stream.c - STREAM-style memory bandwidth test (Copy / Scale / Add / Triad)
 * for the proxmox-hardware-stress-test skill (used by ram.sh).
 *
 * Build:  gcc -O3 -march=native -fopenmp -o stream stream.c
 *         (without -fopenmp it still builds and runs single-threaded)
 * Usage:  OMP_NUM_THREADS=n [OMP_PLACES=..] [OMP_PROC_BIND=..] ./stream [ELEMENTS] [NTIMES]
 *           ELEMENTS  doubles per array (default 100,000,000 = 800 MB/array, 2.4 GB total)
 *                     Each array must be >= 4x the total CPU cache, otherwise the
 *                     result measures cache, not RAM (ram.sh enforces this).
 *           NTIMES    repetitions, best of NTIMES-1 is reported (default 10, min 2)
 *
 * Byte counting follows McCalpin's STREAM: Copy/Scale 16 B per element,
 * Add/Triad 24 B per element; write-allocate traffic is NOT counted.
 * After the timed loops every element is checked against the expected value
 * (validation=ok|FAILED): a mismatch means a broken build or a memory error.
 *
 * Output (parsed by ram.sh):
 *   threads=<n> array_MB=<x> total_MB=<y> ntimes=<k>
 *   Copy   best_MB/s=<v> avg_MB/s=<v> best_time=<s>
 *   Scale  ...
 *   Add    ...
 *   Triad  ...
 *   validation=ok errors=0
 */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>
#ifdef _OPENMP
#include <omp.h>
#endif

static double now(void) {
#ifdef _OPENMP
  return omp_get_wtime();
#else
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
#endif
}

static double *alloc_array(long n) {
  void *p = NULL;
  if (posix_memalign(&p, 64, (size_t)n * sizeof(double)) != 0) return NULL;
  return (double *)p;
}

int main(int argc, char **argv) {
  long n = (argc > 1) ? atol(argv[1]) : 100000000L;
  int ntimes = (argc > 2) ? atoi(argv[2]) : 10;
  if (n < 100000) { fprintf(stderr, "stream: ELEMENTS too small (%ld)\n", n); return 2; }
  if (ntimes < 2) ntimes = 2;

  double *a = alloc_array(n), *b = alloc_array(n), *c = alloc_array(n);
  if (!a || !b || !c) { fprintf(stderr, "stream: cannot allocate 3 x %.1f MB\n", n * 8.0 / 1e6); return 3; }

  long j;
  /* first touch in parallel so pages land near the threads that use them */
  #pragma omp parallel for schedule(static)
  for (j = 0; j < n; j++) { a[j] = 1.0; b[j] = 2.0; c[j] = 0.0; }

  const double s = 3.0;
  const char *name[4] = {"Copy", "Scale", "Add", "Triad"};
  const double bytes[4] = {16.0 * n, 16.0 * n, 24.0 * n, 24.0 * n};
  double best[4] = {1e30, 1e30, 1e30, 1e30}, sum[4] = {0, 0, 0, 0};

  for (int k = 0; k < ntimes; k++) {
    double t;
    t = now();
    #pragma omp parallel for schedule(static)
    for (j = 0; j < n; j++) c[j] = a[j];
    t = now() - t; if (k) { sum[0] += t; if (t < best[0]) best[0] = t; }

    t = now();
    #pragma omp parallel for schedule(static)
    for (j = 0; j < n; j++) b[j] = s * c[j];
    t = now() - t; if (k) { sum[1] += t; if (t < best[1]) best[1] = t; }

    t = now();
    #pragma omp parallel for schedule(static)
    for (j = 0; j < n; j++) c[j] = a[j] + b[j];
    t = now() - t; if (k) { sum[2] += t; if (t < best[2]) best[2] = t; }

    t = now();
    #pragma omp parallel for schedule(static)
    for (j = 0; j < n; j++) a[j] = b[j] + s * c[j];
    t = now() - t; if (k) { sum[3] += t; if (t < best[3]) best[3] = t; }
  }

  /* expected values after ntimes iterations */
  double ea = 1.0, eb = 2.0, ec = 0.0;
  for (int k = 0; k < ntimes; k++) { ec = ea; eb = s * ec; ec = ea + eb; ea = eb + s * ec; }
  long errors = 0;
  #pragma omp parallel for schedule(static) reduction(+:errors)
  for (j = 0; j < n; j++) {
    if (fabs(a[j] - ea) > 1e-9 * fabs(ea) || fabs(b[j] - eb) > 1e-9 * fabs(eb) || fabs(c[j] - ec) > 1e-9 * fabs(ec)) errors++;
  }

  int threads = 1;
#ifdef _OPENMP
  threads = omp_get_max_threads();
#endif
  printf("threads=%d array_MB=%.1f total_MB=%.1f ntimes=%d\n", threads, n * 8.0 / 1e6, 3.0 * n * 8.0 / 1e6, ntimes);
  for (int i = 0; i < 4; i++) {
    double avg = sum[i] / (ntimes - 1);
    printf("%-6s best_MB/s=%.1f avg_MB/s=%.1f best_time=%.4f\n", name[i], bytes[i] / best[i] / 1e6, bytes[i] / avg / 1e6, best[i]);
  }
  printf("validation=%s errors=%ld\n", errors ? "FAILED" : "ok", errors);
  free(a); free(b); free(c);
  return errors ? 1 : 0;
}
