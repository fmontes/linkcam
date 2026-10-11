#include "LinkCamMath.h"

#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>

static void testAngles(void) {
    int32_t value = 0;
    assert(LinkCamParseAngle("30", LINKCAM_PAN_MIN_UNITS, LINKCAM_PAN_MAX_UNITS, &value));
    assert(value == 108000);
    assert(LinkCamParseAngle("-12.5deg", LINKCAM_PAN_MIN_UNITS, LINKCAM_PAN_MAX_UNITS, &value));
    assert(value == -46800);
    assert(LinkCamParseAngle("108000u", LINKCAM_PAN_MIN_UNITS, LINKCAM_PAN_MAX_UNITS, &value));
    assert(value == 108000);
    assert(LinkCamParseAngle("0.5", LINKCAM_PAN_MIN_UNITS, LINKCAM_PAN_MAX_UNITS, &value));
    assert(value == 3600);
    assert(LinkCamParseAngle("-0.5", LINKCAM_PAN_MIN_UNITS, LINKCAM_PAN_MAX_UNITS, &value));
    assert(value == -3600);
    assert(LinkCamParseAngle("999", LINKCAM_PAN_MIN_UNITS, LINKCAM_PAN_MAX_UNITS, &value));
    assert(value == LINKCAM_PAN_MAX_UNITS);
    assert(!LinkCamParseAngle("12oops", LINKCAM_PAN_MIN_UNITS, LINKCAM_PAN_MAX_UNITS, &value));
    assert(!LinkCamParseAngle("nan", LINKCAM_PAN_MIN_UNITS, LINKCAM_PAN_MAX_UNITS, &value));
    assert(!LinkCamParseAngle("", LINKCAM_PAN_MIN_UNITS, LINKCAM_PAN_MAX_UNITS, &value));
}

static void testZoom(void) {
    uint16_t value = 0;
    assert(LinkCamParseZoom("1.5", &value) && value == 150);
    assert(LinkCamParseZoom("1.5x", &value) && value == 150);
    assert(LinkCamParseZoom("150", &value) && value == 150);
    assert(LinkCamParseZoom("0.5x", &value) && value == LINKCAM_ZOOM_MIN_UNITS);
    assert(LinkCamParseZoom("5x", &value) && value == LINKCAM_ZOOM_MAX_UNITS);
    assert(LinkCamParseZoom("500", &value) && value == LINKCAM_ZOOM_MAX_UNITS);
    assert(!LinkCamParseZoom("50", &value));
    assert(!LinkCamParseZoom("1.5oops", &value));
    assert(!LinkCamParseZoom("inf", &value));
}

static void testConversions(void) {
    assert(fabs(LinkCamDegreesFromUnits(108000) - 30.0) < 0.0001);
    assert(fabs(LinkCamZoomMultiplierFromUnits(175) - 1.75) < 0.0001);
    assert(LinkCamClampAngleUnits(1000, LINKCAM_PAN_MIN_UNITS, LINKCAM_PAN_MAX_UNITS) == 0);
    assert(LinkCamClampZoomUnits(50) == LINKCAM_ZOOM_MIN_UNITS);
}

int main(void) {
    testAngles();
    testZoom();
    testConversions();
    puts("LinkCamMath tests passed");
    return 0;
}
