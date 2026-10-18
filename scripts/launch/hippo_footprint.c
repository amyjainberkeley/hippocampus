// hippo_footprint.c: content-free footprint sampler for every process running from an app bundle.
//
// Build:  clang -O2 -o hippo_footprint hippo_footprint.c
// Run:    ./hippo_footprint [seconds=3600] [interval=10] [bundle=/Applications/Hippocampus.app/] > hour.csv
//
// No root. Reads proc_pid_rusage(RUSAGE_INFO_V6) for each PID whose executable lives under the bundle
// (menu-bar app, capture helper, OCR worker, agent, MCP servers started by AI tools, Ask, setup).
// It reads counters only: CPU time, P-core time, CPU energy, memory footprint, wakeups and disk I/O.
// It never reads window contents, files or memory contents.
//
// CSV, one row per sampling interval, summed over all matching processes:
//   t_s, procs, cpu_pct_one_core, cpu_pct_machine, pcore_share, cpu_energy_mW, phys_fp_MB,
//   max_fp_MB (largest interval peak of any one process), neural_fp_MB, pkg_idle_wakeups_per_s,
//   disk_write_MB
// A summary goes to stderr at the end: hour average and p95 of 60 s windows for CPU, energy and memory.
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <unistd.h>

#define MAXP 4096
typedef struct { int pid; uint64_t cpu, pcpu, nj, wk, dw; int seen; } Prev;
static Prev prev[MAXP];
static int nprev = 0;

static Prev *lookup(int pid) {
  for (int i = 0; i < nprev; i++) if (prev[i].pid == pid) return &prev[i];
  if (nprev == MAXP) return NULL;
  prev[nprev] = (Prev){ .pid = pid };
  return &prev[nprev++];
}

static int cmpd(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return (x > y) - (x < y);
}

static double pctl(double *v, int n, double p) {
  if (n == 0) return 0;
  double *c = malloc(sizeof(double) * n);
  memcpy(c, v, sizeof(double) * n);
  qsort(c, n, sizeof(double), cmpd);
  double r = c[(int)(p * (n - 1) + 0.5)];
  free(c);
  return r;
}

int main(int argc, char **argv) {
  int seconds = argc > 1 ? atoi(argv[1]) : 3600;
  int interval = argc > 2 ? atoi(argv[2]) : 10;
  const char *bundle = argc > 3 ? argv[3] : "/Applications/Hippocampus.app/";
  int ncpu = 0; size_t len = sizeof(ncpu);
  sysctlbyname("hw.logicalcpu", &ncpu, &len, NULL, 0);
  mach_timebase_info_data_t tb; mach_timebase_info(&tb);
  int rows = seconds / interval + 1;
  double *cpu = calloc(rows, sizeof(double)), *mw = calloc(rows, sizeof(double)), *fp = calloc(rows, sizeof(double));
  double maxfp_all = 0;
  printf("t_s,procs,cpu_pct_one_core,cpu_pct_machine,pcore_share,cpu_energy_mW,phys_fp_MB,max_fp_MB,neural_fp_MB,"
         "pkg_idle_wakeups_per_s,disk_write_MB\n");
  int n = 0;
  for (int t = 0; t <= seconds; t += interval) {
    int pids[MAXP];
    int count = proc_listallpids(pids, sizeof(pids)) ;
    double dcpu = 0, dpcpu = 0, dnj = 0, dwk = 0, ddw = 0, fpsum = 0, fpmax = 0, neural = 0;
    int procs = 0;
    for (int i = 0; i < nprev; i++) prev[i].seen = 0;
    for (int i = 0; i < count; i++) {
      char path[PROC_PIDPATHINFO_MAXSIZE];
      if (proc_pidpath(pids[i], path, sizeof(path)) <= 0) continue;
      if (strncmp(path, bundle, strlen(bundle)) != 0) continue;
      struct rusage_info_v6 ri;
      if (proc_pid_rusage(pids[i], RUSAGE_INFO_V6, (rusage_info_t *)&ri) != 0) continue;
      uint64_t c = ri.ri_user_time + ri.ri_system_time, pc = ri.ri_user_ptime + ri.ri_system_ptime;
      Prev *p = lookup(pids[i]);
      if (!p) continue;
      if (t > 0 && p->cpu) {  // a process first seen now contributes from its next interval
        dcpu += c - p->cpu; dpcpu += pc - p->pcpu; dnj += ri.ri_energy_nj - p->nj;
        dwk += ri.ri_pkg_idle_wkups - p->wk; ddw += ri.ri_diskio_byteswritten - p->dw;
      }
      p->cpu = c; p->pcpu = pc; p->nj = ri.ri_energy_nj; p->wk = ri.ri_pkg_idle_wkups;
      p->dw = ri.ri_diskio_byteswritten; p->seen = 1;
      fpsum += ri.ri_phys_footprint / 1048576.0;
      double m = ri.ri_interval_max_phys_footprint / 1048576.0;  // peak since the last read of this counter
      if (m > fpmax) fpmax = m;
      neural += ri.ri_neural_footprint / 1048576.0;
      procs++;
    }
    if (t > 0) {
      double cpu_s = dcpu * tb.numer / tb.denom / 1e9;
      double pct = 100.0 * cpu_s / interval;
      cpu[n] = pct; mw[n] = dnj / 1e6 / interval; fp[n] = fpsum; n++;
      if (fpmax > maxfp_all) maxfp_all = fpmax;
      printf("%d,%d,%.2f,%.3f,%.2f,%.1f,%.1f,%.1f,%.1f,%.2f,%.2f\n", t, procs, pct, pct / ncpu,
             dcpu ? dpcpu / dcpu : 0, dnj / 1e6 / interval, fpsum, fpmax, neural, dwk / interval, ddw / 1048576.0);
      fflush(stdout);
    }
    if (t + interval <= seconds) sleep(interval);
  }
  // 60 s windows from consecutive intervals.
  int w = 60 / interval > 0 ? 60 / interval : 1, nw = n / w;
  double *win = calloc(nw > 0 ? nw : 1, sizeof(double));
  for (int i = 0; i < nw; i++) { double s = 0; for (int j = 0; j < w; j++) s += cpu[i * w + j]; win[i] = s / w; }
  double avg = 0, avg_mw = 0;
  for (int i = 0; i < n; i++) { avg += cpu[i]; avg_mw += mw[i]; }
  avg /= n ? n : 1; avg_mw /= n ? n : 1;
  fprintf(stderr, "logical cpus: %d\n", ncpu);
  fprintf(stderr, "CPU average: %.2f%% of one core = %.3f%% of the machine\n", avg, avg / ncpu);
  fprintf(stderr, "CPU p95 of 60 s windows: %.2f%% of one core = %.3f%% of the machine\n", pctl(win, nw, 0.95), pctl(win, nw, 0.95) / ncpu);
  fprintf(stderr, "CPU energy average: %.0f mW (CPU only; ANE and GPU need powermetrics)\n", avg_mw);
  fprintf(stderr, "Memory footprint, all processes: p95 %.0f MB, largest single-process peak %.0f MB\n", pctl(fp, n, 0.95), maxfp_all);
  return 0;
}
