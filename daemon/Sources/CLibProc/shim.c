#include "include/CLibProc.h"

int memagent_pid_rusage(int pid, memagent_rusage *out) {
    struct rusage_info_v4 ri;
    int rc = proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri);
    if (rc != 0) return rc;
    out->phys_footprint = ri.ri_phys_footprint;
    out->resident_size = ri.ri_resident_size;
    out->lifetime_max_phys_footprint = ri.ri_lifetime_max_phys_footprint;
    out->cpu_user = ri.ri_user_time;
    out->cpu_system = ri.ri_system_time;
    out->proc_start_abstime = ri.ri_proc_start_abstime;
    return 0;
}

int memagent_list_pids(int *buf, int capacity_ints) {
    return proc_listallpids(buf, capacity_ints * (int)sizeof(int));
}

int memagent_pid_name(int pid, char *buf, uint32_t bufsize) {
    return proc_name(pid, buf, bufsize);
}
