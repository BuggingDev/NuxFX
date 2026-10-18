/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 NuxFX contributors */
/* dzn_audit: check that every advertised device command resolves to a function.
 *
 * usage: dzn_audit AUDIT_LIST     (AUDIT_LIST lines: "EXTENSION vkCommandName")
 *
 * Reports:
 *   NULL    the loader returned no pointer for an advertised command
 *   SHARED  several non-alias commands resolve to the same pointer. That is how
 *           the runtime's no-op stub shows up. Aliases (vkCmdFoo and
 *           vkCmdFooKHR, vkCmdFoo2 and vkCmdFoo2KHR) are not reported.
 * LIMITATION: a single unimplemented command that resolves to the stub is not
 * detected by this check.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

static int in_list(const char *n, const char **list, uint32_t cnt) {
    for (uint32_t i = 0; i < cnt; i++)
        if (!strcmp(n, list[i]))
            return 1;
    return 0;
}

/* Strip vendor and KHR/EXT suffixes so that aliases compare equal. */
static void base_name(const char *in, char *out, size_t size) {
    static const char *suffixes[] = {
        "KHR", "EXT", "NV", "AMD", "QCOM", "ARM", "INTEL", "NVX", "MSFT", "VALVE",
        "GOOGLE", "HUAWEI", "QNX", "FUCHSIA", "ANDROID", "OHOS", "MVK", "2",
    };
    strncpy(out, in, size - 1);
    out[size - 1] = 0;
    int stripped = 1;
    while (stripped) {
        stripped = 0;
        for (size_t i = 0; i < sizeof(suffixes) / sizeof(suffixes[0]); i++) {
            size_t sl = strlen(suffixes[i]);
            size_t l = strlen(out);
            if (l > sl && !strcmp(out + l - sl, suffixes[i])) {
                out[l - sl] = 0;
                stripped = 1;
            }
        }
    }
}

#define MAX_CMDS 4096
static char names_seen[MAX_CMDS][256];
static void *ptrs_seen[MAX_CMDS];
static int ncmds;

int main(int argc, char **argv) {
    if (argc < 2) {
        printf("usage: %s AUDIT_LIST\n", argv[0]);
        return 1;
    }
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                              .pApplicationName = "dzn_audit", .apiVersion = VK_API_VERSION_1_3 };
    VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    VkInstance inst;
    VkResult r = vkCreateInstance(&ici, NULL, &inst);
    if (r) {
        printf("vkCreateInstance failed %d\n", r);
        return 1;
    }
    uint32_t n = 0;
    vkEnumeratePhysicalDevices(inst, &n, NULL);
    if (!n) {
        printf("no physical devices\n");
        return 1;
    }
    VkPhysicalDevice *pd = malloc(sizeof(*pd) * n);
    vkEnumeratePhysicalDevices(inst, &n, pd);
    VkPhysicalDevice phys = pd[0];
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(phys, &props);
    printf("device: %s apiVersion %u.%u.%u\n", props.deviceName,
           VK_VERSION_MAJOR(props.apiVersion), VK_VERSION_MINOR(props.apiVersion),
           VK_VERSION_PATCH(props.apiVersion));

    uint32_t ec = 0;
    vkEnumerateDeviceExtensionProperties(phys, NULL, &ec, NULL);
    VkExtensionProperties *ep = malloc(sizeof(*ep) * ec);
    vkEnumerateDeviceExtensionProperties(phys, NULL, &ec, ep);
    const char **names = malloc(sizeof(char *) * ec);
    uint32_t enabled = 0;
    for (uint32_t i = 0; i < ec; i++) {
        if (strstr(ep[i].extensionName, "win32"))
            continue;
        names[enabled++] = ep[i].extensionName;
    }
    uint32_t qc = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &qc, NULL);
    VkQueueFamilyProperties *qp = malloc(sizeof(*qp) * qc);
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &qc, qp);
    uint32_t qi = 0;
    for (; qi < qc; qi++)
        if (qp[qi].queueFlags & VK_QUEUE_GRAPHICS_BIT)
            break;
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                    .queueFamilyIndex = qi, .queueCount = 1, .pQueuePriorities = &prio };
    VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1,
                               .pQueueCreateInfos = &qci, .enabledExtensionCount = enabled,
                               .ppEnabledExtensionNames = names };
    VkDevice dev;
    r = vkCreateDevice(phys, &dci, NULL, &dev);
    printf("vkCreateDevice with %u extensions -> %d\n", enabled, r);
    if (r)
        return 2;

    FILE *f = fopen(argv[1], "r");
    if (!f) {
        printf("cannot open %s\n", argv[1]);
        return 3;
    }
    char ext[256], cmd[256];
    int total = 0, missing = 0;
    while (fscanf(f, "%255s %255s", ext, cmd) == 2) {
        if (strncmp(ext, "CORE_", 5) && !in_list(ext, names, enabled))
            continue;
        total++;
        PFN_vkVoidFunction fn = vkGetDeviceProcAddr(dev, cmd);
        if (!fn) {
            printf("NULL %s %s\n", ext, cmd);
            missing++;
            continue;
        }
        if (ncmds < MAX_CMDS) {
            strncpy(names_seen[ncmds], cmd, 255);
            ptrs_seen[ncmds] = (void *)fn;
            ncmds++;
        }
    }
    fclose(f);

    int shared = 0;
    for (int i = 0; i < ncmds; i++) {
        if (!ptrs_seen[i])
            continue;
        char bi[256];
        base_name(names_seen[i], bi, sizeof(bi));
        int group = 0;
        for (int j = i + 1; j < ncmds; j++) {
            if (ptrs_seen[j] != ptrs_seen[i])
                continue;
            char bj[256];
            base_name(names_seen[j], bj, sizeof(bj));
            if (strcmp(bi, bj)) {
                if (!group) {
                    printf("SHARED %p: %s", ptrs_seen[i], names_seen[i]);
                    group = 1;
                    shared++;
                }
                printf(" %s", names_seen[j]);
                ptrs_seen[j] = NULL;
            }
        }
        if (group)
            printf("\n");
    }
    printf("checked %d, null %d, shared-groups %d\n", total, missing, shared);
    return 0;
}