// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NuxFX contributors
// Regression check for patch 21: a timeline semaphore that one VkDevice exports as an opaque fd
// can be imported by another VkDevice and carries CPU signals, GPU signals and queue waits across.
// WSL's Direct3D 12 cannot open a shared fence, so dzn keeps the value in a memfd page.
// Build and run with tests/run_semaphore_share_test.sh. Exit codes: 0 pass, 1 fail, 77 skip.
#include <vulkan/vulkan.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int failures;

#define CHECK(cond, ...)                                           \
    do {                                                           \
        if (cond) {                                                \
            printf("ok    ");                                      \
        } else {                                                   \
            printf("FAIL  ");                                      \
            failures++;                                            \
        }                                                          \
        printf(__VA_ARGS__);                                       \
        printf("\n");                                              \
        fflush(stdout);                                            \
    } while (0)

static VkDevice make_device(VkPhysicalDevice pd) {
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qi = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    qi.queueFamilyIndex = 0;
    qi.queueCount = 1;
    qi.pQueuePriorities = &prio;
    VkPhysicalDeviceVulkan12Features f12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES};
    f12.timelineSemaphore = VK_TRUE;
    const char *ext[] = {"VK_KHR_external_semaphore", "VK_KHR_external_semaphore_fd"};
    VkDeviceCreateInfo di = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f12};
    di.queueCreateInfoCount = 1;
    di.pQueueCreateInfos = &qi;
    di.enabledExtensionCount = 2;
    di.ppEnabledExtensionNames = ext;
    VkDevice dev = VK_NULL_HANDLE;
    if (vkCreateDevice(pd, &di, NULL, &dev) != VK_SUCCESS)
        return VK_NULL_HANDLE;
    return dev;
}

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static uint64_t counter(VkDevice dev, VkSemaphore s) {
    uint64_t v = ~0ull;
    vkGetSemaphoreCounterValue(dev, s, &v);
    return v;
}

static VkResult wait_for(VkDevice dev, VkSemaphore s, uint64_t value, uint64_t timeout_ms) {
    VkSemaphoreWaitInfo wi = {VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO};
    wi.semaphoreCount = 1;
    wi.pSemaphores = &s;
    wi.pValues = &value;
    return vkWaitSemaphores(dev, &wi, timeout_ms * 1000000ull);
}

static void signal_cpu(VkDevice dev, VkSemaphore s, uint64_t value) {
    VkSemaphoreSignalInfo si = {VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO};
    si.semaphore = s;
    si.value = value;
    vkSignalSemaphore(dev, &si);
}

// An empty queue submission that waits for wait_value (0 = no wait) and signals signal_value (0 = none).
static VkResult submit(VkDevice dev, VkSemaphore s, uint64_t wait_value, uint64_t signal_value) {
    VkQueue q;
    vkGetDeviceQueue(dev, 0, 0, &q);
    VkTimelineSemaphoreSubmitInfo ti = {VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO};
    ti.waitSemaphoreValueCount = wait_value ? 1 : 0;
    ti.pWaitSemaphoreValues = &wait_value;
    ti.signalSemaphoreValueCount = signal_value ? 1 : 0;
    ti.pSignalSemaphoreValues = &signal_value;
    VkPipelineStageFlags stage = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, &ti};
    si.waitSemaphoreCount = wait_value ? 1 : 0;
    si.pWaitSemaphores = &s;
    si.pWaitDstStageMask = &stage;
    si.signalSemaphoreCount = signal_value ? 1 : 0;
    si.pSignalSemaphores = &s;
    return vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE);
}

struct delayed {
    VkDevice dev;
    VkSemaphore sem;
    uint64_t value;
    unsigned ms;
};

static void *delayed_signal(void *arg) {
    struct delayed *d = arg;
    usleep(d->ms * 1000);
    signal_cpu(d->dev, d->sem, d->value);
    return NULL;
}

int main(void) {
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.apiVersion = VK_API_VERSION_1_3;
    VkInstanceCreateInfo ii = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ii.pApplicationInfo = &app;
    VkInstance inst;
    if (vkCreateInstance(&ii, NULL, &inst) != VK_SUCCESS) {
        printf("SKIP: no Vulkan instance\n");
        return 77;
    }
    uint32_t n = 1;
    VkPhysicalDevice pd;
    vkEnumeratePhysicalDevices(inst, &n, &pd);
    if (n == 0) {
        printf("SKIP: no Vulkan device\n");
        return 77;
    }
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(pd, &props);
    printf("device: %s\n", props.deviceName);

    VkSemaphoreTypeCreateInfo tinfo = {VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO};
    tinfo.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE;
    VkPhysicalDeviceExternalSemaphoreInfo ei = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_SEMAPHORE_INFO, &tinfo};
    ei.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT;
    VkExternalSemaphoreProperties ep = {VK_STRUCTURE_TYPE_EXTERNAL_SEMAPHORE_PROPERTIES};
    vkGetPhysicalDeviceExternalSemaphoreProperties(pd, &ei, &ep);
    const VkExternalSemaphoreFeatureFlags need =
        VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT | VK_EXTERNAL_SEMAPHORE_FEATURE_IMPORTABLE_BIT;
    if ((ep.externalSemaphoreFeatures & need) != need) {
        printf("SKIP: the device cannot export and import opaque fd timeline semaphores (features 0x%x)\n",
               ep.externalSemaphoreFeatures);
        return 77;
    }

    VkDevice a = make_device(pd), b = make_device(pd);
    if (!a || !b) {
        printf("SKIP: cannot create two devices with VK_KHR_external_semaphore_fd\n");
        return 77;
    }
    PFN_vkGetSemaphoreFdKHR get_fd = (PFN_vkGetSemaphoreFdKHR)vkGetDeviceProcAddr(a, "vkGetSemaphoreFdKHR");
    PFN_vkGetSemaphoreFdKHR get_fd_b = (PFN_vkGetSemaphoreFdKHR)vkGetDeviceProcAddr(b, "vkGetSemaphoreFdKHR");
    PFN_vkImportSemaphoreFdKHR import_a = (PFN_vkImportSemaphoreFdKHR)vkGetDeviceProcAddr(a, "vkImportSemaphoreFdKHR");
    PFN_vkImportSemaphoreFdKHR import_b = (PFN_vkImportSemaphoreFdKHR)vkGetDeviceProcAddr(b, "vkImportSemaphoreFdKHR");

    VkExportSemaphoreCreateInfo xi = {VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO, &tinfo};
    xi.handleTypes = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT;
    VkSemaphoreCreateInfo si = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, &xi};
    VkSemaphore sa, sb;
    VkResult r = vkCreateSemaphore(a, &si, NULL, &sa);
    CHECK(r == VK_SUCCESS, "device A creates an exportable timeline semaphore (%d)", (int)r);
    signal_cpu(a, sa, 3);

    VkSemaphoreGetFdInfoKHR gi = {VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR};
    gi.semaphore = sa;
    gi.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT;
    int fd = -1;
    r = get_fd(a, &gi, &fd);
    CHECK(r == VK_SUCCESS && fd >= 0, "device A exports it as an opaque fd (%d, fd %d)", (int)r, fd);

    VkSemaphoreCreateInfo plain = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, &tinfo};
    r = vkCreateSemaphore(b, &plain, NULL, &sb);
    CHECK(r == VK_SUCCESS, "device B creates a timeline semaphore (%d)", (int)r);
    VkImportSemaphoreFdInfoKHR im = {VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR};
    im.semaphore = sb;
    im.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT;
    im.fd = dup(fd);
    r = import_b(b, &im);
    CHECK(r == VK_SUCCESS, "device B imports a duplicate of the fd (%d)", (int)r);
    if (r != VK_SUCCESS) {
        printf("RESULT fail (the import is refused: the driver cannot share the semaphore)\n");
        return 1;
    }

    CHECK(counter(b, sb) == 3, "B reads the value A had signalled before the import (%llu)", (unsigned long long)counter(b, sb));
    signal_cpu(a, sa, 7);
    CHECK(counter(b, sb) == 7, "B reads A's later CPU signal (%llu)", (unsigned long long)counter(b, sb));
    signal_cpu(b, sb, 9);
    CHECK(counter(a, sa) == 9, "A reads B's CPU signal (%llu)", (unsigned long long)counter(a, sa));
    CHECK(wait_for(b, sb, 9, 1000) == VK_SUCCESS, "B waits for 9 on the CPU");
    CHECK(wait_for(a, sa, 12, 100) == VK_TIMEOUT, "a wait for a value that nobody signalled times out");

    // A GPU signal on the queue of A has to reach B although nobody on A asks for the value.
    r = submit(a, sa, 0, 11);
    CHECK(r == VK_SUCCESS, "A submits a queue signal of 11 (%d)", (int)r);
    uint64_t t0 = now_ms();
    VkResult w = wait_for(b, sb, 11, 3000);
    CHECK(w == VK_SUCCESS, "B sees the queue signal on the CPU (%d, %llu ms)", (int)w, (unsigned long long)(now_ms() - t0));

    // A queue wait on B for a value that A signals on the CPU 300 ms later; B then signals 14 itself.
    struct delayed d = {a, sa, 13, 300};
    pthread_t thread;
    pthread_create(&thread, NULL, delayed_signal, &d);
    t0 = now_ms();
    r = submit(b, sb, 13, 14);
    uint64_t submitted = now_ms() - t0;
    w = wait_for(a, sa, 14, 3000);
    uint64_t total = now_ms() - t0;
    pthread_join(thread, NULL);
    CHECK(r == VK_SUCCESS, "B submits a queue wait for 13 (%d, returned after %llu ms)", (int)r, (unsigned long long)submitted);
    CHECK(w == VK_SUCCESS && total >= 250, "A sees B's queue signal of 14 only after A's signal of 13 (%d, %llu ms)", (int)w, (unsigned long long)total);

    // A second import and an export of an imported semaphore.
    VkSemaphore sa2;
    vkCreateSemaphore(a, &plain, NULL, &sa2);
    im.semaphore = sa2;
    im.fd = dup(fd);
    r = import_a(a, &im);
    CHECK(r == VK_SUCCESS, "device A imports the fd into a second semaphore (%d)", (int)r);
    CHECK(counter(a, sa2) >= 14, "the second semaphore starts at the shared value (%llu)", (unsigned long long)counter(a, sa2));
    VkSemaphoreGetFdInfoKHR gb = {VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR};
    gb.semaphore = sb;
    gb.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT;
    int fd2 = -1;
    r = get_fd_b(b, &gb, &fd2);
    CHECK(r == VK_SUCCESS && fd2 >= 0, "an imported semaphore can be exported again (%d)", (int)r);

    // A semaphore is destroyed after an import: no double release.
    vkDestroySemaphore(b, sb, NULL);
    vkDestroySemaphore(a, sa2, NULL);
    vkDestroySemaphore(a, sa, NULL);
    CHECK(1, "the semaphores are destroyed");

    if (failures) {
        printf("RESULT fail (%d)\n", failures);
        return 1;
    }
    printf("RESULT pass\n");
    return 0;
}
