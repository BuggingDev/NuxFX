/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 NuxFX contributors
 *
 * Two features that patch 15 advertises (DXVK 3.0.1 refuses an adapter without them):
 *   null    nullDescriptor (VK_EXT_robustness2): a storage buffer descriptor written with
 *           VK_NULL_HANDLE reads as zero.
 *   inline  inlineUniformBlock: a uniform block whose data is written into the descriptor set.
 * Each mode is a separate process, because a driver that cannot do it may crash.
 *
 * Usage: descriptor_features_test <shader.spv> <null|inline>
 * Exit codes: 0 pass, 1 fail, 77 skip (feature not advertised).
 */
#include <vulkan/vulkan.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(x)                                                    \
   do {                                                             \
      VkResult r_ = (x);                                            \
      if (r_ != VK_SUCCESS) {                                       \
         fprintf(stderr, "%s failed: %d\n", #x, r_);                \
         return 1;                                                  \
      }                                                             \
   } while (0)

static unsigned char *
read_file(const char *path, size_t *size)
{
   FILE *f = fopen(path, "rb");
   if (!f)
      return NULL;
   fseek(f, 0, SEEK_END);
   long len = ftell(f);
   fseek(f, 0, SEEK_SET);
   unsigned char *data = len > 0 ? malloc((size_t)len) : NULL;
   if (!data || fread(data, 1, (size_t)len, f) != (size_t)len) {
      fclose(f);
      free(data);
      return NULL;
   }
   fclose(f);
   *size = (size_t)len;
   return data;
}

int
main(int argc, char **argv)
{
   if (argc != 3 || (strcmp(argv[2], "null") != 0 && strcmp(argv[2], "nullubo") != 0 &&
                     strcmp(argv[2], "inline") != 0)) {
      fprintf(stderr, "usage: %s <shader.spv> <null|nullubo|inline>\n", argv[0]);
      return 1;
   }
   const int inline_mode = strcmp(argv[2], "inline") == 0;
   const int ubo_mode = strcmp(argv[2], "nullubo") == 0;
   const VkDescriptorType null_type =
      ubo_mode ? VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER : VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
   size_t spv_size = 0;
   unsigned char *spv = read_file(argv[1], &spv_size);
   if (!spv) {
      fprintf(stderr, "cannot read %s\n", argv[1]);
      return 1;
   }

   VkApplicationInfo app = {
      .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
      .apiVersion = VK_API_VERSION_1_3,
   };
   VkInstanceCreateInfo ici = {
      .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
      .pApplicationInfo = &app,
   };
   VkInstance instance;
   CHECK(vkCreateInstance(&ici, NULL, &instance));
   uint32_t n = 1;
   VkPhysicalDevice phys;
   vkEnumeratePhysicalDevices(instance, &n, &phys);
   if (n == 0) {
      printf("SKIP: no Vulkan device\n");
      return 77;
   }

   VkPhysicalDeviceRobustness2FeaturesEXT rob2 = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT,
   };
   VkPhysicalDeviceVulkan13Features f13 = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
      .pNext = &rob2,
   };
   VkPhysicalDeviceFeatures2 f2 = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
      .pNext = &f13,
   };
   vkGetPhysicalDeviceFeatures2(phys, &f2);
   printf("advertised: nullDescriptor %u, inlineUniformBlock %u\n", rob2.nullDescriptor,
          f13.inlineUniformBlock);
   if ((inline_mode && !f13.inlineUniformBlock) || (!inline_mode && !rob2.nullDescriptor)) {
      printf("SKIP: not advertised\n");
      return 77;
   }

   float prio = 1.0f;
   VkDeviceQueueCreateInfo qi = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueFamilyIndex = 0,
      .queueCount = 1,
      .pQueuePriorities = &prio,
   };
   VkPhysicalDeviceRobustness2FeaturesEXT rob2_on = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT,
      .nullDescriptor = VK_TRUE,
   };
   VkPhysicalDeviceVulkan13Features f13_on = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
      .pNext = &rob2_on,
      .inlineUniformBlock = VK_TRUE,
   };
   const char *ext[] = {VK_EXT_ROBUSTNESS_2_EXTENSION_NAME};
   VkDeviceCreateInfo dci = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .pNext = &f13_on,
      .queueCreateInfoCount = 1,
      .pQueueCreateInfos = &qi,
      .enabledExtensionCount = inline_mode ? 0 : 1,
      .ppEnabledExtensionNames = ext,
   };
   VkDevice dev;
   CHECK(vkCreateDevice(phys, &dci, NULL, &dev));
   VkQueue queue;
   vkGetDeviceQueue(dev, 0, 0, &queue);

   /* The output buffer: one word, pre-set to a marker. */
   VkBufferCreateInfo bci = {
      .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
      .size = 256,
      .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
      .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
   };
   VkBuffer out;
   CHECK(vkCreateBuffer(dev, &bci, NULL, &out));
   VkMemoryRequirements mr;
   vkGetBufferMemoryRequirements(dev, out, &mr);
   VkPhysicalDeviceMemoryProperties mp;
   vkGetPhysicalDeviceMemoryProperties(phys, &mp);
   uint32_t type = UINT32_MAX;
   for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
      const VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
      if ((mr.memoryTypeBits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) {
         type = i;
         break;
      }
   }
   if (type == UINT32_MAX)
      return 1;
   VkMemoryAllocateInfo mai = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = mr.size,
      .memoryTypeIndex = type,
   };
   VkDeviceMemory mem;
   CHECK(vkAllocateMemory(dev, &mai, NULL, &mem));
   CHECK(vkBindBufferMemory(dev, out, mem, 0));
   volatile uint32_t *map;
   CHECK(vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, (void **)&map));
   map[0] = 0xDEADBEEFu;

   /* Layout: binding 0 is the feature under test, binding 1 the output buffer. */
   VkDescriptorSetLayoutBinding b[2] = {
      {
         .binding = 0,
         .descriptorType = inline_mode ? VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK : null_type,
         .descriptorCount = inline_mode ? 4 : 1,
         .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
      },
      {
         .binding = 1,
         .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
         .descriptorCount = 1,
         .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
      },
   };
   VkDescriptorSetLayoutCreateInfo slci = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      .bindingCount = 2,
      .pBindings = b,
   };
   VkDescriptorSetLayout sl;
   CHECK(vkCreateDescriptorSetLayout(dev, &slci, NULL, &sl));
   VkPipelineLayoutCreateInfo plci = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
      .setLayoutCount = 1,
      .pSetLayouts = &sl,
   };
   VkPipelineLayout pl;
   CHECK(vkCreatePipelineLayout(dev, &plci, NULL, &pl));

   VkShaderModuleCreateInfo smci = {
      .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
      .codeSize = spv_size,
      .pCode = (const uint32_t *)spv,
   };
   VkShaderModule sm;
   CHECK(vkCreateShaderModule(dev, &smci, NULL, &sm));
   VkComputePipelineCreateInfo cpci = {
      .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
      .stage = {
         .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
         .stage = VK_SHADER_STAGE_COMPUTE_BIT,
         .module = sm,
         .pName = "main",
      },
      .layout = pl,
   };
   VkPipeline pipe;
   CHECK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpci, NULL, &pipe));

   VkDescriptorPoolSize ps[2] = {
      {inline_mode ? VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK : null_type, inline_mode ? 4 : 1},
      {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1},
   };
   VkDescriptorPoolInlineUniformBlockCreateInfo pi = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_INLINE_UNIFORM_BLOCK_CREATE_INFO,
      .maxInlineUniformBlockBindings = 1,
   };
   VkDescriptorPoolCreateInfo dpci = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
      .pNext = inline_mode ? &pi : NULL,
      .maxSets = 1,
      .poolSizeCount = 2,
      .pPoolSizes = ps,
   };
   VkDescriptorPool dp;
   CHECK(vkCreateDescriptorPool(dev, &dpci, NULL, &dp));
   VkDescriptorSetAllocateInfo dsai = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
      .descriptorPool = dp,
      .descriptorSetCount = 1,
      .pSetLayouts = &sl,
   };
   VkDescriptorSet set;
   CHECK(vkAllocateDescriptorSets(dev, &dsai, &set));

   uint32_t block = 0x1234ABCDu;
   VkWriteDescriptorSetInlineUniformBlock wi = {
      .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET_INLINE_UNIFORM_BLOCK,
      .dataSize = 4,
      .pData = &block,
   };
   VkDescriptorBufferInfo null_buf = {.buffer = VK_NULL_HANDLE, .offset = 0, .range = VK_WHOLE_SIZE};
   VkDescriptorBufferInfo out_buf = {.buffer = out, .offset = 0, .range = VK_WHOLE_SIZE};
   VkWriteDescriptorSet w[2] = {
      {
         .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
         .pNext = inline_mode ? &wi : NULL,
         .dstSet = set,
         .dstBinding = 0,
         .descriptorCount = inline_mode ? 4 : 1,
         .descriptorType = inline_mode ? VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK : null_type,
         .pBufferInfo = inline_mode ? NULL : &null_buf,
      },
      {
         .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
         .dstSet = set,
         .dstBinding = 1,
         .descriptorCount = 1,
         .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
         .pBufferInfo = &out_buf,
      },
   };
   printf("writing the descriptors\n");
   fflush(stdout);
   vkUpdateDescriptorSets(dev, 2, w, 0, NULL);

   VkCommandPoolCreateInfo cpi = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
      .queueFamilyIndex = 0,
   };
   VkCommandPool pool;
   CHECK(vkCreateCommandPool(dev, &cpi, NULL, &pool));
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
   vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
   vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pl, 0, 1, &set, 0, NULL);
   vkCmdDispatch(cmd, 1, 1, 1);
   VkBufferMemoryBarrier bar = {
      .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
      .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
      .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
      .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .buffer = out,
      .size = VK_WHOLE_SIZE,
   };
   vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 0, NULL, 1, &bar, 0, NULL);
   CHECK(vkEndCommandBuffer(cmd));
   VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
   VkFence fence;
   CHECK(vkCreateFence(dev, &fci, NULL, &fence));
   VkSubmitInfo si = {
      .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
      .commandBufferCount = 1,
      .pCommandBuffers = &cmd,
   };
   CHECK(vkQueueSubmit(queue, 1, &si, fence));
   CHECK(vkWaitForFences(dev, 1, &fence, VK_TRUE, 10ull * 1000000000ull));

   uint32_t got = map[0];
   uint32_t want = inline_mode ? 0x1234ABCDu : 0u;
   printf("shader wrote 0x%08x (expected 0x%08x), %s\n", got, want,
          inline_mode ? "inline uniform block" : (ubo_mode ? "null uniform buffer" : "null storage buffer"));
   return got == want ? 0 : 1;
}
