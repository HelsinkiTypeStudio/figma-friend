#ifndef CZLIB_H
#define CZLIB_H
#include <stddef.h>

/// Inflates zlib, gzip or raw deflate data. Returns a malloc'd buffer (free with cz_free) and sets *out_len.
/// *complete is 1 when the stream ended cleanly, 0 when the data was cut off or damaged (the bytes
/// decoded before the damage are still returned). Returns NULL when nothing could be decoded.
unsigned char *cz_inflate(const unsigned char *in, size_t in_len, size_t *out_len, int *complete);

/// Deflates with a zlib header (what PDF's FlateDecode expects). Returns a malloc'd buffer or NULL.
unsigned char *cz_deflate(const unsigned char *in, size_t in_len, int level, size_t *out_len);

void cz_free(void *p);

#endif
