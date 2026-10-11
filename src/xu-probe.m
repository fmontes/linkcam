//
// xu-probe.m — standalone raw UVC Extension Unit (XU) get/set probe.
//
// Reuses UVCController's device discovery + IOKit ControlRequest path
// (the same cooperative method that works while the macOS camera driver
// owns the device). Adds RAW access by unit-id + selector so we can
// read/write Insta360 vendor XU controls that uvc-util doesn't expose.
//
// Usage:
//   xu-probe -V 0x2e1a:0x4c04 units
//   xu-probe -V 0x2e1a:0x4c04 get  <unitId> <selector> <length>
//   xu-probe -V 0x2e1a:0x4c04 set  <unitId> <selector> <hexbytes>
//   xu-probe -V 0x2e1a:0x4c04 scan <unitId>            # GET_CUR sweep of selectors 1..32
//
#import <Foundation/Foundation.h>
#import "UVCController.h"

// UVC request codes
#define UVC_SET_CUR 0x01
#define UVC_GET_CUR 0x81
#define UVC_GET_MIN 0x82
#define UVC_GET_MAX 0x83
#define UVC_GET_LEN 0x85
#define UVC_GET_INFO 0x86
#define UVC_GET_DEF 0x87

// The raw request methods live in UVCController.m but aren't in the public
// header. Declare them here so we can call them.
@interface UVCController (RawXU)
- (BOOL) setData:(void*)value withLength:(int)length forSelector:(int)selector atUnitId:(int)unitId;
- (BOOL) getData:(void*)value ofType:(int)type withLength:(int)length fromSelector:(int)selector atUnitId:(int)unitId;
@end

static void hexdump(const uint8_t *b, int n) {
    for (int i = 0; i < n; i++) printf("%02x ", b[i]);
    printf("\n");
}

static int parse_hex(const char *s, uint8_t *out, int max) {
    int n = 0;
    while (*s && n < max) {
        while (*s == ' ' || *s == ',' || *s == ':') s++;
        if (!*s) break;
        unsigned v;
        if (sscanf(s, "%2x", &v) != 1) break;
        out[n++] = (uint8_t)v;
        s += 2;
    }
    return n;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        UInt16 vid = 0x2e1a, pid = 0x4c04;
        int argi = 1;
        // very small arg parse: optional -V vid:pid then subcommand
        if (argc > 2 && strcmp(argv[1], "-V") == 0) {
            unsigned a, b;
            if (sscanf(argv[2], "%x:%x", &a, &b) == 2) { vid = a; pid = b; }
            argi = 3;
        }
        if (argi >= argc) {
            fprintf(stderr, "usage: xu-probe [-V vid:pid] units|get|set|scan ...\n");
            return 2;
        }

        // Find the target device by vid/pid.
        NSArray *devs = [UVCController uvcControllers];
        UVCController *dev = nil;
        for (UVCController *d in devs) {
            if ([d vendorId] == vid && [d productId] == pid) { dev = d; break; }
        }
        if (!dev) { fprintf(stderr, "device %04x:%04x not found\n", vid, pid); return 1; }

        const char *cmd = argv[argi++];

        if (strcmp(cmd, "units") == 0) {
            printf("extension unit: %u\n", [dev extensionUnitId]);
            return [dev extensionUnitId] ? 0 : 1;
        }
        else if (strcmp(cmd, "get") == 0 && argi + 2 < argc + 1) {
            int unit = atoi(argv[argi++]);
            int sel = (int)strtol(argv[argi++], NULL, 0);
            int len = (argi < argc) ? atoi(argv[argi++]) : 8;
            uint8_t buf[256] = {0};
            BOOL ok = [dev getData:buf ofType:UVC_GET_CUR withLength:len fromSelector:sel atUnitId:unit];
            printf("GET_CUR unit=%d sel=0x%02x len=%d -> %s\n", unit, sel, len, ok ? "OK" : "FAIL");
            if (ok) hexdump(buf, len);
            return ok ? 0 : 1;
        }
        else if (strcmp(cmd, "set") == 0 && argi + 2 < argc + 1) {
            int unit = atoi(argv[argi++]);
            int sel = (int)strtol(argv[argi++], NULL, 0);
            uint8_t buf[256] = {0};
            int len = (argi < argc) ? parse_hex(argv[argi++], buf, sizeof(buf)) : 0;
            BOOL ok = [dev setData:buf withLength:len forSelector:sel atUnitId:unit];
            printf("SET_CUR unit=%d sel=0x%02x len=%d -> %s\n", unit, sel, len, ok ? "OK" : "FAIL");
            return ok ? 0 : 1;
        }
        else if (strcmp(cmd, "scan") == 0 && argi < argc) {
            int unit = atoi(argv[argi++]);
            printf("== scanning unit %d, selectors 0x01..0x20 (GET_CUR) ==\n", unit);
            for (int sel = 1; sel <= 0x20; sel++) {
                // first ask GET_LEN to learn the control size
                uint8_t lenbuf[2] = {0,0};
                int wlen = 0;
                if ([dev getData:lenbuf ofType:UVC_GET_LEN withLength:2 fromSelector:sel atUnitId:unit]) {
                    wlen = lenbuf[0] | (lenbuf[1] << 8);
                }
                if (wlen <= 0 || wlen > 256) continue;
                uint8_t buf[256] = {0};
                if ([dev getData:buf ofType:UVC_GET_CUR withLength:wlen fromSelector:sel atUnitId:unit]) {
                    printf("  sel=0x%02x len=%d cur= ", sel, wlen);
                    hexdump(buf, wlen);
                }
            }
            return 0;
        }
        fprintf(stderr, "bad args\n");
        return 2;
    }
}
