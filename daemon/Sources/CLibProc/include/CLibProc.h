#ifndef CLIBPROC_H
#define CLIBPROC_H

#include <stdint.h>
#include <libproc.h>
#include <sys/resource.h>
#include <sys/sysctl.h>

/* Flattened subset of rusage_info_v4 — the fields mem-agent cares about.
   proc_pid_rusage works unprivileged for same-uid processes; task_for_pid does not. */
typedef struct {
    uint64_t phys_footprint;              /* bytes; matches Activity Monitor "Memory" */
    uint64_t resident_size;               /* bytes */
    uint64_t lifetime_max_phys_footprint; /* bytes */
    uint64_t cpu_user;                    /* mach time units; only deltas matter */
    uint64_t cpu_system;                  /* mach time units */
    uint64_t proc_start_abstime;
} memagent_rusage;

int memagent_pid_rusage(int pid, memagent_rusage *out);

/* Returns number of pids written into buf (capacity in ints), or -1. */
int memagent_list_pids(int *buf, int capacity_ints);

/* Returns length of name written, 0 on failure. */
int memagent_pid_name(int pid, char *buf, uint32_t bufsize);

#endif
