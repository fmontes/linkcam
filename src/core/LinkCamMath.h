#ifndef LINK_CAM_MATH_H
#define LINK_CAM_MATH_H

#include <stdbool.h>
#include <stdint.h>

enum {
    LINKCAM_ANGLE_STEP_UNITS = 3600,
    LINKCAM_PAN_MIN_UNITS = -522000,
    LINKCAM_PAN_MAX_UNITS = 522000,
    LINKCAM_TILT_MIN_UNITS = -324000,
    LINKCAM_TILT_MAX_UNITS = 360000,
    LINKCAM_ZOOM_MIN_UNITS = 100,
    LINKCAM_ZOOM_MAX_UNITS = 400
};

bool LinkCamParseAngle(const char *input, int32_t minimum, int32_t maximum, int32_t *output);
bool LinkCamParseZoom(const char *input, uint16_t *output);
int32_t LinkCamClampAngleUnits(int64_t value, int32_t minimum, int32_t maximum);
uint16_t LinkCamClampZoomUnits(int64_t value);
double LinkCamDegreesFromUnits(int32_t units);
double LinkCamZoomMultiplierFromUnits(uint16_t units);

#endif
