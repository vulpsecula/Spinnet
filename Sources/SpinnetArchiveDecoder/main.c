// The only archive parser: unprivileged, confined, no filesystem output.
#include <stdint.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <spawn.h>
#include <sys/wait.h>
#include <signal.h>
#include <stdio.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include "pbzx_stream.h"
#include "xar_stream.h"

// The macOS SDK provides the system libarchive link stub but omits its
// headers. These opaque public declarations match libarchive v3.7.4's
// archive.h/archive_entry.h; no private Apple API is used.
struct archive; struct archive_entry;
extern struct archive *archive_read_new(void);
extern int archive_read_support_format_tar(struct archive *);
extern int archive_read_support_format_zip(struct archive *);
extern int archive_read_support_format_xar(struct archive *);
extern int archive_read_support_format_cpio(struct archive *);
extern int archive_read_support_filter_none(struct archive *);
extern int archive_read_support_filter_gzip(struct archive *);
extern int archive_read_support_filter_bzip2(struct archive *);
extern int archive_read_support_filter_xz(struct archive *);
extern int archive_read_support_filter_zstd(struct archive *);
extern int archive_read_set_format_option(struct archive *,const char *,const char *,const char *);
extern int archive_read_open_fd(struct archive *,int,size_t);
extern int archive_read_open(struct archive *,void *,int (*)(struct archive *,void *),ssize_t (*)(struct archive *,void *,const void **),int (*)(struct archive *,void *));
extern int archive_read_next_header(struct archive *,struct archive_entry **);
extern int archive_read_free(struct archive *);
extern int archive_read_data_block(struct archive *,const void **,size_t *,int64_t *);
extern const char *archive_entry_pathname_utf8(struct archive_entry *);
extern const char *archive_entry_hardlink_utf8(struct archive_entry *);
extern const char *archive_entry_symlink_utf8(struct archive_entry *);
extern mode_t archive_entry_filetype(struct archive_entry *);
extern mode_t archive_entry_perm(struct archive_entry *);
extern int64_t archive_entry_size(struct archive_entry *);
extern int archive_entry_is_encrypted(struct archive_entry *);
extern int archive_entry_sparse_count(struct archive_entry *);
#define ARCHIVE_OK 0
#define ARCHIVE_EOF 1
#define AE_IFREG S_IFREG
#define AE_IFDIR S_IFDIR
#define AE_IFLNK S_IFLNK

static int send_bytes(const void *p, size_t n) {
    while (n) { ssize_t written = write(1, p, n); if (written < 0 && errno == EINTR) continue; if (written <= 0) return -1; p = (const char *)p + written; n -= (size_t)written; } return 0;
}
static int copy_name(const char *value, char **output) {
    *output=NULL; if (!value) return 0;
    size_t count=strnlen(value,2049); if (count>2048) return -1;
    *output=malloc(count+1); if (!*output) return -1;
    memcpy(*output,value,count); (*output)[count]=0; return 0;
}
static void u32(unsigned char *p, uint32_t n) { for (int i=3;i>=0;i--) { p[i]=(unsigned char)n; n >>= 8; } }
static void u64(unsigned char *p, uint64_t n) { for (int i=7;i>=0;i--) { p[i]=(unsigned char)n; n >>= 8; } }
static int frame(unsigned char kind, unsigned char execute, const char *path, const char *link, uint64_t size) {
    size_t pn=path ? strnlen(path, 2049) : 0, ln=link ? strnlen(link, 2049) : 0;
    if (pn>2048 || ln>2048 || (kind && !pn)) return -1;
    unsigned char h[24]={ 'S','P','A','1', kind, execute, 0, 0 };
    u32(h+8,(uint32_t)pn); u32(h+12,(uint32_t)ln); u64(h+16,size);
    return send_bytes(h,sizeof h) || (pn && send_bytes(path,pn)) || (ln && send_bytes(link,ln));
}
static int confined(void) {
    // Fail before parsing unless actual resource acquisition remains denied.
    // Opening the root directory for dyld does not grant descendant files.
    // The diagnostic canary is a harmless sibling of our own fixed executable,
    // not an actual private user file. It is never read or written.
    char path[PATH_MAX]; uint32_t length=sizeof path;
    if (_NSGetExecutablePath(path,&length)) return 0;
    char *leaf=strrchr(path,'/'); if (!leaf || (size_t)(leaf-path)+24>=sizeof path) return 0;
    strcpy(leaf+1,"SpinnetArchiveCanary");
    int fd=open(path,O_RDONLY); if (fd>=0) { close(fd); return 0; }
    if (errno!=EPERM && errno!=EACCES && errno!=ENOENT) return 0;
    fd=open(path,O_WRONLY); if (fd>=0) { close(fd); return 0; }
    if (errno!=EPERM && errno!=EACCES && errno!=ENOENT) return 0;
    fd=socket(AF_INET,SOCK_STREAM,0);
    if (fd>=0) {
        struct sockaddr_in target={0}; target.sin_len=sizeof target; target.sin_family=AF_INET; target.sin_port=htons(9); target.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
        int result=connect(fd,(struct sockaddr *)&target,sizeof target), error=errno; close(fd);
        if (result==0 || (error!=EPERM && error!=EACCES)) return 0;
    } else if (errno!=EPERM && errno!=EACCES) return 0;
    pid_t child; char *args[]={"/usr/bin/true",NULL}, *env[]={NULL};
    int result=posix_spawn(&child,args[0],NULL,NULL,args,env);
    if (!result) { kill(child,SIGKILL); while (waitpid(child,NULL,0)<0 && errno==EINTR) {}; return 0; }
    return result==EPERM || result==EACCES;
}
int main(int argc, char **argv) {
    (void)argv;
    if (argc!=1 || getuid()==0 || geteuid()!=getuid() || getegid()!=getgid()) return 70;
    if (!confined()) return 77;
    unsigned char magic[4];
    if (pread(3,magic,4,0)==4 && !memcmp(magic,"xar!",4)) {
        int result=spinnet_xar_emit(3,frame,send_bytes);
        if (result) fprintf(stderr,"archive decoder rejected stage %d\n",result);
        return result;
    }
    struct archive *a=archive_read_new(); if (!a) return 71;
    spinnet_pbzx_stream pbzx={0}; int pbzx_active=0;
    char *path=NULL, *link=NULL;
    int status=78;
    int (*support[])(struct archive *)={ archive_read_support_format_tar, archive_read_support_format_zip,
        archive_read_support_format_xar, archive_read_support_format_cpio,
        archive_read_support_filter_none, archive_read_support_filter_gzip, archive_read_support_filter_bzip2,
        archive_read_support_filter_xz };
    for (unsigned i=0;i<sizeof support/sizeof support[0];i++) {
        if (support[i](a)!=ARCHIVE_OK) { fprintf(stderr,"archive decoder unavailable format/filter %u\n",i); goto done; }
    }
    if (archive_read_set_format_option(a,"zip","mac-ext",NULL)!=ARCHIVE_OK || archive_read_set_format_option(a,"tar","mac-ext",NULL)!=ARCHIVE_OK) goto done;
    // No support-all, external-program filters, ACL or macOS metadata restoration.
    status=79; pbzx_active=spinnet_pbzx_open(&pbzx,3);
    if (pbzx_active<0 || (pbzx_active ? archive_read_open(a,&pbzx,NULL,spinnet_pbzx_read,NULL) : archive_read_open_fd(a,3,65536))!=ARCHIVE_OK) goto done; status=80;
    struct archive_entry *e; unsigned entries=0; uint64_t expanded=0;
    for (;;) {
        free(path); free(link); path=NULL; link=NULL;
        int next=archive_read_next_header(a,&e);
        if (next==ARCHIVE_EOF) {
            if (pbzx_active && spinnet_pbzx_finish(&pbzx)) { status=88; break; }
            status=frame(0,0,NULL,NULL,0) ? 72 : 0; break;
        }
        if (next!=ARCHIVE_OK || ++entries>50000 || archive_entry_is_encrypted(e)>0 || archive_entry_sparse_count(e)>0) { status=81; break; }
        // Freeze each bounded property before subsequent library getter calls.
        if (copy_name(archive_entry_pathname_utf8(e),&path) || !path ||
            copy_name(archive_entry_hardlink_utf8(e),&link)) { status=82; break; }
        unsigned char kind=0; mode_t type=archive_entry_filetype(e);
        if (link) kind=4;
        else if (type==AE_IFREG) kind=1;
        else if (type==AE_IFDIR) kind=2;
        else if (type==AE_IFLNK) { kind=3; if (copy_name(archive_entry_symlink_utf8(e),&link) || !link) break; }
        else { status=82; break; }
        int64_t size=kind==1 ? archive_entry_size(e) : 0;
        if (size<0 || (uint64_t)size>UINT64_C(8589934592)-expanded) { status=83; break; }
        if (frame(kind,(archive_entry_perm(e)&S_IXUSR)!=0,path,link,(uint64_t)size)) { status=84; break; }
        uint64_t received=0; unsigned empty_blocks=0;
        for (;;) {
            const void *buffer=NULL; size_t n=0; int64_t offset=0;
            int block=archive_read_data_block(a,&buffer,&n,&offset);
            if (block==ARCHIVE_EOF) break;
            if (block!=ARCHIVE_OK) { status=85; goto done; }
            if (!n) { if (++empty_blocks>8) { status=86; goto done; }; continue; }
            empty_blocks=0;
            if (!buffer || kind!=1 || offset<0 || (uint64_t)offset!=received || (uint64_t)n>(uint64_t)size-received) { status=86; goto done; }
            const unsigned char *bytes=buffer; size_t left=n;
            while (left) { size_t chunk=left>65536 ? 65536 : left; if (send_bytes(bytes,chunk)) { status=86; goto done; }; bytes+=chunk; left-=chunk; }
            received+=(uint64_t)n;
        }
        if (received!=(uint64_t)size) { status=87; break; }
        expanded+=received;
    }
    done: if (status) fprintf(stderr,"archive decoder rejected stage %d\n",status); free(path); free(link); archive_read_free(a); spinnet_pbzx_close(&pbzx); return status;
}
