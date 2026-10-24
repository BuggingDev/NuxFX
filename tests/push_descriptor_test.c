/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 NuxFX contributors
 *
 * Regression check for patch 20: vkCmdPushDescriptorSetKHR (the non-2 KHR
 * entrypoint used by vkd3d-proton) and
 * vkCmdPushDescriptorSetWithTemplateKHR must bind descriptors for the compute
 * bind point named by the command or by the template.
 *
 * Usage: push_descriptor_test <shader.spv> <plain|template>
 * Exit codes: 0 pass, 1 fail, 77 skip (no push descriptor support).
 */
#include <vulkan/vulkan.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(x)                                                              \
   do {                                                                       \
      VkResult r_ = (x);                                                      \
      if (r_ != VK_SUCCESS) {                                                 \
         fprintf(stderr, "%s failed: %d\n", #x, r_);                          \
         return 1;                                                            \
      }                                                                       \
   } while (0)

static unsigned char *
read_file(const char *path, size_t *size)
{
   FILE *f = fopen(path, "rb");
   if (!f) {
      fprintf(stderr, "cannot open %s\n", path);
      return NULL;
   }
   fseek(f, 0, SEEK_END);
   long len = ftell(f);
   fseek(f, 0, SEEK_SET);
   if (len <= 0) {
      fclose(f);
      return NULL;
   }
   unsigned char *data = malloc((size_t)len);
   if (!data || fread(data, 1, (size_t)len, f) != (size_t)len) {
      free(data);
      fclose(f);
      return NULL;
   }
   fclose(f);
   *size = (size_t)len;
   return data;
}

static int
has_device_extension(VkPhysicalDevice phys, const char *name)
{
   uint32_t count = 0;
   if (vkEnumerateDeviceExtensionProperties(phys, NULL, &count, NULL) != VK_SUCCESS)
      return 0;
   VkExtensionProperties *props = calloc(count, sizeof(*props));
   if (!props)
      return 0;
   if (vkEnumerateDeviceExtensionProperties(phys, NULL, &count, props) != VK_SUCCESS) {
      free(props);
      return 0;
   }
   int found = 0;
   for (uint32_t i = 0; i < count; i++) {
      if (strcmp(props[i].extensionName, name) == 0) {
         found = 1;
         break;
      }
   }
   free(props);
   return found;
}

int
main(int argc, char **argv)
{
   if (argc != 3 || (strcmp(argv[2], "plain") != 0 && strcmp(argv[2], "template") != 0)) {
      fprintf(stderr, "usage: %s <shader.spv> <plain|template>\n", argv[0]);
      return 1;
   }
   const int use_template = strcmp(argv[2], "template") == 0;

   size_t spv_size = 0;
   unsigned char *spv = read_file(argv[1], &spv_size);
   if (!spv) {
      fprintf(stderr, "cannot read shader %s\n", argv[1]);
      return 1;
   }

   VkApplicationInfo app_info = {
      .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
      .pApplicationName = "push_descriptor_test",
      .apiVersion = VK_API_VERSION_1_1,
   };
   VkInstanceCreateInfo instance_info = {
      .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
      .pApplicationInfo = &app_info,
   };
   VkInstance instance = VK_NULL_HANDLE;
   CHECK(vkCreateInstance(&instance_info, NULL, &instance));

   uint32_t phys_count = 0;
   CHECK(vkEnumeratePhysicalDevices(instance, &phys_count, NULL));
   if (phys_count == 0) {
      fprintf(stderr, "no Vulkan physical devices\n");
      return 77;
   }
   VkPhysicalDevice *phys = calloc(phys_count, sizeof(*phys));
   if (!phys)
      return 1;
   CHECK(vkEnumeratePhysicalDevices(instance, &phys_count, phys));

   VkPhysicalDevice chosen = VK_NULL_HANDLE;
   for (uint32_t i = 0; i < phys_count; i++) {
      if (has_device_extension(phys[i], VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME)) {
         chosen = phys[i];
         break;
      }
   }
   free(phys);
   if (chosen == VK_NULL_HANDLE) {
      printf("SKIP: no physical device with %s\n", VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME);
      return 77;
   }

   VkPhysicalDeviceProperties props;
   vkGetPhysicalDeviceProperties(chosen, &props);
   printf("device: %s (api %u.%u.%u)\n", props.deviceName,
          VK_API_VERSION_MAJOR(props.apiVersion),
          VK_API_VERSION_MINOR(props.apiVersion),
          VK_API_VERSION_PATCH(props.apiVersion));

   uint32_t queue_count = 0;
   vkGetPhysicalDeviceQueueFamilyProperties(chosen, &queue_count, NULL);
   VkQueueFamilyProperties *queues = calloc(queue_count, sizeof(*queues));
   if (!queues)
      return 1;
   vkGetPhysicalDeviceQueueFamilyProperties(chosen, &queue_count, queues);
   uint32_t queue_family = UINT32_MAX;
   for (uint32_t i = 0; i < queue_count; i++) {
      if (queues[i].queueFlags & VK_QUEUE_COMPUTE_BIT) {
         queue_family = i;
         break;
      }
   }
   free(queues);
   if (queue_family == UINT32_MAX) {
      fprintf(stderr, "no compute queue\n");
      return 1;
   }

   float priority = 1.0f;
   VkDeviceQueueCreateInfo queue_info = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueFamilyIndex = queue_family,
      .queueCount = 1,
      .pQueuePriorities = &priority,
   };
   const char *device_extensions[] = {VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME};
   VkDeviceCreateInfo device_info = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .queueCreateInfoCount = 1,
      .pQueueCreateInfos = &queue_info,
      .enabledExtensionCount = 1,
      .ppEnabledExtensionNames = device_extensions,
   };
   VkDevice device = VK_NULL_HANDLE;
   CHECK(vkCreateDevice(chosen, &device_info, NULL, &device));
   VkQueue queue = VK_NULL_HANDLE;
   vkGetDeviceQueue(device, queue_family, 0, &queue);

   PFN_vkCmdPushDescriptorSetKHR push_set =
      (PFN_vkCmdPushDescriptorSetKHR)vkGetDeviceProcAddr(device, "vkCmdPushDescriptorSetKHR");
   PFN_vkCmdPushDescriptorSetWithTemplateKHR push_template =
      (PFN_vkCmdPushDescriptorSetWithTemplateKHR)vkGetDeviceProcAddr(
         device, "vkCmdPushDescriptorSetWithTemplateKHR");
   if (!push_set || !push_template) {
      fprintf(stderr, "push descriptor entrypoints missing (plain %p, template %p)\n",
              (void *)push_set, (void *)push_template);
      return 1;
   }

   VkBufferCreateInfo buffer_info = {
      .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
      .size = 256,
      .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
      .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
   };
   VkBuffer buffer = VK_NULL_HANDLE;
   CHECK(vkCreateBuffer(device, &buffer_info, NULL, &buffer));
   VkMemoryRequirements mem_req;
   vkGetBufferMemoryRequirements(device, buffer, &mem_req);
   VkPhysicalDeviceMemoryProperties mem_props;
   vkGetPhysicalDeviceMemoryProperties(chosen, &mem_props);
   uint32_t memory_type = UINT32_MAX;
   for (uint32_t i = 0; i < mem_props.memoryTypeCount; i++) {
      if ((mem_req.memoryTypeBits & (1u << i)) &&
          (mem_props.memoryTypes[i].propertyFlags &
           (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) ==
             (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
         memory_type = i;
         break;
      }
   }
   if (memory_type == UINT32_MAX) {
      fprintf(stderr, "no host-visible coherent memory type for the storage buffer\n");
      return 1;
   }
   VkMemoryAllocateInfo alloc_info = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = mem_req.size,
      .memoryTypeIndex = memory_type,
   };
   VkDeviceMemory memory = VK_NULL_HANDLE;
   CHECK(vkAllocateMemory(device, &alloc_info, NULL, &memory));
   CHECK(vkBindBufferMemory(device, buffer, memory, 0));
   void *mapped = NULL;
   CHECK(vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &mapped));
   memset(mapped, 0, 256);

   VkDescriptorSetLayoutBinding binding = {
      .binding = 0,
      .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
      .descriptorCount = 1,
      .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
   };
   VkDescriptorSetLayoutCreateInfo layout_info = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      .flags = VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR,
      .bindingCount = 1,
      .pBindings = &binding,
   };
   VkDescriptorSetLayout set_layout = VK_NULL_HANDLE;
   CHECK(vkCreateDescriptorSetLayout(device, &layout_info, NULL, &set_layout));
   VkPipelineLayoutCreateInfo pipeline_layout_info = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
      .setLayoutCount = 1,
      .pSetLayouts = &set_layout,
   };
   VkPipelineLayout pipeline_layout = VK_NULL_HANDLE;
   CHECK(vkCreatePipelineLayout(device, &pipeline_layout_info, NULL, &pipeline_layout));

   VkShaderModuleCreateInfo module_info = {
      .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
      .codeSize = spv_size,
      .pCode = (const uint32_t *)spv,
   };
   VkShaderModule module = VK_NULL_HANDLE;
   CHECK(vkCreateShaderModule(device, &module_info, NULL, &module));
   VkComputePipelineCreateInfo pipeline_info = {
      .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
      .stage = {
         .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
         .stage = VK_SHADER_STAGE_COMPUTE_BIT,
         .module = module,
         .pName = "main",
      },
      .layout = pipeline_layout,
   };
   VkPipeline pipeline = VK_NULL_HANDLE;
   CHECK(vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &pipeline_info, NULL, &pipeline));

   VkDescriptorUpdateTemplateEntry entry = {
      .dstBinding = 0,
      .dstArrayElement = 0,
      .descriptorCount = 1,
      .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
      .offset = 0,
      .stride = 0,
   };
   VkDescriptorUpdateTemplateCreateInfo template_info = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_UPDATE_TEMPLATE_CREATE_INFO,
      .descriptorUpdateEntryCount = 1,
      .pDescriptorUpdateEntries = &entry,
      .templateType = VK_DESCRIPTOR_UPDATE_TEMPLATE_TYPE_PUSH_DESCRIPTORS_KHR,
      .descriptorSetLayout = VK_NULL_HANDLE,
      .pipelineBindPoint = VK_PIPELINE_BIND_POINT_COMPUTE,
      .pipelineLayout = pipeline_layout,
      .set = 0,
   };
   VkDescriptorUpdateTemplate update_template = VK_NULL_HANDLE;
   CHECK(vkCreateDescriptorUpdateTemplate(device, &template_info, NULL, &update_template));

   VkCommandPoolCreateInfo pool_info = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
      .queueFamilyIndex = queue_family,
   };
   VkCommandPool pool = VK_NULL_HANDLE;
   CHECK(vkCreateCommandPool(device, &pool_info, NULL, &pool));
   VkCommandBufferAllocateInfo cmd_info = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
      .commandPool = pool,
      .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
      .commandBufferCount = 1,
   };
   VkCommandBuffer cmd = VK_NULL_HANDLE;
   CHECK(vkAllocateCommandBuffers(device, &cmd_info, &cmd));

   VkCommandBufferBeginInfo begin_info = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
   };
   CHECK(vkBeginCommandBuffer(cmd, &begin_info));
   vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);

   VkDescriptorBufferInfo descriptor_buffer = {
      .buffer = buffer,
      .offset = 0,
      .range = VK_WHOLE_SIZE,
   };
   if (use_template) {
      push_template(cmd, update_template, pipeline_layout, 0, &descriptor_buffer);
   } else {
      VkWriteDescriptorSet write = {
         .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
         .dstBinding = 0,
         .dstArrayElement = 0,
         .descriptorCount = 1,
         .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
         .pBufferInfo = &descriptor_buffer,
      };
      push_set(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline_layout, 0, 1, &write);
   }
   vkCmdDispatch(cmd, 1, 1, 1);

   VkBufferMemoryBarrier barrier = {
      .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
      .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
      .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
      .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .buffer = buffer,
      .offset = 0,
      .size = VK_WHOLE_SIZE,
   };
   vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                        VK_PIPELINE_STAGE_HOST_BIT, 0, 0, NULL, 1, &barrier, 0, NULL);
   CHECK(vkEndCommandBuffer(cmd));

   VkFenceCreateInfo fence_info = {
      .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
   };
   VkFence fence = VK_NULL_HANDLE;
   CHECK(vkCreateFence(device, &fence_info, NULL, &fence));
   VkSubmitInfo submit_info = {
      .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
      .commandBufferCount = 1,
      .pCommandBuffers = &cmd,
   };
   CHECK(vkQueueSubmit(queue, 1, &submit_info, fence));
   CHECK(vkWaitForFences(device, 1, &fence, VK_TRUE, UINT64_MAX));

   uint32_t value = 0;
   memcpy(&value, mapped, sizeof(value));
   printf("shader wrote 0x%08x (expected 0xdeadbeef), path %s\n", value,
          use_template ? "template" : "plain");

   vkUnmapMemory(device, memory);
   vkDestroyFence(device, fence, NULL);
   vkDestroyCommandPool(device, pool, NULL);
   vkDestroyDescriptorUpdateTemplate(device, update_template, NULL);
   vkDestroyPipeline(device, pipeline, NULL);
   vkDestroyShaderModule(device, module, NULL);
   vkDestroyPipelineLayout(device, pipeline_layout, NULL);
   vkDestroyDescriptorSetLayout(device, set_layout, NULL);
   vkDestroyBuffer(device, buffer, NULL);
   vkFreeMemory(device, memory, NULL);
   vkDestroyDevice(device, NULL);
   vkDestroyInstance(instance, NULL);
   free(spv);

   return value == 0xDEADBEEFu ? 0 : 1;
}
