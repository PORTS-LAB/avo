// Shared by Avo's GLES and Vulkan layers: where the device profile's GPU
// comes from, and who sees it.
//
// The engine writes the profile's GPU into debug.avo.gl.* and debug.avo.vk.*
// at boot (DeviceProfile.bootProperties in AvoKit). Every process may read
// debug_prop, and the shell may set it, so a developer can try another name
// with `setprop` and a restart of the app.
#pragma once

#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/system_properties.h>
#include <unistd.h>

#define AVO_EXPORT __attribute__((visibility("default")))

#ifndef AVO_LOG
#define AVO_LOG(...) ((void)0)
#endif

// `value` is empty when the property is not set.
static inline void avo_prop(const char* name, char value[PROP_VALUE_MAX]) {
    value[0] = '\0';
    __system_property_get(name, value);
}

// 0x5143 or 20803; false when unset or not a number.
static inline bool avo_prop_u32(const char* name, uint32_t* out) {
    char value[PROP_VALUE_MAX];
    avo_prop(name, value);
    if (!value[0]) return false;
    char* end = NULL;
    unsigned long parsed = strtoul(value, &end, 0);
    if (*end != '\0' || parsed > UINT32_MAX) return false;
    *out = (uint32_t)parsed;
    return true;
}

// Apps only: uid 10000 and up in each Android user. System processes
// (SurfaceFlinger's RenderEngine, system_server) keep the real GPU.
static inline bool avo_app_process(void) {
    return getuid() % 100000 >= 10000;
}

// The framework's own renderers inside an app: HWUI and WebView (Chromium).
// Skia and Chromium pick driver workarounds from the GPU's name, and the
// phone's workarounds are wrong for what really draws (ANGLE on the Mac's
// GPU), so they keep the real name.
//
// They are told by the code that calls, not by the thread's name: HWUI's
// thread is "RenderThread", but so is Unreal Engine's, whose renderer must
// see the profile like any app's, and WebView's GPU thread may be
// "Chrome_InProcGpuThread" as well as "CrGpuMain". The layers look for HWUI
// or WebView on the caller's stack. Only HWUI's helpers (hwuiTask*) and
// CrGpuMain still go by name, and "RenderThread" too when the stack can't be
// read.

// The libraries a call passes through to reach a layer: libEGL, libGLES*
// (libGLESv2 and the like, this GLES layer), libvulkan and Vulkan layers.
static inline bool avo_loader_library(const char* name) {
    return strncmp(name, "libEGL", 6) == 0 || strncmp(name, "libGLES", 7) == 0 || strcmp(name, "libvulkan.so") == 0
        || strncmp(name, "libVkLayer", 10) == 0;
}

// HWUI, and WebView's Chromium: libwebviewchromium.so in AOSP's WebView,
// libmonochrome*.so or libchrome*.so in Google's, which may load it from the
// Trichrome library's APK.
static inline bool avo_framework_library(const char* path, const char* name) {
    return strcmp(name, "libhwui.so") == 0 || strcmp(name, "libwebviewchromium.so") == 0
        || strncmp(name, "libmonochrome", 13) == 0 || strncmp(name, "libchrome", 9) == 0
        || strstr(path, "com.google.android.webview") || strstr(path, "com.android.webview") || strstr(path, "trichrome");
}

enum { AVO_STACK_FRAMES = 32 };
typedef enum { AVO_CALLER_UNKNOWN, AVO_CALLER_APP, AVO_CALLER_FRAMEWORK } AvoCaller;
typedef struct {
    int frames;
    AvoCaller caller;
    const char* library;  // the one that decided
    const char* last;     // the last one the walk reached
} AvoStack;

// Notes the library of a return address; true once it is the framework's.
// The call is just before the address, in the caller's library. Code outside
// any library (JIT) proves nothing either way.
static inline bool avo_stack_frame(AvoStack* stack, uintptr_t pc) {
    Dl_info info;
    if (!pc || !dladdr((void*)(pc - 1), &info) || !info.dli_fname) return false;
    const char* slash = strrchr(info.dli_fname, '/');
    const char* name = slash ? slash + 1 : info.dli_fname;
    stack->last = name;
    if (avo_framework_library(info.dli_fname, name)) {
        stack->caller = AVO_CALLER_FRAMEWORK;
        stack->library = name;
        return true;
    }
    if (stack->caller == AVO_CALLER_UNKNOWN && !avo_loader_library(name)) {
        stack->caller = AVO_CALLER_APP;
        stack->library = name;
    }
    return false;
}

// This thread's stack, [low, high): the walk reads nothing outside it.
static inline bool avo_stack_bounds(uintptr_t* low, uintptr_t* high) {
    static _Thread_local uintptr_t stack_low, stack_high;
    if (!stack_high) {
        pthread_attr_t attr;
        void* base = NULL;
        size_t size = 0;
        if (pthread_getattr_np(pthread_self(), &attr) != 0) return false;
        int failed = pthread_attr_getstack(&attr, &base, &size);
        pthread_attr_destroy(&attr);
        if (failed || !base || size < 16) return false;
        stack_low = (uintptr_t)base;
        stack_high = stack_low + size;
    }
    *low = stack_low;
    *high = stack_high;
    return true;
}

// A return address as code: without its pointer authentication code
// (XPACLRI, a no-op on CPUs without one) and above the 48-bit user range.
static inline uintptr_t avo_code_address(uintptr_t address) {
    register uintptr_t lr __asm__("x30") = address;
    __asm__("hint #7" : "+r"(lr));
    return lr & ((UINT64_C(1) << 48) - 1);
}

// The framework when HWUI or WebView is in the caller's first frames, the app
// when other code is, unknown when the walk found nothing past the loaders.
//
// It follows the AArch64 frame records (x29 points at the caller's x29 and
// the return address), which every NDK and platform build keeps, so nothing
// of the caller's libraries is parsed: a game may ship its unwind tables
// encrypted. A record is read only when it is 16-byte aligned, inside this
// thread's stack and above the one before; anything else ends the walk, such
// as a frame without a record or code that uses x29 for something else.
static inline __attribute__((noinline)) AvoStack avo_stack_caller(void) {
    AvoStack stack = {0, AVO_CALLER_UNKNOWN, NULL, NULL};
    uintptr_t low, high;
    if (!avo_stack_bounds(&low, &high)) return stack;
    uintptr_t fp = (uintptr_t)__builtin_frame_address(0);
    uintptr_t pc = (uintptr_t)__builtin_return_address(0);
    while (stack.frames < AVO_STACK_FRAMES && !avo_stack_frame(&stack, avo_code_address(pc))) {
        stack.frames++;
        if (fp % 16 || fp < low || fp > high - 16) break;
        uintptr_t next = ((const uintptr_t*)fp)[0];
        if (next <= fp || next % 16 || next > high - 16) break;
        pc = ((const uintptr_t*)next)[1];
        fp = next;
    }
    return stack;
}

// Whether the framework's renderers made the current GL or Vulkan call. A
// thread runs either the framework's renderers or an app's, so its stack is
// read once, on its first call (0.1 to 2 ms).
static inline bool avo_framework_call(void) {
    char name[16] = {0};
    prctl(PR_GET_NAME, name, 0, 0, 0);
    if (strncmp(name, "hwuiTask", 8) == 0 || strncmp(name, "CrGpuMain", 9) == 0) return true;
    static _Thread_local AvoCaller caller;
    if (caller == AVO_CALLER_UNKNOWN) {
        AvoStack stack = avo_stack_caller();
        caller = stack.caller;
        AVO_LOG("%s: caller %s (%s, %d frames, last %s)", name,
                caller == AVO_CALLER_FRAMEWORK ? "framework" : caller == AVO_CALLER_APP ? "app" : "unknown",
                stack.library ? stack.library : "-", stack.frames, stack.last ? stack.last : "-");
    }
    if (caller != AVO_CALLER_UNKNOWN) return caller == AVO_CALLER_FRAMEWORK;
    return strcmp(name, "RenderThread") == 0;
}
