/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 NuxFX contributors
 *
 * Calls the VK_EXT_transform_feedback entrypoints that dzn implements as stubs (patch 09), twice in
 * two command buffers. Patch 23 makes the first call print one warning line; this program only has
 * to run to the end, run_xfb_stub_test.sh looks at the line.
 * Exit codes: 0 done, 1 failure, 77 skip (the extension is not available).
 */
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <string.h>

#define CHECK(x)                                                    \
   do {                                                             \
      VkResult r_ = (x);                                            \
      if (r_ != VK_SUCCESS) {                                       \
         fprintf(stderr, "%s failed: %d\n", #x, r_);                \
         return 1;                                                  \
      }                                                             \
   } while (0)

int
main(void)
{
   VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3};
   VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
   VkInstance instance;
   CHECK(vkCreateInstance(&ici, NULL, &instance));
   uint32_t n = 1;
   VkPhysicalDevice phys;
   vkEnumeratePhysicalDevices(instance, &n, &phys);
   if (n == 0) {
      printf("SKIP: no Vulkan device\n");
      return 77;
   }
   uint32_t ec = 0;
   vkEnumerateDeviceExtensionProperties(phys, NULL, &ec, NULL);
   VkExtensionProperties props[512];
   if (ec > 512)
      ec = 512;
   vkEnumerateDeviceExtensionProperties(phys, NULL, &ec, props);
   int have = 0;
   for (uint32_t i = 0; i < ec; i++)
      if (strcmp(props[i].extensionName, VK_EXT_TRANSFORM_FEEDBACK_EXTENSION_NAME) == 0)
         have = 1;
   if (!have) {
      printf("SKIP: %s is not available\n", VK_EXT_TRANSFORM_FEEDBACK_EXTENSION_NAME);
      return 77;
   }

   float prio = 1.0f;
   VkDeviceQueueCreateInfo qi = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueFamilyIndex = 0,
      .queueCount = 1,
      .pQueuePriorities = &prio,
   };
   VkPhysicalDeviceTransformFeedbackFeaturesEXT xf = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_FEATURES_EXT,
      .transformFeedback = VK_TRUE,
   };
   const char *ext[] = {VK_EXT_TRANSFORM_FEEDBACK_EXTENSION_NAME};
   VkDeviceCreateInfo dci = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .pNext = &xf,
      .queueCreateInfoCount = 1,
      .pQueueCreateInfos = &qi,
      .enabledExtensionCount = 1,
      .ppEnabledExtensionNames = ext,
   };
   VkDevice dev;
   CHECK(vkCreateDevice(phys, &dci, NULL, &dev));
   PFN_vkCmdBindTransformFeedbackBuffersEXT bind =
      (PFN_vkCmdBindTransformFeedbackBuffersEXT)vkGetDeviceProcAddr(dev, "vkCmdBindTransformFeedbackBuffersEXT");
   if (!bind) {
      fprintf(stderr, "vkCmdBindTransformFeedbackBuffersEXT is missing\n");
      return 1;
   }
   VkQueue queue;
   vkGetDeviceQueue(dev, 0, 0, &queue);

   VkBufferCreateInfo bci = {
      .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
      .size = 256,
      .usage = VK_BUFFER_USAGE_TRANSFORM_FEEDBACK_BUFFER_BIT_EXT,
      .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
   };
   VkBuffer buf;
   CHECK(vkCreateBuffer(dev, &bci, NULL, &buf));
   VkMemoryRequirements mr;
   vkGetBufferMemoryRequirements(dev, buf, &mr);
   VkPhysicalDeviceMemoryProperties mp;
   vkGetPhysicalDeviceMemoryProperties(phys, &mp);
   uint32_t type = 0;
   while (type < mp.memoryTypeCount && !(mr.memoryTypeBits & (1u << type)))
      type++;
   VkMemoryAllocateInfo mai = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = mr.size,
      .memoryTypeIndex = type,
   };
   VkDeviceMemory mem;
   CHECK(vkAllocateMemory(dev, &mai, NULL, &mem));
   CHECK(vkBindBufferMemory(dev, buf, mem, 0));

   VkCommandPoolCreateInfo cpi = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = 0};
   VkCommandPool pool;
   CHECK(vkCreateCommandPool(dev, &cpi, NULL, &pool));
   for (int round = 0; round < 2; round++) {
      VkCommandBufferAllocateInfo cai = {
         .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
         .commandPool = pool,
         .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
         .commandBufferCount = 1,
      };
      VkCommandBuffer cmd;
      CHECK(vkAllocateCommandBuffers(dev, &cai, &cmd));
      VkCommandBufferBeginInfo cbi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
      CHECK(vkBeginCommandBuffer(cmd, &cbi));
      VkDeviceSize off = 0, size = 256;
      bind(cmd, 0, 1, &buf, &off, &size);
      CHECK(vkEndCommandBuffer(cmd));
      VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
      VkFence fence;
      CHECK(vkCreateFence(dev, &fci, NULL, &fence));
      VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd};
      CHECK(vkQueueSubmit(queue, 1, &si, fence));
      CHECK(vkWaitForFences(dev, 1, &fence, VK_TRUE, 10ull * 1000000000ull));
   }
   printf("transform feedback entrypoints called twice\n");
   return 0;
}
