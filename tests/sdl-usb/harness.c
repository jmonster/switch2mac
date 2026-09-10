#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#define SDL_PLATFORM_MACOS 1
#define SDL_sscanf sscanf
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x); exit(2); } } while(0)
typedef uint8_t Uint8; typedef uint32_t Uint32; typedef int64_t Sint64;
// Fake only the platform/USB boundary; included function bodies are production.
typedef int io_registry_entry_t; typedef int kern_return_t;
#define kIOMainPortDefault 0
#define IO_OBJECT_NULL 0
#define KERN_SUCCESS 0
#define kIOServicePlane "IOService"
#define kCFAllocatorDefault 0
#define kCFNumberSInt64Type 0
#define CFSTR(x) (x)
typedef struct { int type; Sint64 value; } Number;
typedef Number *CFTypeRef; typedef Number *CFNumberRef;
static Number location = {1, 0x02000000}, address = {1, 5};
static bool missing_address, alternate_address;
static int released_entries, released_properties;
static unsigned long long IORegistryEntryIDMatching(unsigned long long id) {return id;}
static int IOServiceGetMatchingService(int port, unsigned long long id) {return id == 42 ? 3 : 0;}
static bool IOObjectConformsTo(int entry, const char *name) {return entry == 1 && strcmp(name,"IOUSBHostDevice") == 0;}
static int IORegistryEntryGetParentEntry(int entry, const char *plane, int *parent) {*parent = entry - 1; return 0;}
static void IOObjectRelease(int entry) {CHECK(entry > 0); released_entries++;}
static CFTypeRef IORegistryEntryCreateCFProperty(int entry, const char *key, int alloc, int options) {
    if (!strcmp(key,"locationID")) return &location;
    if (missing_address) return NULL;
    if (!strcmp(key,alternate_address ? "USBDeviceAddress" : "USB Address")) return &address;
    return NULL;
}
static int CFGetTypeID(CFTypeRef v) {return v->type;}
static int CFNumberGetTypeID(void) {return 1;}
static bool CFNumberGetValue(CFNumberRef n, int type, Sint64 *out) {*out=n->value;return true;}
static void CFRelease(CFTypeRef p) {CHECK(p);released_properties++;}

typedef struct {int index; Uint8 bus, address; unsigned vendor, product;} libusb_device;
typedef libusb_device libusb_device_handle;
typedef int libusb_context;
struct libusb_device_descriptor {unsigned idVendor,idProduct;};
static libusb_device devices[]={{0,2,4,0x57e,0x2073},{1,2,5,0x57e,0x2073},{2,2,6,0x57e,0x2073}};
static libusb_device *ordered[]={&devices[0],&devices[1],&devices[2]};
static int count=2, opened, claimed, exited, freed, closed, claim_result;
static int usb_init(libusb_context **c) {static int context;*c=&context;return 0;}
static void usb_exit(libusb_context *c) {exited++;}
static ssize_t usb_list(libusb_context *c, libusb_device ***out) {*out=ordered;return count;}
static void usb_free(libusb_device **list,int unref) {freed++;}
static int usb_desc(libusb_device *d,struct libusb_device_descriptor *out) {out->idVendor=d->vendor;out->idProduct=d->product;return 0;}
static Uint8 usb_bus(libusb_device *d){return d->bus;}
static Uint8 usb_address(libusb_device *d){return d->address;}
static int usb_open(libusb_device *d,libusb_device_handle **out){opened++;*out=d;return 0;}
static int usb_claim(libusb_device_handle *d,Uint8 interface){claimed++;return claim_result;}
typedef struct {
    int (*init)(libusb_context **);void (*exit)(libusb_context *);
    ssize_t (*get_device_list)(libusb_context *,libusb_device ***);
    void (*free_device_list)(libusb_device **,int);
    int (*get_device_descriptor)(libusb_device *,struct libusb_device_descriptor *);
    Uint8 (*get_bus_number)(libusb_device *);Uint8 (*get_device_address)(libusb_device *);
    int (*open)(libusb_device *,libusb_device_handle **);
    int (*claim_interface)(libusb_device_handle *,Uint8);
} API;
typedef struct {unsigned vendor_id,product_id; const char *path;} HIDDevice;
typedef struct {
    API *libusb;HIDDevice *device;libusb_device_handle *device_handle;
    libusb_context *usb_context;bool own_device_handle,interface_claimed;
    Uint8 interface_number,out_endpoint,in_endpoint;
} SDL_DriverSwitch2_Context;
static bool FindBulkEndpoints(API *api,libusb_device_handle *d,Uint8 *i,Uint8 *out,Uint8 *in){*i=1;*out=2;*in=0x82;return true;}
static void ReleaseVendorInterface(SDL_DriverSwitch2_Context *ctx){
    if(ctx->device_handle)closed++;
    if(ctx->usb_context)ctx->libusb->exit(ctx->usb_context);
    ctx->device_handle=NULL;ctx->usb_context=NULL;ctx->own_device_handle=false;ctx->interface_claimed=false;
}
#include "production.c"

int main(void) {
    API api={usb_init,usb_exit,usb_list,usb_free,usb_desc,usb_bus,usb_address,usb_open,usb_claim};
    HIDDevice hid={0x57e,0x2073,"DevSrvsID:42"};
    SDL_DriverSwitch2_Context c={.libusb=&api,.device=&hid};
    CHECK(AcquireVendorInterface(&c));
    if(c.device_handle != &devices[1]) {fputs("Wrong identical USB controller selected\n",stderr);return 42;}
    CHECK(opened==1 && claimed==1 && freed==1);
    ReleaseVendorInterface(&c);
    ordered[0]=&devices[1];ordered[1]=&devices[0];
    CHECK(AcquireVendorInterface(&c) && c.device_handle==&devices[1]);
    ReleaseVendorInterface(&c);
    // One visible wrong peer is not proof of association.
    ordered[0]=&devices[0];count=1;int old=opened;
    CHECK(!AcquireVendorInterface(&c) && opened==old && c.usb_context==NULL);
    // Duplicate address records fail closed rather than choosing either.
    ordered[0]=&devices[1];ordered[1]=&devices[2];devices[2].address=5;count=2;
    CHECK(!AcquireVendorInterface(&c) && opened==old);
    count=1;claim_result=-1;
    CHECK(!AcquireVendorInterface(&c) && c.device_handle==NULL && c.usb_context==NULL);
    CHECK(closed==3);claim_result=0;
#ifndef BASELINE
    Uint8 bus=0,addr=0;
    released_entries=released_properties=0;
    CHECK(S2USB_GetIdentity("DevSrvsID:42",&bus,&addr) && bus==2 && addr==5);
    CHECK(released_entries==3 && released_properties==2);
    CHECK(!S2USB_GetIdentity(NULL,&bus,&addr));
    CHECK(!S2USB_GetIdentity("DevSrvsID:42junk",&bus,&addr));
    CHECK(!S2USB_GetIdentity("DevSrvsID:999",&bus,&addr));
    alternate_address=true;CHECK(S2USB_GetIdentity(hid.path,&bus,&addr));
    missing_address=true;CHECK(!S2USB_GetIdentity(hid.path,&bus,&addr));missing_address=false;
    location.type=2;CHECK(!S2USB_GetIdentity(hid.path,&bus,&addr));location.type=1;
    address.value=128;CHECK(!S2USB_GetIdentity(hid.path,&bus,&addr));address.value=5;
    hid.path="DevSrvsID:999";old=opened;CHECK(!AcquireVendorInterface(&c) && opened==old);
#endif
    puts("USB identity, reversed enumeration, ambiguity and cleanup regressions passed.");
    return 0;
}
