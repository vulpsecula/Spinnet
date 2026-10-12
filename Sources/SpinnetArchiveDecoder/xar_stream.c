// Public Apple SDK XAR streaming APIs. This file is linked only into the
// unprivileged confined decoder; it never extracts to a filesystem path.
#include "xar_stream.h"
#include <xar/xar.h>
#include <zlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#define SP_XAR_LIMIT UINT64_C(8589934592)
static uint64_t value64(const uint8_t *p) { uint64_t n=0; for (unsigned i=0;i<8;i++) n=(n<<8)|p[i]; return n; }
static int read_at(int fd, void *data, size_t count, uint64_t offset) {
    size_t done=0; while (done<count) {
        ssize_t n=pread(fd,(uint8_t *)data+done,count-done,(off_t)(offset+done));
        if (n<0 && errno==EINTR) continue; if (n<=0) return -1; done+=(size_t)n;
    } return 0;
}
static int number(const char *text, unsigned base, uint64_t maximum, uint64_t *output) {
    if (!text || !*text || strnlen(text,32)>31) return -1;
    uint64_t n=0; for (const char *p=text;*p;p++) {
        if (*p<'0' || *p>='0'+(int)base) return -1;
        unsigned digit=(unsigned)(*p-'0'); if (n>(maximum-digit)/base || digit>maximum) return -1; n=n*base+digit;
    } *output=n; return 0;
}
static int bounded_toc(int fd) {
    uint8_t header[28]; struct stat info;
    if (fstat(fd,&info) || !S_ISREG(info.st_mode) || info.st_size<28 || (uint64_t)info.st_size>SP_XAR_LIMIT || read_at(fd,header,28,0)) return 91;
    if (memcmp(header,"xar!",4) || header[6]!=0 || header[7]!=1) return 91;
    uint64_t start=((uint64_t)header[4]<<8)|header[5], compressed=value64(header+8), plain=value64(header+16);
    if (start<28 || start>4096 || !compressed || compressed>8*1024*1024 || !plain || plain>32*1024*1024) return 89;
    if (start>(uint64_t)info.st_size || compressed>(uint64_t)info.st_size-start) return 91;
    uint8_t *input=malloc((size_t)compressed), *output=malloc((size_t)plain+1);
    if (!input || !output) { free(input); free(output); return 89; }
    int result=91;
    if (!read_at(fd,input,(size_t)compressed,start)) {
        z_stream stream={0}; stream.next_in=input; stream.avail_in=(uInt)compressed;
        stream.next_out=output; stream.avail_out=(uInt)plain+1;
        if (inflateInit(&stream)==Z_OK) {
            int state=inflate(&stream,Z_FINISH);
            if (state==Z_STREAM_END && stream.total_in==compressed && stream.total_out==plain) {
                output[plain]=0;
                // XML TOC must not expand entities or read external resources.
                // Root never sees/parses this XML; the worker still has RSS/CPU
                // bounds and denies all outside file/network acquisition.
                if (!memchr(output,0,(size_t)plain) && !strstr((char *)output,"<!DOCTYPE") && !strstr((char *)output,"<!ENTITY")) result=0;
            }
            inflateEnd(&stream);
        }
    }
    free(input); free(output); return result;
}
// Existing PKG interoperability requires the public deprecated XAR format APIs.
// The raw path is data for Root's descriptor-relative traversal rejection; no
// xar_extract/xar_extract_tofile or arbitrary pathname opening is permitted.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
int spinnet_xar_emit(int fd, int (*frame)(unsigned char,unsigned char,const char *,const char *,uint64_t), int (*bytes)(const void *,size_t)) {
    int status=bounded_toc(fd); if (status) return status;
    xar_t archive=NULL;
#if defined(SPINNET_XAR_FD_PATH_FIXTURE)
    // Owned diagnostic build only: exercise the public macOS14 fd pathname
    // branch on the current system without claiming actual OS14 acceptance.
    if (fd!=3) return 91;
    if (dup2(3,4)!=4) return 91;
    errno=0; int probe=open("/dev/fd/4",O_RDONLY), probe_error=errno;
    if (probe>=0) close(probe);
    close(4);
    fprintf(stderr,"fixed fd4 pathname probe status %d errno %d\n",probe>=0?1:0,probe_error);
    if (probe>=0 || (probe_error!=EPERM && probe_error!=EACCES)) return 91;
    archive=xar_open("/dev/fd/3",READ);
    if (!archive) { fprintf(stderr,"fixed fd3 XAR pathname errno %d\n",errno); return 91; }
#else
    if (__builtin_available(macOS 15.0,*)) {
        int copy=dup(fd); if (copy<0) return 91;
        archive=xar_fdopen_digest_verify(copy,READ,NULL,0);
        if (!archive) { close(copy); return 91; }
    } else {
        // macOS14 public API: only this inherited held read-only capability,
        // never a Plugin/user-resolvable source pathname.
        if (fd!=3) return 91;
        archive=xar_open("/dev/fd/3",READ);
        if (!archive) return 91;
    }
#endif
    xar_iter_t iterator=xar_iter_new(); if (!iterator) { xar_close(archive); return 89; }
    unsigned count=0; uint64_t expanded=0; status=0;
    for (xar_file_t file=xar_file_first(archive,iterator);file;file=xar_file_next(iterator)) {
        if (++count>50000) { status=89; break; }
        char *path=xar_get_path(file);
        const char *type=NULL, *mode_text=NULL, *size_text=NULL, *link=NULL;
        uint64_t mode=0, size=0; unsigned char kind=0;
        if (!path || !*path || strnlen(path,2049)>2048 || xar_prop_get(file,"type",&type) || !type) { free(path); status=91; break; }
        if (!strcmp(type,"directory")) kind=2;
        else if (!strcmp(type,"file")) kind=1;
        else if (!strcmp(type,"symlink")) {
            kind=3; if (xar_prop_get(file,"link",&link) || !link || strnlen(link,2049)>2048) { free(path); status=91; break; }
        } else { free(path); status=91; break; }
        if (xar_prop_get(file,"mode",&mode_text)==0 && number(mode_text,8,07777,&mode)) { free(path); status=91; break; }
        if (kind==1) {
            if (xar_prop_get(file,"data/size",&size_text) || number(size_text,10,SP_XAR_LIMIT,&size)) { free(path); status=91; break; }
            if (size>SP_XAR_LIMIT-expanded) { free(path); status=89; break; }
        }
        if (frame(kind,(mode&S_IXUSR)!=0,path,link,size)) { free(path); status=91; break; }
        free(path);
        if (kind!=1) continue;
        xar_stream stream={0}; if (xar_extract_tostream_init(archive,file,&stream)!=XAR_STREAM_OK) { status=91; break; }
        uint8_t buffer[65536]; uint64_t received=0; int state;
        do {
            stream.next_out=(char *)buffer; stream.avail_out=sizeof buffer;
            state=xar_extract_tostream(&stream);
            size_t produced=sizeof buffer-stream.avail_out;
            if (state==XAR_STREAM_ERR || produced>size-received || (!produced && state!=XAR_STREAM_END) || (produced && bytes(buffer,produced))) { status=91; break; }
            received+=produced;
        } while (state!=XAR_STREAM_END);
        if (xar_extract_tostream_end(&stream)!=XAR_STREAM_OK || received!=size) status=91;
        if (status) break;
        expanded+=received;
    }
    if (!status && frame(0,0,NULL,NULL,0)) status=91;
    xar_iter_free(iterator); xar_close(archive); return status;
}
#pragma clang diagnostic pop
