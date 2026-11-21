#ifndef MOONREAD_AI_COVER_H
#define MOONREAD_AI_COVER_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    const uint8_t *data;
    size_t len;
} MoonreadCoverBytes;

// Inputs are borrowed for the call. Strings use UTF-8. Null means absent.
MoonreadCoverBytes moonread_ai_cover_extract(
    MoonreadCoverBytes body,
    MoonreadCoverBytes response_url,
    MoonreadCoverBytes charset,
    MoonreadCoverBytes title
);

// The output is a UTF-8 JSON array of URLs. Release it exactly once.
void moonread_ai_cover_release(MoonreadCoverBytes output);

#endif
