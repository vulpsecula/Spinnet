#ifndef SPINNET_PBZX_STREAM_H
#define SPINNET_PBZX_STREAM_H
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
struct archive;
typedef struct {
    int fd;
    uint64_t input_size, offset, block_size, expanded;
    uint8_t *decoded;
    size_t decoded_size, cursor;
    int failed;
} spinnet_pbzx_stream;
/* 1 documented PBZX, 0 another format, -1 malformed/bounded refusal. */
int spinnet_pbzx_open(spinnet_pbzx_stream *, int);
ssize_t spinnet_pbzx_read(struct archive *, void *, const void **);
int spinnet_pbzx_finish(spinnet_pbzx_stream *);
void spinnet_pbzx_close(spinnet_pbzx_stream *);
#endif
