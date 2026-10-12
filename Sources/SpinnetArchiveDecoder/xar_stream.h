#ifndef SPINNET_XAR_STREAM_H
#define SPINNET_XAR_STREAM_H
#include <stdint.h>
#include <stddef.h>
int spinnet_xar_emit(int fd, int (*frame)(unsigned char,unsigned char,const char *,const char *,uint64_t), int (*bytes)(const void *,size_t));
#endif
