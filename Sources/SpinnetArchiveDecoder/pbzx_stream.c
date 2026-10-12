// Public Apple compression_tool(1), BLOCK COMPRESSION FILE FORMAT; only its
// documented 'pbzx' XZ/LZMA form. No historical flag-format guesses or tools.
#include "pbzx_stream.h"
#include <compression.h>
#include <unistd.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#define SP_INPUT_MAX UINT64_C(8589934592)
#define SP_BLOCK_MAX UINT64_C(67108864)
static uint64_t be64(const uint8_t *bytes) {
    uint64_t value=0; for (unsigned i=0;i<8;i++) value=(value<<8)|bytes[i]; return value;
}
static int take(spinnet_pbzx_stream *s, uint8_t *output, size_t count) {
    if (s->offset>s->input_size || (uint64_t)count>s->input_size-s->offset) return -1;
    size_t done=0;
    while (done<count) {
        ssize_t n=pread(s->fd,output+done,count-done,(off_t)(s->offset+done));
        if (n<0 && errno==EINTR) continue;
        if (n<=0) return -1; done+=(size_t)n;
    }
    s->offset+=(uint64_t)count; return 0;
}
int spinnet_pbzx_open(spinnet_pbzx_stream *s, int fd) {
    memset(s,0,sizeof *s); s->fd=fd;
    struct stat status;
    if (fstat(fd,&status) || !S_ISREG(status.st_mode) || status.st_size<=0 || (uint64_t)status.st_size>SP_INPUT_MAX) return -1;
    s->input_size=(uint64_t)status.st_size;
    uint8_t magic[4]; ssize_t count;
    do { count=pread(fd,magic,4,0); } while (count<0 && errno==EINTR);
    if (count!=4 || memcmp(magic,"pbzx",4)) return 0;
    uint8_t header[12]; if (take(s,header,sizeof header)) return -1;
    s->block_size=be64(header+4);
    if (!s->block_size || s->block_size>SP_BLOCK_MAX) return -1;
    return 1;
}
static int block(spinnet_pbzx_stream *s) {
    free(s->decoded); s->decoded=NULL; s->decoded_size=0; s->cursor=0;
    if (s->offset==s->input_size) return 0;
    uint8_t header[16]; if (take(s,header,sizeof header)) return -1;
    uint64_t plain=be64(header), compressed=be64(header+8);
    if (!plain || plain>s->block_size || plain>SP_INPUT_MAX-s->expanded ||
        !compressed || compressed>SP_BLOCK_MAX || compressed>s->input_size-s->offset) return -1;
    s->decoded=malloc((size_t)plain+1); if (!s->decoded) return -1;
    if (plain==compressed) {
        if (take(s,s->decoded,(size_t)plain)) return -1;
    } else {
        uint8_t *input=malloc((size_t)compressed); if (!input) return -1;
        if (take(s,input,(size_t)compressed)) { free(input); return -1; }
        compression_stream stream={0};
        if (compression_stream_init(&stream,COMPRESSION_STREAM_DECODE,COMPRESSION_LZMA)!=COMPRESSION_STATUS_OK) { free(input); return -1; }
        stream.src_ptr=input; stream.src_size=(size_t)compressed;
        stream.dst_ptr=s->decoded; stream.dst_size=(size_t)plain+1;
        int valid=0;
        for (unsigned iteration=0;iteration<1024;iteration++) {
            size_t old_input=stream.src_size, old_output=stream.dst_size;
            compression_status status=compression_stream_process(&stream,COMPRESSION_STREAM_FINALIZE);
            if (status==COMPRESSION_STATUS_END) {
                valid=stream.src_size==0 && stream.dst_size==1; break;
            }
            if (status!=COMPRESSION_STATUS_OK || stream.dst_size==0 ||
                (stream.src_size==old_input && stream.dst_size==old_output)) break;
        }
        compression_stream_destroy(&stream); free(input);
        if (!valid) return -1;
    }
    s->decoded_size=(size_t)plain; s->expanded+=plain; return 1;
}
ssize_t spinnet_pbzx_read(struct archive *archive, void *opaque, const void **output) {
    (void)archive; spinnet_pbzx_stream *s=opaque;
    if (s->failed) return -1;
    if (s->cursor==s->decoded_size) {
        int result=block(s); if (result<0) { s->failed=1; return -1; } if (!result) return 0;
    }
    size_t count=s->decoded_size-s->cursor; if (count>65536) count=65536;
    *output=s->decoded+s->cursor; s->cursor+=count; return (ssize_t)count;
}
int spinnet_pbzx_finish(spinnet_pbzx_stream *s) {
    // Validate every remaining documented block even when cpio reaches its
    // trailer early. Never accept malformed/truncated trailing framing.
    if (s->failed) return -1;
    while (s->offset<s->input_size) { if (block(s)<=0) { s->failed=1; return -1; } }
    return 0;
}
void spinnet_pbzx_close(spinnet_pbzx_stream *s) { free(s->decoded); s->decoded=NULL; }
