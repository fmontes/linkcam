#import <Foundation/Foundation.h>

#include <locale.h>
#include <stdio.h>
#include <string.h>

#import "LinkCamCore.h"
#import "LinkCamMath.h"

#define LINKCAM_VERSION "0.2.0"

enum {
    ExitSuccess = 0,
    ExitDeviceError = 1,
    ExitUsage = 2,
    ExitControlUnavailable = 3,
    ExitReadFailure = 4,
    ExitWriteFailure = 5
};

static void printUsage(FILE *stream) {
    fprintf(stream,
        "usage:\n"
        "  linkcam                         recenter the gimbal\n"
        "  linkcam status [--json]         show current camera state\n"
        "  linkcam pan <degrees>           set pan, preserving tilt\n"
        "  linkcam tilt <degrees>          set tilt, preserving pan\n"
        "  linkcam set <pan> <tilt>        set pan and tilt\n"
        "  linkcam zoom <1x..4x>           set zoom multiplier\n"
        "  linkcam ai [on|off|toggle|status]\n"
        "  linkcam help | version\n"
        "\n"
        "Angles accept degrees by default, or raw UVC units with a 'u' suffix.\n"
        "Zoom accepts 1..4 (or an 'x' suffix), and raw values 100..400.\n");
}

static int exitCodeForResult(LinkCamResult result) {
    switch (result) {
        case LinkCamResultOK: return ExitSuccess;
        case LinkCamResultInvalidArgument: return ExitUsage;
        case LinkCamResultDeviceNotFound: return ExitDeviceError;
        case LinkCamResultControlUnavailable: return ExitControlUnavailable;
        case LinkCamResultReadFailed: return ExitReadFailure;
        case LinkCamResultWriteFailed: return ExitWriteFailure;
        case LinkCamResultTrackingDisableFailed: return ExitWriteFailure;
    }
    return ExitDeviceError;
}

static int failResult(LinkCamResult result) {
    fprintf(stderr, "linkcam: %s: %s\n", LinkCamResultCode(result), LinkCamResultDescription(result));
    return exitCodeForResult(result);
}

static const char *trackingText(int8_t tracking) {
    if (tracking == 1) return "on";
    if (tracking == 0) return "off";
    return "unknown";
}

static void printState(const LinkCamState *state, bool json) {
    double pan = LinkCamDegreesFromUnits(state->panUnits);
    double tilt = LinkCamDegreesFromUnits(state->tiltUnits);
    double zoom = LinkCamZoomMultiplierFromUnits(state->zoomUnits);

    if (json) {
        printf("{\"connected\":true,\"panDegrees\":%.1f,\"tiltDegrees\":%.1f,"
               "\"panUnits\":%d,\"tiltUnits\":%d,\"zoom\":%.2f,\"zoomUnits\":%u,\"tracking\":",
               pan, tilt, state->panUnits, state->tiltUnits, zoom, state->zoomUnits);
        if (state->tracking < 0) printf("null");
        else printf(state->tracking ? "true" : "false");
        printf(",\"trackingActive\":");
        if (state->trackingActive < 0) printf("null");
        else printf(state->trackingActive ? "true" : "false");
        printf("}\n");
        return;
    }

    printf("pan:         %.1f°\n", pan);
    printf("tilt:        %.1f°\n", tilt);
    printf("raw:         {pan=%d,tilt=%d}\n", state->panUnits, state->tiltUnits);
    printf("zoom:        %.2fx (%u)\n", zoom, state->zoomUnits);
    printf("ai tracking: %s\n", trackingText(state->tracking));
    if (state->tracking == 1) {
        printf("ai subject:  %s\n", state->trackingActive == 1 ? "tracking" : "looking");
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setlocale(LC_NUMERIC, "C");

        const char *command = argc > 1 ? argv[1] : "center";
        if (strcmp(command, "help") == 0 || strcmp(command, "--help") == 0 || strcmp(command, "-h") == 0) {
            if (argc != 2) { printUsage(stderr); return ExitUsage; }
            printUsage(stdout);
            return ExitSuccess;
        }
        if (strcmp(command, "version") == 0 || strcmp(command, "--version") == 0 || strcmp(command, "-v") == 0) {
            if (argc != 2) { printUsage(stderr); return ExitUsage; }
            printf("linkcam %s\n", LINKCAM_VERSION);
            return ExitSuccess;
        }

        bool isCenter = strcmp(command, "center") == 0;
        bool isStatus = strcmp(command, "status") == 0;
        bool isPan = strcmp(command, "pan") == 0;
        bool isTilt = strcmp(command, "tilt") == 0;
        bool isSet = strcmp(command, "set") == 0;
        bool isZoom = strcmp(command, "zoom") == 0;
        bool isAI = strcmp(command, "ai") == 0;
        if (!isCenter && !isStatus && !isPan && !isTilt && !isSet && !isZoom && !isAI) {
            fprintf(stderr, "linkcam: unknown command '%s'\n", command);
            printUsage(stderr);
            return ExitUsage;
        }

        int32_t requestedPan = 0;
        int32_t requestedTilt = 0;
        uint16_t requestedZoom = 0;
        bool json = false;

        if (isCenter && argc != 1 && argc != 2) { printUsage(stderr); return ExitUsage; }
        if (isStatus) {
            if (argc == 3 && strcmp(argv[2], "--json") == 0) json = true;
            else if (argc != 2) { printUsage(stderr); return ExitUsage; }
        }
        if (isPan) {
            if (argc != 3 || !LinkCamParseAngle(argv[2], LINKCAM_PAN_MIN_UNITS, LINKCAM_PAN_MAX_UNITS, &requestedPan)) {
                fprintf(stderr, "linkcam: invalid pan value\n");
                return ExitUsage;
            }
        }
        if (isTilt) {
            if (argc != 3 || !LinkCamParseAngle(argv[2], LINKCAM_TILT_MIN_UNITS, LINKCAM_TILT_MAX_UNITS, &requestedTilt)) {
                fprintf(stderr, "linkcam: invalid tilt value\n");
                return ExitUsage;
            }
        }
        if (isSet) {
            if (argc != 4 ||
                !LinkCamParseAngle(argv[2], LINKCAM_PAN_MIN_UNITS, LINKCAM_PAN_MAX_UNITS, &requestedPan) ||
                !LinkCamParseAngle(argv[3], LINKCAM_TILT_MIN_UNITS, LINKCAM_TILT_MAX_UNITS, &requestedTilt)) {
                fprintf(stderr, "linkcam: invalid pan/tilt value\n");
                return ExitUsage;
            }
        }
        if (isZoom) {
            if (argc != 3 || !LinkCamParseZoom(argv[2], &requestedZoom)) {
                fprintf(stderr, "linkcam: invalid zoom; use 1..4, 1x..4x, or raw units 100..400\n");
                return ExitUsage;
            }
        }
        if (isAI) {
            if (argc > 3) { printUsage(stderr); return ExitUsage; }
            if (argc == 3 && strcmp(argv[2], "on") != 0 && strcmp(argv[2], "off") != 0 &&
                strcmp(argv[2], "toggle") != 0 && strcmp(argv[2], "status") != 0) {
                fprintf(stderr, "linkcam: usage: linkcam ai [on|off|toggle|status]\n");
                return ExitUsage;
            }
        }

        LinkCamDevice *device = NULL;
        LinkCamResult result = LinkCamDeviceOpen(&device);
        if (result != LinkCamResultOK) {
            if (json) {
                printf("{\"connected\":false,\"error\":{\"code\":\"%s\",\"message\":\"%s\"}}\n",
                       LinkCamResultCode(result), LinkCamResultDescription(result));
            } else {
                failResult(result);
            }
            return exitCodeForResult(result);
        }

        int exitCode = ExitSuccess;
        LinkCamState state = {0};

        if (isCenter) {
            result = LinkCamSetPanTilt(device, 0, 0, &state);
            if (result == LinkCamResultOK) printf("✓ recentered (pan=%.1f°, tilt=%.1f°)\n",
                                                  LinkCamDegreesFromUnits(state.panUnits),
                                                  LinkCamDegreesFromUnits(state.tiltUnits));
        } else if (isStatus) {
            result = LinkCamReadState(device, &state);
            if (result == LinkCamResultOK) printState(&state, json);
            else if (json) {
                printf("{\"connected\":true,\"error\":{\"code\":\"%s\",\"message\":\"%s\"}}\n",
                       LinkCamResultCode(result), LinkCamResultDescription(result));
            }
        } else if (isPan || isTilt) {
            int32_t pan = 0, tilt = 0;
            result = LinkCamReadPanTilt(device, &pan, &tilt);
            if (result == LinkCamResultOK) {
                if (isPan) pan = requestedPan;
                else tilt = requestedTilt;
                result = LinkCamSetPanTilt(device, pan, tilt, &state);
            }
            if (result == LinkCamResultOK) printf("✓ pan=%.1f°, tilt=%.1f°\n",
                                                  LinkCamDegreesFromUnits(state.panUnits),
                                                  LinkCamDegreesFromUnits(state.tiltUnits));
        } else if (isSet) {
            result = LinkCamSetPanTilt(device, requestedPan, requestedTilt, &state);
            if (result == LinkCamResultOK) printf("✓ pan=%.1f°, tilt=%.1f°\n",
                                                  LinkCamDegreesFromUnits(state.panUnits),
                                                  LinkCamDegreesFromUnits(state.tiltUnits));
        } else if (isZoom) {
            result = LinkCamSetZoom(device, requestedZoom, &state);
            if (result == LinkCamResultOK) printf("✓ zoom=%.2fx (%u)\n",
                                                  LinkCamZoomMultiplierFromUnits(state.zoomUnits),
                                                  state.zoomUnits);
        } else if (isAI) {
            const char *action = argc == 3 ? argv[2] : "toggle";
            if (strcmp(action, "status") == 0) {
                int8_t tracking = -1;
                result = LinkCamReadTracking(device, &tracking);
                if (result == LinkCamResultOK) printf("ai tracking: %s\n", trackingText(tracking));
            } else {
                int8_t tracking = -1;
                if (strcmp(action, "on") == 0) tracking = 1;
                else if (strcmp(action, "off") == 0) tracking = 0;
                else if (strcmp(action, "toggle") == 0) {
                    result = LinkCamReadTracking(device, &tracking);
                    if (result == LinkCamResultOK) tracking = tracking ? 0 : 1;
                }
                if (result == LinkCamResultOK) result = LinkCamSetTracking(device, tracking, &state);
                if (result == LinkCamResultOK) {
                    if (tracking && state.trackingActive != 1) {
                        printf("✓ ai tracking ON (looking for a subject)\n");
                    } else {
                        printf("✓ ai tracking %s\n", tracking ? "ON" : "OFF");
                    }
                }
            }
        }

        if (result != LinkCamResultOK) {
            if (!(isStatus && json)) exitCode = failResult(result);
            else exitCode = exitCodeForResult(result);
        }
        LinkCamDeviceClose(device);
        return exitCode;
    }
}
