#include "czlib.h"
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static unsigned char *run_inflate(const unsigned char *in, size_t in_len, int window_bits,
                                  size_t *out_len, int *complete) {
    z_stream s;
    memset(&s, 0, sizeof(s));
    if (inflateInit2(&s, window_bits) != Z_OK) return NULL;
    size_t cap = in_len * 4 + 1024, len = 0;
    unsigned char *out = malloc(cap);
    if (!out) { inflateEnd(&s); return NULL; }
    s.next_in = (Bytef *)in;
    int ret = Z_OK;
    size_t remaining = in_len;
    *complete = 0;
    while (1) {
        if (cap - len < 65536) {
            size_t ncap = cap * 2;
            unsigned char *n = realloc(out, ncap);
            if (!n) { free(out); inflateEnd(&s); return NULL; }
            out = n; cap = ncap;
        }
        unsigned int chunk_in = remaining > 0x40000000u ? 0x40000000u : (unsigned int)remaining;
        s.avail_in = chunk_in;
        size_t room = cap - len;
        s.avail_out = room > 0x40000000u ? 0x40000000u : (unsigned int)room;
        s.next_out = out + len;
        unsigned int before_out = s.avail_out;
        ret = inflate(&s, Z_NO_FLUSH);
        size_t consumed = chunk_in - s.avail_in;
        remaining -= consumed;
        len += before_out - s.avail_out;
        if (ret == Z_STREAM_END) { *complete = 1; break; }
        if (ret == Z_BUF_ERROR && remaining == 0) break;      /* input ended early */
        if (ret != Z_OK && ret != Z_BUF_ERROR) break;          /* damaged data */
        if (remaining == 0 && s.avail_out != 0) break;
    }
    inflateEnd(&s);
    if (len == 0 && !*complete) { free(out); return NULL; }
    *out_len = len;
    return out;
}

unsigned char *cz_inflate(const unsigned char *in, size_t in_len, size_t *out_len, int *complete) {
    unsigned char *r = run_inflate(in, in_len, 15 + 32, out_len, complete);   /* zlib or gzip */
    if (r) return r;
    return run_inflate(in, in_len, -15, out_len, complete);                  /* raw deflate */
}

unsigned char *cz_deflate(const unsigned char *in, size_t in_len, int level, size_t *out_len) {
    uLong cap = compressBound((uLong)in_len);
    unsigned char *out = malloc(cap ? cap : 16);
    if (!out) return NULL;
    z_stream s;
    memset(&s, 0, sizeof(s));
    if (deflateInit2(&s, level, Z_DEFLATED, 15, 9, Z_DEFAULT_STRATEGY) != Z_OK) { free(out); return NULL; }
    s.next_in = (Bytef *)in;
    s.avail_in = (uInt)in_len;
    s.next_out = out;
    s.avail_out = (uInt)cap;
    int ret = deflate(&s, Z_FINISH);
    if (ret != Z_STREAM_END) { deflateEnd(&s); free(out); return NULL; }
    *out_len = s.total_out;
    deflateEnd(&s);
    return out;
}

void cz_free(void *p) { free(p); }
