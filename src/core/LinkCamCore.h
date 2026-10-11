#ifndef LINK_CAM_CORE_H
#define LINK_CAM_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LinkCamDevice LinkCamDevice;

typedef enum {
    LinkCamResultOK = 0,
    LinkCamResultInvalidArgument = 1,
    LinkCamResultDeviceNotFound = 2,
    LinkCamResultControlUnavailable = 3,
    LinkCamResultReadFailed = 4,
    LinkCamResultWriteFailed = 5,
    LinkCamResultTrackingDisableFailed = 6
} LinkCamResult;

typedef struct {
    int32_t panUnits;
    int32_t tiltUnits;
    uint16_t zoomUnits;
    int8_t tracking; /* 0 = off, 1 = on, -1 = unavailable */
    int8_t trackingActive; /* subject acquired: 0 = no, 1 = yes, -1 = unavailable */
    int8_t videoMode; /* 0 = normal, 4 = whiteboard, 6 = DeskView, -1 = unavailable */
} LinkCamState;

LinkCamResult LinkCamDeviceOpen(LinkCamDevice **output);
void LinkCamDeviceClose(LinkCamDevice *device);

LinkCamResult LinkCamReadState(LinkCamDevice *device, LinkCamState *output);
LinkCamResult LinkCamReadPanTilt(LinkCamDevice *device, int32_t *panUnits, int32_t *tiltUnits);
LinkCamResult LinkCamReadZoom(LinkCamDevice *device, uint16_t *zoomUnits);
LinkCamResult LinkCamReadTracking(LinkCamDevice *device, int8_t *tracking);
LinkCamResult LinkCamEnsureTrackingSubject(LinkCamDevice *device, int8_t *active);

LinkCamResult LinkCamSetPanTilt(LinkCamDevice *device, int32_t panUnits, int32_t tiltUnits, LinkCamState *readback);
LinkCamResult LinkCamSetZoom(LinkCamDevice *device, uint16_t zoomUnits, LinkCamState *readback);
LinkCamResult LinkCamSetTracking(LinkCamDevice *device, int8_t tracking, LinkCamState *readback);
LinkCamResult LinkCamSetVideoMode(LinkCamDevice *device, int8_t videoMode, LinkCamState *readback);

const char *LinkCamResultCode(LinkCamResult result);
const char *LinkCamResultDescription(LinkCamResult result);

#ifdef __cplusplus
}
#endif

#endif
