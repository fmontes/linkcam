#include "LinkCamMath.h"

#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

static bool ends_with_case_insensitive(const char *value, const char *suffix) {
    size_t valueLength = strlen(value);
    size_t suffixLength = strlen(suffix);
    if (suffixLength > valueLength) return false;

    const char *start = value + valueLength - suffixLength;
    for (size_t i = 0; i < suffixLength; i++) {
        if (tolower((unsigned char)start[i]) != tolower((unsigned char)suffix[i])) return false;
    }
    return true;
}

static bool parse_number_without_suffix(const char *input, size_t suffixLength, double *output) {
    if (!input || !output) return false;

    size_t length = strlen(input);
    if (length == 0 || length <= suffixLength || length - suffixLength >= 64) return false;

    char number[64];
    size_t numberLength = length - suffixLength;
    memcpy(number, input, numberLength);
    number[numberLength] = '\0';

    errno = 0;
    char *end = NULL;
    double value = strtod(number, &end);
    if (errno == ERANGE || end == number || *end != '\0' || !isfinite(value)) return false;

    *output = value;
    return true;
}

int32_t LinkCamClampAngleUnits(int64_t value, int32_t minimum, int32_t maximum) {
    if (value < minimum) value = minimum;
    if (value > maximum) value = maximum;

    double steps = (double)value / LINKCAM_ANGLE_STEP_UNITS;
    int64_t snapped = (int64_t)llround(steps) * LINKCAM_ANGLE_STEP_UNITS;
    if (snapped < minimum) snapped = minimum;
    if (snapped > maximum) snapped = maximum;
    return (int32_t)snapped;
}

uint16_t LinkCamClampZoomUnits(int64_t value) {
    if (value < LINKCAM_ZOOM_MIN_UNITS) return LINKCAM_ZOOM_MIN_UNITS;
    if (value > LINKCAM_ZOOM_MAX_UNITS) return LINKCAM_ZOOM_MAX_UNITS;
    return (uint16_t)value;
}

bool LinkCamParseAngle(const char *input, int32_t minimum, int32_t maximum, int32_t *output) {
    if (!input || !output) return false;

    bool rawUnits = false;
    size_t suffixLength = 0;
    if (ends_with_case_insensitive(input, "deg")) {
        suffixLength = 3;
    } else if (ends_with_case_insensitive(input, "d")) {
        suffixLength = 1;
    } else if (ends_with_case_insensitive(input, "u")) {
        suffixLength = 1;
        rawUnits = true;
    }

    double value = 0;
    if (!parse_number_without_suffix(input, suffixLength, &value)) return false;

    double raw = rawUnits ? value : value * LINKCAM_ANGLE_STEP_UNITS;
    if (!isfinite(raw)) return false;
    if (raw < minimum) raw = minimum;
    if (raw > maximum) raw = maximum;

    *output = LinkCamClampAngleUnits((int64_t)llround(raw), minimum, maximum);
    return true;
}

bool LinkCamParseZoom(const char *input, uint16_t *output) {
    if (!input || !output) return false;

    bool explicitMultiplier = ends_with_case_insensitive(input, "x");
    double value = 0;
    if (!parse_number_without_suffix(input, explicitMultiplier ? 1 : 0, &value)) return false;

    double raw = 0;
    if (explicitMultiplier || value <= 4.0) {
        raw = value * 100.0;
    } else if (value >= LINKCAM_ZOOM_MIN_UNITS) {
        raw = value;
    } else {
        return false;
    }

    if (!isfinite(raw)) return false;
    if (raw < LINKCAM_ZOOM_MIN_UNITS) raw = LINKCAM_ZOOM_MIN_UNITS;
    if (raw > LINKCAM_ZOOM_MAX_UNITS) raw = LINKCAM_ZOOM_MAX_UNITS;
    *output = LinkCamClampZoomUnits((int64_t)llround(raw));
    return true;
}

double LinkCamDegreesFromUnits(int32_t units) {
    return (double)units / LINKCAM_ANGLE_STEP_UNITS;
}

double LinkCamZoomMultiplierFromUnits(uint16_t units) {
    return (double)units / 100.0;
}
