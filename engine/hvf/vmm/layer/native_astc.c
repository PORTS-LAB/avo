// VK_LAYER_AVO_native_astc: a Vulkan layer between gfxstream and MoltenVK on
// the Mac (avo-vmm loads it through the Vulkan loader; astc.rs).
//
// gfxstream decompresses ASTC textures itself, into RGBA8 with compute
// shaders, whenever the driver lacks sampled, linear-filtered *linear* tiling
// for ASTC (needEmulatedAstc). Metal has no linear compressed textures, so
// MoltenVK never reports it, and every guest ASTC texture is emulated although
// the Mac's GPU samples ASTC natively. An emulated texture takes its RGBA8
// image plus all its compressed levels: about 5x the memory of ASTC 4x4, 10x
// of 6x6 and 17x of 8x8. Games size their texture streaming by those numbers
// and drop mip levels within a second (Delta Force: sharp, then blurry).
//
// This layer adds SAMPLED_IMAGE and SAMPLED_IMAGE_FILTER_LINEAR to the linear
// tiling features of ASTC LDR formats wherever optimal tiling has them, so
// gfxstream passes ASTC straight to MoltenVK. Avo's guest layer
// (guest/gfxsync) takes the two bits away again, so apps never try a linear
// ASTC image. Everything else passes straight through.
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

// The few Vulkan types the layer needs (vulkan_core.h, vk_layer.h), so it
// builds with nothing but the Mac's clang.
typedef int32_t VkResult;
typedef int32_t VkStructureType;
typedef int32_t VkFormat;
typedef uint32_t VkFlags;
typedef struct VkInstance_T* VkInstance;
typedef struct VkPhysicalDevice_T* VkPhysicalDevice;
typedef struct VkDevice_T* VkDevice;
typedef void (*PFN_vkVoidFunction)(void);
typedef PFN_vkVoidFunction (*PFN_vkGetInstanceProcAddr)(VkInstance, const char*);
typedef PFN_vkVoidFunction (*PFN_vkGetDeviceProcAddr)(VkDevice, const char*);
typedef PFN_vkVoidFunction (*PFN_GetPhysicalDeviceProcAddr)(VkInstance, const char*);

enum {
    VK_SUCCESS = 0,
    VK_ERROR_OUT_OF_HOST_MEMORY = -1,
    VK_ERROR_INITIALIZATION_FAILED = -3,
    VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO = 47,
    VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO = 48,
    VK_LAYER_LINK_INFO = 0,
    LAYER_NEGOTIATE_INTERFACE_STRUCT = 1,
    VK_FORMAT_ASTC_4x4_UNORM_BLOCK = 157,
    VK_FORMAT_ASTC_12x12_SRGB_BLOCK = 184,
    VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT = 0x1,
    VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT = 0x1000,
};

typedef struct {
    VkFlags linearTilingFeatures;
    VkFlags optimalTilingFeatures;
    VkFlags bufferFeatures;
} VkFormatProperties;

typedef struct {
    VkStructureType sType;
    void* pNext;
    VkFormatProperties formatProperties;
} VkFormatProperties2;

typedef struct VkLayerInstanceLink {
    struct VkLayerInstanceLink* pNext;
    PFN_vkGetInstanceProcAddr pfnNextGetInstanceProcAddr;
    PFN_GetPhysicalDeviceProcAddr pfnNextGetPhysicalDeviceProcAddr;
} VkLayerInstanceLink;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    int32_t function;
    union {
        VkLayerInstanceLink* pLayerInfo;
        void* other;
    } u;
} VkLayerInstanceCreateInfo;

typedef struct VkLayerDeviceLink {
    struct VkLayerDeviceLink* pNext;
    PFN_vkGetInstanceProcAddr pfnNextGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr pfnNextGetDeviceProcAddr;
} VkLayerDeviceLink;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    int32_t function;
    union {
        VkLayerDeviceLink* pLayerInfo;
        void* other;
    } u;
} VkLayerDeviceCreateInfo;

typedef struct {
    int32_t sType;
    void* pNext;
    uint32_t loaderLayerInterfaceVersion;
    PFN_vkGetInstanceProcAddr pfnGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr pfnGetDeviceProcAddr;
    PFN_GetPhysicalDeviceProcAddr pfnGetPhysicalDeviceProcAddr;
} VkNegotiateLayerInterface;

typedef struct {
    VkStructureType sType;
    const void* pNext;
} VkBaseStructure;

typedef VkResult (*PFN_vkCreateInstance)(const void*, const void*, VkInstance*);
typedef void (*PFN_vkDestroyInstance)(VkInstance, const void*);
typedef VkResult (*PFN_vkCreateDevice)(VkPhysicalDevice, const void*, const void*, VkDevice*);
typedef void (*PFN_vkDestroyDevice)(VkDevice, const void*);
typedef void (*PFN_vkGetPhysicalDeviceFormatProperties)(VkPhysicalDevice, VkFormat, VkFormatProperties*);
typedef void (*PFN_vkGetPhysicalDeviceFormatProperties2)(VkPhysicalDevice, VkFormat, VkFormatProperties2*);

#define EXPORT __attribute__((visibility("default")))

// The first word of an instance, physical device or device handle: the
// loader's dispatch table, the same for an instance and its physical devices.
static void* key_of(const void* handle) { return *(void* const*)handle; }

// MARK: Instances and devices

typedef struct Instance {
    struct Instance* next;
    void* key;
    VkInstance handle;
    PFN_vkGetInstanceProcAddr gipa;
    PFN_vkDestroyInstance destroy;
    PFN_vkGetPhysicalDeviceFormatProperties format_properties;
    PFN_vkGetPhysicalDeviceFormatProperties2 format_properties2;
    PFN_vkGetPhysicalDeviceFormatProperties2 format_properties2_khr;
} Instance;

typedef struct Device {
    struct Device* next;
    void* key;
    PFN_vkGetDeviceProcAddr gdpa;
    PFN_vkDestroyDevice destroy;
} Device;

static pthread_mutex_t lists_lock = PTHREAD_MUTEX_INITIALIZER;
static Instance* instances;
static Device* devices;

// The instance of `key`, or the newest one should a physical device's key
// ever differ from its instance's.
static Instance* find_instance(void* key) {
    pthread_mutex_lock(&lists_lock);
    Instance* found = instances;
    while (found && found->key != key) found = found->next;
    if (!found) found = instances;
    pthread_mutex_unlock(&lists_lock);
    return found;
}

static Device* find_device(void* key) {
    pthread_mutex_lock(&lists_lock);
    Device* found = devices;
    while (found && found->key != key) found = found->next;
    pthread_mutex_unlock(&lists_lock);
    return found;
}

// MARK: Format properties

static atomic_flag announced = ATOMIC_FLAG_INIT;

static void add_linear(VkFormat format, VkFormatProperties* properties) {
    const VkFlags sampled = VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT;
    if (format < VK_FORMAT_ASTC_4x4_UNORM_BLOCK || format > VK_FORMAT_ASTC_12x12_SRGB_BLOCK) return;
    if ((properties->optimalTilingFeatures & sampled) != sampled) return;
    properties->linearTilingFeatures |= sampled;
    if (!atomic_flag_test_and_set(&announced)) {
        fprintf(stderr, "[gpu] ASTC goes to Metal natively (no gfxstream decompression)\n");
    }
}

static void GetPhysicalDeviceFormatProperties(VkPhysicalDevice physical, VkFormat format, VkFormatProperties* properties) {
    Instance* instance = find_instance(key_of(physical));
    if (!instance || !instance->format_properties) return;
    instance->format_properties(physical, format, properties);
    add_linear(format, properties);
}

static void GetPhysicalDeviceFormatProperties2(VkPhysicalDevice physical, VkFormat format, VkFormatProperties2* properties) {
    Instance* instance = find_instance(key_of(physical));
    if (!instance || !instance->format_properties2) return;
    instance->format_properties2(physical, format, properties);
    add_linear(format, &properties->formatProperties);
}

static void GetPhysicalDeviceFormatProperties2KHR(VkPhysicalDevice physical, VkFormat format, VkFormatProperties2* properties) {
    Instance* instance = find_instance(key_of(physical));
    if (!instance || !instance->format_properties2_khr) return;
    instance->format_properties2_khr(physical, format, properties);
    add_linear(format, &properties->formatProperties);
}

// MARK: Chain

static VkResult CreateInstance(const VkBaseStructure* info, const void* allocator, VkInstance* out) {
    VkLayerInstanceCreateInfo* link = (VkLayerInstanceCreateInfo*)info->pNext;
    while (link && !(link->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO && link->function == VK_LAYER_LINK_INFO)) {
        link = (VkLayerInstanceCreateInfo*)link->pNext;
    }
    if (!link || !link->u.pLayerInfo) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr gipa = link->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    link->u.pLayerInfo = link->u.pLayerInfo->pNext;
    PFN_vkCreateInstance create = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
    if (!create) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult result = create(info, allocator, out);
    if (result != VK_SUCCESS) return result;

    Instance* instance = calloc(1, sizeof *instance);
    PFN_vkDestroyInstance destroy = (PFN_vkDestroyInstance)gipa(*out, "vkDestroyInstance");
    if (!instance) {
        if (destroy) destroy(*out, allocator);
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    instance->handle = *out;
    instance->key = key_of(*out);
    instance->gipa = gipa;
    instance->destroy = destroy;
    instance->format_properties = (PFN_vkGetPhysicalDeviceFormatProperties)gipa(*out, "vkGetPhysicalDeviceFormatProperties");
    instance->format_properties2 = (PFN_vkGetPhysicalDeviceFormatProperties2)gipa(*out, "vkGetPhysicalDeviceFormatProperties2");
    instance->format_properties2_khr = (PFN_vkGetPhysicalDeviceFormatProperties2)gipa(*out, "vkGetPhysicalDeviceFormatProperties2KHR");
    pthread_mutex_lock(&lists_lock);
    instance->next = instances;
    instances = instance;
    pthread_mutex_unlock(&lists_lock);
    return result;
}

static void DestroyInstance(VkInstance handle, const void* allocator) {
    if (!handle) return;
    void* key = key_of(handle);
    pthread_mutex_lock(&lists_lock);
    Instance** link = &instances;
    while (*link && (*link)->key != key) link = &(*link)->next;
    Instance* instance = *link;
    if (instance) *link = instance->next;
    pthread_mutex_unlock(&lists_lock);
    if (!instance) return;
    if (instance->destroy) instance->destroy(handle, allocator);
    free(instance);
}

static VkResult CreateDevice(VkPhysicalDevice physical, const VkBaseStructure* info, const void* allocator, VkDevice* out) {
    VkLayerDeviceCreateInfo* link = (VkLayerDeviceCreateInfo*)info->pNext;
    while (link && !(link->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO && link->function == VK_LAYER_LINK_INFO)) {
        link = (VkLayerDeviceCreateInfo*)link->pNext;
    }
    if (!link || !link->u.pLayerInfo) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr gipa = link->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr gdpa = link->u.pLayerInfo->pfnNextGetDeviceProcAddr;
    link->u.pLayerInfo = link->u.pLayerInfo->pNext;
    Instance* instance = find_instance(key_of(physical));
    PFN_vkCreateDevice create = (PFN_vkCreateDevice)gipa(instance ? instance->handle : NULL, "vkCreateDevice");
    if (!create) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult result = create(physical, info, allocator, out);
    if (result != VK_SUCCESS) return result;

    Device* device = calloc(1, sizeof *device);
    PFN_vkDestroyDevice destroy = (PFN_vkDestroyDevice)gdpa(*out, "vkDestroyDevice");
    if (!device) {
        if (destroy) destroy(*out, allocator);
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    device->key = key_of(*out);
    device->gdpa = gdpa;
    device->destroy = destroy;
    pthread_mutex_lock(&lists_lock);
    device->next = devices;
    devices = device;
    pthread_mutex_unlock(&lists_lock);
    return result;
}

static void DestroyDevice(VkDevice handle, const void* allocator) {
    if (!handle) return;
    void* key = key_of(handle);
    pthread_mutex_lock(&lists_lock);
    Device** link = &devices;
    while (*link && (*link)->key != key) link = &(*link)->next;
    Device* device = *link;
    if (device) *link = device->next;
    pthread_mutex_unlock(&lists_lock);
    if (!device) return;
    if (device->destroy) device->destroy(handle, allocator);
    free(device);
}

// MARK: Entry points

EXPORT PFN_vkVoidFunction vkGetDeviceProcAddr(VkDevice handle, const char* name) {
    if (strcmp(name, "vkGetDeviceProcAddr") == 0) return (PFN_vkVoidFunction)vkGetDeviceProcAddr;
    if (strcmp(name, "vkDestroyDevice") == 0) return (PFN_vkVoidFunction)DestroyDevice;
    Device* device = handle ? find_device(key_of(handle)) : NULL;
    return device ? device->gdpa(handle, name) : NULL;
}

EXPORT PFN_vkVoidFunction vkGetInstanceProcAddr(VkInstance handle, const char* name) {
    if (strcmp(name, "vkGetInstanceProcAddr") == 0) return (PFN_vkVoidFunction)vkGetInstanceProcAddr;
    if (strcmp(name, "vkCreateInstance") == 0) return (PFN_vkVoidFunction)CreateInstance;
    if (strcmp(name, "vkDestroyInstance") == 0) return (PFN_vkVoidFunction)DestroyInstance;
    if (strcmp(name, "vkCreateDevice") == 0) return (PFN_vkVoidFunction)CreateDevice;
    if (strcmp(name, "vkGetDeviceProcAddr") == 0) return (PFN_vkVoidFunction)vkGetDeviceProcAddr;
    if (strcmp(name, "vkDestroyDevice") == 0) return (PFN_vkVoidFunction)DestroyDevice;
    Instance* instance = handle ? find_instance(key_of(handle)) : NULL;
    if (!instance) return NULL;
    // Ours only where the driver has the function too.
    if (strcmp(name, "vkGetPhysicalDeviceFormatProperties") == 0) {
        return instance->format_properties ? (PFN_vkVoidFunction)GetPhysicalDeviceFormatProperties : NULL;
    }
    if (strcmp(name, "vkGetPhysicalDeviceFormatProperties2") == 0) {
        return instance->format_properties2 ? (PFN_vkVoidFunction)GetPhysicalDeviceFormatProperties2 : NULL;
    }
    if (strcmp(name, "vkGetPhysicalDeviceFormatProperties2KHR") == 0) {
        return instance->format_properties2_khr ? (PFN_vkVoidFunction)GetPhysicalDeviceFormatProperties2KHR : NULL;
    }
    return instance->gipa(handle, name);
}

EXPORT VkResult vkNegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface* interface) {
    if (!interface || interface->sType != LAYER_NEGOTIATE_INTERFACE_STRUCT) return VK_ERROR_INITIALIZATION_FAILED;
    if (interface->loaderLayerInterfaceVersion > 2) interface->loaderLayerInterfaceVersion = 2;
    interface->pfnGetInstanceProcAddr = vkGetInstanceProcAddr;
    interface->pfnGetDeviceProcAddr = vkGetDeviceProcAddr;
    interface->pfnGetPhysicalDeviceProcAddr = NULL;
    return VK_SUCCESS;
}
