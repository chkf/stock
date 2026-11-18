#ifndef STOCK_RESEARCH_ARCHIVE_H
#define STOCK_RESEARCH_ARCHIVE_H
#include <stddef.h>
#include <stdint.h>
void sr_digest(const uint8_t *bytes, size_t size, uint8_t out[32]);
int sr_range_digest(const char *path, int64_t offset, int64_t length, uint8_t out[32]);
int sr_gunzip(const uint8_t *input, size_t size, size_t limit, uint8_t **output, size_t *used);
void sr_release(void *buffer);
int sr_gb18030_utf8(const uint8_t *input, size_t size, uint8_t **output, size_t *used);
#endif
