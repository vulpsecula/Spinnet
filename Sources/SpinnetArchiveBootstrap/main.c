// Fixed UID-drop bootstrap. Parses no archive data and accepts no command/profile.
#include <unistd.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <grp.h>
#include <stdint.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <fcntl.h>
#include <libproc.h>

static int identity(const char *s, unsigned *out) {
    if (!*s) return -1;
    uint64_t n=0; for (;*s;s++) { if (*s<'0'||*s>'9') return -1; n=n*10+(unsigned)(*s-'0'); if (n>UINT32_MAX) return -1; }
    *out=(unsigned)n; return 0;
}
static int limit(int resource, rlim_t value) { struct rlimit r={value,value}; int status=setrlimit(resource,&r); if (status) fprintf(stderr,"archive bootstrap resource %d: %s\n",resource,strerror(errno)); return status; }
int main(int argc, char **argv) {
    unsigned uid,gid;
    if (argc!=3 || identity(argv[1],&uid) || identity(argv[2],&gid) || !uid) return 70;
    char raw[PATH_MAX], executable[PATH_MAX], decoder[PATH_MAX]; uint32_t count=sizeof raw;
    if (_NSGetExecutablePath(raw,&count) || !realpath(raw,executable)) return 71;
    char *slash=strrchr(executable,'/'); if (!slash) return 71; *slash=0;
    if (snprintf(decoder,sizeof decoder,"%s/SpinnetArchiveDecoder",executable)>=(int)sizeof decoder) return 71;
    struct stat info; if (lstat(decoder,&info) || !S_ISREG(info.st_mode) || info.st_mode&022) return 71;
    // Modern macOS maps a large shared-cache/guard reservation (~466 GiB
    // on this host). A fixed small RLIMIT_AS is below the existing map and
    // fails EINVAL. Bound additional mappings above the measured fixed C
    // startup reservation; fail if its public proc information is unavailable.
    struct proc_taskinfo task;
    if (proc_pidinfo(getpid(),PROC_PIDTASKINFO,0,&task,sizeof task)!=sizeof task ||
        task.pti_virtual_size>UINT64_MAX-536870912) return 72;
    if (limit(RLIMIT_CORE,0) || limit(RLIMIT_CPU,30) || limit(RLIMIT_NOFILE,32) || limit(RLIMIT_STACK,8*1024*1024) ||
        limit(RLIMIT_AS,task.pti_virtual_size+536870912)) return 72;
    umask(077); if (chdir("/")) return 72;
    if (geteuid()==0) { if (setgroups(0,NULL) || setgid(gid) || setuid(uid)) return 73; }
    if (getuid()!=uid || geteuid()!=uid || getgid()!=gid || getegid()!=gid) return 73;
    if (fcntl(3,F_SETFD,0)) return 74;
    // Parent installs only fd0..3; close all other inherited descriptors.
    for (int fd=4;fd<32;fd++) close(fd);
    char profile[PATH_MAX*2];
    // Parameterised literal path is constrained to the admitted decoder sibling,
    // never caller text. Refuse SBPL metacharacters rather than quote them.
    if (strchr(decoder,'"') || strchr(decoder,'\\') || strchr(decoder,'\n')) return 75;
    int length=snprintf(profile,sizeof profile,
        "(version 1)(deny default)(deny network*)(deny process-fork)(deny file-write*)(allow process-exec (literal \"%s\"))"
        "(allow file-read* (literal \"/\") (literal \"%s\") (subpath \"/usr/lib\") (subpath \"/System/Library\") (subpath \"/System/Volumes/Preboot/Cryptexes/OS/System/Library\") (subpath \"/System/Volumes/Preboot/Cryptexes/Incoming/OS/System/Library\"))"
        "(allow file-read* (literal \"/dev/fd/3\"))"
        "(allow file-map-executable (literal \"%s\") (subpath \"/usr/lib\") (subpath \"/System/Library\") (subpath \"/System/Volumes/Preboot/Cryptexes/OS/System/Library\") (subpath \"/System/Volumes/Preboot/Cryptexes/Incoming/OS/System/Library\"))"
        "(allow sysctl-read)(allow mach-lookup (global-name \"com.apple.system.logger\"))",decoder,decoder,decoder);
    if (length<0 || length>=(int)sizeof profile) return 75;
    char *args[]={"/usr/bin/sandbox-exec","-p",profile,decoder,NULL};
    char *env[]={"LANG=C","LC_ALL=C",NULL};
    execve(args[0],args,env); return 76;
}
