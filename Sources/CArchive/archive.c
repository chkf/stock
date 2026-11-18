#include "CArchive.h"
#include <limits.h>
#include <iconv.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>
#ifdef __APPLE__
#include <CommonCrypto/CommonDigest.h>
typedef CC_SHA256_CTX sr_context;
#define init_sha(c) CC_SHA256_Init(c)
#define feed_sha(c,p,n) CC_SHA256_Update(c,p,(CC_LONG)(n))
#define finish_sha(c,p) CC_SHA256_Final(p,c)
#else
#include <openssl/sha.h>
typedef SHA256_CTX sr_context;
#define init_sha(c) SHA256_Init(c)
#define feed_sha(c,p,n) SHA256_Update(c,p,n)
#define finish_sha(c,p) SHA256_Final(p,c)
#endif

void sr_digest(const uint8_t *bytes, size_t size, uint8_t out[32]) {
    sr_context ctx;
    init_sha(&ctx);
    while (size) {
        size_t n = size > 1048576 ? 1048576 : size;
        feed_sha(&ctx, bytes, n);
        bytes += n;
        size -= n;
    }
    finish_sha(&ctx, out);
}

int sr_range_digest(const char *path, int64_t offset, int64_t length, uint8_t out[32]) {
    if (offset < 0 || length < 0) return -1;
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    int result = fseeko(f, (off_t)offset, SEEK_SET);
    sr_context ctx;
    init_sha(&ctx);
    uint8_t buffer[32768];
    while (!result && length > 0) {
        size_t n = length > (int64_t)sizeof(buffer) ? sizeof(buffer) : (size_t)length;
        if (fread(buffer, 1, n, f) != n) { result = -1; break; }
        feed_sha(&ctx, buffer, n);
        length -= n;
    }
    if (!result) finish_sha(&ctx, out);
    fclose(f);
    return result;
}

int sr_gunzip(const uint8_t *input, size_t size, size_t limit, uint8_t **output, size_t *used) {
    if (!size || size > UINT_MAX || !limit || limit > UINT_MAX) return -1;
    z_stream z = {0};
    if (inflateInit2(&z, 16 + MAX_WBITS) != Z_OK) return -1;
    z.next_in = (Bytef *)input;
    z.avail_in = (uInt)size;
    size_t capacity = limit < 65536 ? limit : 65536;
    uint8_t *bytes = malloc(capacity);
    int ok = 0;
    while (bytes) {
        z.next_out = bytes + z.total_out;
        z.avail_out = (uInt)(capacity - z.total_out);
        int status = inflate(&z, Z_NO_FLUSH);
        if (status == Z_STREAM_END) { ok = z.avail_in == 0; break; }
        if (status != Z_OK || z.avail_out || capacity == limit) break;
        capacity = capacity > limit / 2 ? limit : capacity * 2;
        uint8_t *larger = realloc(bytes, capacity);
        if (!larger) break;
        bytes = larger;
    }
    *used = (size_t)z.total_out;
    inflateEnd(&z);
    if (!ok) { free(bytes); return -1; }
    *output = bytes;
    return 0;
}

void sr_release(void *buffer) { free(buffer); }

int sr_gb18030_utf8(const uint8_t *input, size_t size, uint8_t **output, size_t *used) {
    if (!size || size > 8 * 1024 * 1024) return -1;
    iconv_t conv = iconv_open("UTF-8", "GB18030");
    if (conv == (iconv_t)-1) return -1;
    size_t available = size * 4, left = size;
    char *bytes = malloc(available), *dest = bytes, *src = (char *)input;
    size_t status = bytes ? iconv(conv, &src, &left, &dest, &available) : (size_t)-1;
    iconv_close(conv);
    if (status == (size_t)-1 || left) { free(bytes); return -1; }
    *output = (uint8_t *)bytes;
    *used = (size_t)(dest - bytes);
    return 0;
}
