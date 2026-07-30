#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>
#include <stdbool.h>

// ---------------------------------------------------------------------------
// IOAVService  --  DDC/CI over I2C on Apple Silicon
// ---------------------------------------------------------------------------
//
// These are exported by /System/Library/Frameworks/IOKit.framework and are
// present in the SDK's IOKit.tbd, so they link normally with -framework IOKit.
// No dlopen, no entitlement, no root. They are simply undeclared.
//
// IMPORTANT: the typedef MUST be named `IOAVService`, not `IOAVServiceRef`.
// Swift's CoreFoundation importer applies the Swift 3 "Ref"-stripping rule and
// hard-errors with "'IOAVServiceRef' was obsoleted in Swift 3" otherwise.
typedef CFTypeRef IOAVService;

/// Returns an arbitrary external AV service. Useless with >1 display; we always
/// use IOAVServiceCreateWithService against a specific DCPAVServiceProxy.
extern IOAVService IOAVServiceCreate(CFAllocatorRef allocator);

/// Create Rule (+1). clang's CF heuristic sees the `Create` prefix, so Swift
/// imports this as `Unmanaged<IOAVService>!` -- call .takeRetainedValue().
extern IOAVService IOAVServiceCreateWithService(CFAllocatorRef allocator,
                                               io_service_t service);

/// chipAddress is the 7-bit DDC/CI slave address (0x37). `offset` is ignored by
/// the DCP for DDC reads; pass 0.
extern IOReturn IOAVServiceReadI2C(IOAVService service,
                                   uint32_t chipAddress,
                                   uint32_t offset,
                                   void *outputBuffer,
                                   uint32_t outputBufferSize);

/// chipAddress = 0x37, dataAddress = 0x51 (DDC/CI host sub-address).
/// A return of kIOReturnSuccess means the DCP accepted the transaction -- NOT
/// that the monitor honoured it.
extern IOReturn IOAVServiceWriteI2C(IOAVService service,
                                    uint32_t chipAddress,
                                    uint32_t dataAddress,
                                    void *inputBuffer,
                                    uint32_t inputBufferSize);

// ---------------------------------------------------------------------------
// CoreDisplay  --  display metadata
// ---------------------------------------------------------------------------
//
// Private symbol in a *public* framework, present in CoreDisplay.tbd.
// Create Rule (+1) -> Swift imports as Unmanaged.
//
// Useful keys: "IODisplayLocation" (the framebuffer's IOService path, which is
// the authoritative way to pair a CGDirectDisplayID with a DCPAVServiceProxy),
// "kCGDisplayUUID", "DisplayProductName", "kCGDisplayIsVirtualDevice",
// "kCGDisplayIsAirPlay".
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display);

// NOTE: CGSIsHDRSupported / CGSIsHDREnabled are deliberately *not* declared
// here. Swift does not model `__attribute__((weak_import))`, so a weak
// declaration still imports as a non-optional function and cannot be nil-checked
// -- which defeats the point. They are resolved with dlsym in
// CoreGraphicsSPI.swift instead.
