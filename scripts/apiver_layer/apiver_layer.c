/*
 * VK_LAYER_AEGNUX_apiversion
 *
 * Raises VkApplicationInfo.apiVersion to 1.3 when the application asks for
 * less (DXVK instance requests 1.0 here). Wine's winevulkan and Mesa's device
 * proc gating use the instance API version, so core 1.3 entry points such as
 * vkCmdBindVertexBuffers2 come back NULL even though dzn reports 1.3.318.
 *
 * Set VK_LAYER_AEGNUX_APIVERSION_DISABLE=1 to make the layer a pure passthrough.
 */
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>
#include <vulkan/vk_layer.h>

#ifndef VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO
#define VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO ((VkStructureType)47)
#endif

#define FORCED_API_VERSION VK_API_VERSION_1_3
#define EXPORT __attribute__((visibility("default")))
#include <stdio.h>

static PFN_vkGetInstanceProcAddr next_gipa = NULL;

static VKAPI_ATTR VkResult VKAPI_CALL
layer_CreateInstance(const VkInstanceCreateInfo *ci, const VkAllocationCallbacks *alloc, VkInstance *out)
{
    VkLayerInstanceCreateInfo *link = NULL;
    const VkBaseInStructure *p = (const VkBaseInStructure *)ci->pNext;

    for (; p; p = p->pNext) {
        if (p->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO &&
            ((const VkLayerInstanceCreateInfo *)p)->function == VK_LAYER_LINK_INFO) {
            link = (VkLayerInstanceCreateInfo *)p;
            break;
        }
    }
    if (!link || !link->u.pLayerInfo)
        return VK_ERROR_INITIALIZATION_FAILED;

    /* Resolve the next vkCreateInstance BEFORE advancing the loader link:
     * the loader's next-GIPA reads the current chain position. */
    next_gipa = link->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    PFN_vkCreateInstance next_create = (PFN_vkCreateInstance)next_gipa(NULL, "vkCreateInstance");
    link->u.pLayerInfo = link->u.pLayerInfo->pNext;
    if (!next_create)
        return VK_ERROR_INITIALIZATION_FAILED;

    VkApplicationInfo app;
    memset(&app, 0, sizeof(app));
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    if (ci->pApplicationInfo)
        app = *ci->pApplicationInfo;

    const char *dis = getenv("VK_LAYER_AEGNUX_APIVERSION_DISABLE");
    if (!(dis && dis[0] == '1') && app.apiVersion < FORCED_API_VERSION)
        app.apiVersion = FORCED_API_VERSION;

    VkInstanceCreateInfo copy = *ci;
    copy.pApplicationInfo = &app;
    return next_create(&copy, alloc, out);
}

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
layer_GetInstanceProcAddr(VkInstance instance, const char *name)
{
    if (!name)
        return NULL;
    if (!strcmp(name, "vkGetInstanceProcAddr"))
        return (PFN_vkVoidFunction)layer_GetInstanceProcAddr;
    if (!strcmp(name, "vkCreateInstance"))
        return (PFN_vkVoidFunction)layer_CreateInstance;
    if (!next_gipa)
        return NULL;
    return next_gipa(instance, name);
}

EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
vkGetInstanceProcAddr(VkInstance instance, const char *name)
{
    return layer_GetInstanceProcAddr(instance, name);
}

EXPORT VKAPI_ATTR VkResult VKAPI_CALL
vkNegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface *v)
{
    if (!v)
        return VK_ERROR_INITIALIZATION_FAILED;
    if (v->loaderLayerInterfaceVersion > 2)
        v->loaderLayerInterfaceVersion = 2;
    if (v->loaderLayerInterfaceVersion >= 2) {
        v->pfnGetInstanceProcAddr = layer_GetInstanceProcAddr; /* static, avoids interposition onto libvulkan symbol */
        v->pfnGetDeviceProcAddr = NULL;
        v->pfnGetPhysicalDeviceProcAddr = NULL;
    }
    return VK_SUCCESS;
}