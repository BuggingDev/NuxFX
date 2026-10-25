/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 NuxFX contributors
 *
 * VK_EXT_robustness2 behaviour that patch 15 advertises and that DXVK 3.0.1 and vkd3d-proton need
 * (D3D11 and D3D12 define out-of-range accesses; both layers rely on the driver for them):
 *   ssbo       robustBufferAccess2: a storage buffer descriptor whose range is smaller than the
 *              buffer. Reads beyond the range (inside and far outside the buffer) return zero and
 *              writes beyond it are dropped.
 *   ubo        the same for a uniform buffer descriptor.
 *   image      robustImageAccess2: out-of-bounds imageLoad returns zero, imageStore is dropped.
 *   nullimage  nullDescriptor: a null storage image and a null sampled image read as zero and a
 *              store to the null storage image is dropped.
 *   nulltexel  nullDescriptor: a null uniform texel buffer and a null storage texel buffer.
 * Each case is a separate process, because a driver that gets it wrong may crash.
 *
 * Usage: robustness_test <shader.spv> <ssbo|ubo|image|nullimage|nulltexel>
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

#define MARK 0xA5A5A5A5u
#define DEAD 0xDEADBEEFu

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

static VkPhysicalDeviceMemoryProperties mp;

static uint32_t
find_type(uint32_t bits, VkMemoryPropertyFlags want)
{
   for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
      if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want)
         return i;
   return UINT32_MAX;
}

struct hostbuf {
   VkBuffer buf;
   VkDeviceMemory mem;
   volatile uint32_t *map;
};

static int
make_hostbuf(VkDevice dev, struct hostbuf *b, VkBufferUsageFlags usage, uint32_t fill)
{
   VkBufferCreateInfo bci = {
      .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
      .size = 1024,
      .usage = usage,
      .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
   };
   CHECK(vkCreateBuffer(dev, &bci, NULL, &b->buf));
   VkMemoryRequirements mr;
   vkGetBufferMemoryRequirements(dev, b->buf, &mr);
   uint32_t t = find_type(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
   if (t == UINT32_MAX)
      return 1;
   VkMemoryAllocateInfo mai = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = mr.size,
      .memoryTypeIndex = t,
   };
   CHECK(vkAllocateMemory(dev, &mai, NULL, &b->mem));
   CHECK(vkBindBufferMemory(dev, b->buf, b->mem, 0));
   CHECK(vkMapMemory(dev, b->mem, 0, VK_WHOLE_SIZE, 0, (void **)&b->map));
   for (int i = 0; i < 256; i++)
      b->map[i] = fill;
   return 0;
}

int
main(int argc, char **argv)
{
   static const char *cases[] = {"ssbo", "ubo", "image", "nullimage", "nulltexel"};
   int which = -1;
   if (argc == 3)
      for (int i = 0; i < 5; i++)
         if (strcmp(argv[2], cases[i]) == 0)
            which = i;
   if (which < 0) {
      fprintf(stderr, "usage: %s <shader.spv> <ssbo|ubo|image|nullimage|nulltexel>\n", argv[0]);
      return 1;
   }
   size_t spv_size = 0;
   unsigned char *spv = read_file(argv[1], &spv_size);
   if (!spv) {
      fprintf(stderr, "cannot read %s\n", argv[1]);
      return 1;
   }

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
   vkGetPhysicalDeviceMemoryProperties(phys, &mp);

   VkPhysicalDeviceRobustness2FeaturesEXT rob2 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT};
   VkPhysicalDeviceFeatures2 f2 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &rob2};
   vkGetPhysicalDeviceFeatures2(phys, &f2);
   printf("advertised: robustBufferAccess %u, robustBufferAccess2 %u, robustImageAccess2 %u, nullDescriptor %u\n",
          f2.features.robustBufferAccess, rob2.robustBufferAccess2, rob2.robustImageAccess2, rob2.nullDescriptor);
   /* The range of a buffer descriptor is rounded up to these sizes before it is checked, so reads
    * inside the rounded range may return data and only the bytes past it must read as zero. */
   VkPhysicalDeviceRobustness2PropertiesEXT rp = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_PROPERTIES_EXT};
   VkPhysicalDeviceProperties2 p2 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &rp};
   vkGetPhysicalDeviceProperties2(phys, &p2);
   const uint32_t salign = rp.robustStorageBufferAccessSizeAlignment ? rp.robustStorageBufferAccessSizeAlignment : 1;
   const uint32_t ualign = rp.robustUniformBufferAccessSizeAlignment ? rp.robustUniformBufferAccessSizeAlignment : 1;
   printf("robustStorageBufferAccessSizeAlignment %u, robustUniformBufferAccessSizeAlignment %u\n", salign, ualign);
   const int need_buf = which <= 1, need_img = which == 2, need_null = which >= 3;
   if ((need_buf && !rob2.robustBufferAccess2) || (need_img && !rob2.robustImageAccess2) ||
       (need_null && !rob2.nullDescriptor)) {
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
      .robustBufferAccess2 = need_buf,
      .robustImageAccess2 = need_img,
      .nullDescriptor = need_null,
   };
   VkPhysicalDeviceFeatures2 f2_on = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
      .pNext = &rob2_on,
      .features = {.robustBufferAccess = VK_TRUE},
   };
   const char *ext[] = {VK_EXT_ROBUSTNESS_2_EXTENSION_NAME};
   VkDeviceCreateInfo dci = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .pNext = &f2_on,
      .queueCreateInfoCount = 1,
      .pQueueCreateInfos = &qi,
      .enabledExtensionCount = 1,
      .ppEnabledExtensionNames = ext,
   };
   VkDevice dev;
   CHECK(vkCreateDevice(phys, &dci, NULL, &dev));
   VkQueue queue;
   vkGetDeviceQueue(dev, 0, 0, &queue);

   struct hostbuf under = {0}, out = {0};
   if (which <= 1 && make_hostbuf(dev, &under, which == 0 ? VK_BUFFER_USAGE_STORAGE_BUFFER_BIT : VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, MARK))
      return 1;
   if (make_hostbuf(dev, &out, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, DEAD))
      return 1;

   /* The 4x4 R32_UINT storage image of the "image" case, cleared to 7. */
   VkImage img = VK_NULL_HANDLE;
   VkImageView view = VK_NULL_HANDLE;
   if (which == 2) {
      VkImageCreateInfo ii = {
         .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
         .imageType = VK_IMAGE_TYPE_2D,
         .format = VK_FORMAT_R32_UINT,
         .extent = {4, 4, 1},
         .mipLevels = 1,
         .arrayLayers = 1,
         .samples = VK_SAMPLE_COUNT_1_BIT,
         .tiling = VK_IMAGE_TILING_OPTIMAL,
         .usage = VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
         .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
         .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
      };
      CHECK(vkCreateImage(dev, &ii, NULL, &img));
      VkMemoryRequirements mr;
      vkGetImageMemoryRequirements(dev, img, &mr);
      uint32_t t = find_type(mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
      if (t == UINT32_MAX)
         t = find_type(mr.memoryTypeBits, 0);
      VkMemoryAllocateInfo mai = {
         .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
         .allocationSize = mr.size,
         .memoryTypeIndex = t,
      };
      VkDeviceMemory imem;
      CHECK(vkAllocateMemory(dev, &mai, NULL, &imem));
      CHECK(vkBindImageMemory(dev, img, imem, 0));
      VkImageViewCreateInfo vi = {
         .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
         .image = img,
         .viewType = VK_IMAGE_VIEW_TYPE_2D,
         .format = VK_FORMAT_R32_UINT,
         .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
      };
      CHECK(vkCreateImageView(dev, &vi, NULL, &view));
   }

   /* Bindings: 0 under test, 1 the output buffer, 2 a second null descriptor (null cases). */
   VkDescriptorType t0, t2 = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
   switch (which) {
   case 0: t0 = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER; break;
   case 1: t0 = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER; break;
   case 2: t0 = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE; break;
   case 3: t0 = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE; t2 = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE; break;
   default: t0 = VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER; t2 = VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER; break;
   }
   const int nb = need_null ? 3 : 2;
   VkDescriptorSetLayoutBinding b[3] = {
      {.binding = 0, .descriptorType = t0, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT},
      {.binding = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT},
      {.binding = 2, .descriptorType = t2, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT},
   };
   VkDescriptorSetLayoutCreateInfo slci = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      .bindingCount = nb,
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

   VkDescriptorPoolSize ps[3] = {{t0, 1}, {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1}, {t2, 1}};
   VkDescriptorPoolCreateInfo dpci = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
      .maxSets = 1,
      .poolSizeCount = nb,
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

   /* A range of 64 bytes of a 1024-byte buffer: everything past word 15 is out of range. */
   VkDescriptorBufferInfo under_info = {.buffer = under.buf, .offset = 0, .range = 64};
   VkDescriptorBufferInfo out_info = {.buffer = out.buf, .offset = 0, .range = VK_WHOLE_SIZE};
   VkDescriptorImageInfo img_info = {.imageView = view, .imageLayout = VK_IMAGE_LAYOUT_GENERAL};
   VkDescriptorImageInfo null_img = {.imageView = VK_NULL_HANDLE, .imageLayout = VK_IMAGE_LAYOUT_GENERAL};
   VkBufferView null_bv = VK_NULL_HANDLE;
   VkWriteDescriptorSet w[3] = {
      {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 0, .descriptorCount = 1, .descriptorType = t0},
      {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 1, .descriptorCount = 1,
       .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &out_info},
      {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 2, .descriptorCount = 1, .descriptorType = t2},
   };
   if (which <= 1)
      w[0].pBufferInfo = &under_info;
   else if (which == 2)
      w[0].pImageInfo = &img_info;
   else if (which == 3) {
      w[0].pImageInfo = &null_img;
      w[2].pImageInfo = &null_img;
   } else {
      w[0].pTexelBufferView = &null_bv;
      w[2].pTexelBufferView = &null_bv;
   }
   vkUpdateDescriptorSets(dev, nb, w, 0, NULL);

   VkCommandPoolCreateInfo cpi = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = 0};
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
   if (which == 2) {
      VkImageSubresourceRange sr = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
      VkImageMemoryBarrier to_dst = {
         .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
         .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
         .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
         .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
         .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
         .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
         .image = img,
         .subresourceRange = sr,
      };
      vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &to_dst);
      VkClearColorValue seven = {.uint32 = {7, 7, 7, 7}};
      vkCmdClearColorImage(cmd, img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &seven, 1, &sr);
      VkImageMemoryBarrier to_gen = {
         .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
         .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
         .dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT,
         .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
         .newLayout = VK_IMAGE_LAYOUT_GENERAL,
         .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
         .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
         .image = img,
         .subresourceRange = sr,
      };
      vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, NULL, 0, NULL, 1, &to_gen);
   }
   vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
   vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pl, 0, 1, &set, 0, NULL);
   vkCmdDispatch(cmd, 1, 1, 1);
   VkMemoryBarrier mb = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
      .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
      .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
   };
   vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
   CHECK(vkEndCommandBuffer(cmd));
   VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
   VkFence fence;
   CHECK(vkCreateFence(dev, &fci, NULL, &fence));
   VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd};
   CHECK(vkQueueSubmit(queue, 1, &si, fence));
   CHECK(vkWaitForFences(dev, 1, &fence, VK_TRUE, 10ull * 1000000000ull));

   int fail = 0;
   const char *name = cases[which];
#define EXPECT(what, got, want)                                                              \
   do {                                                                                       \
      uint32_t g_ = (got), w_ = (want);                                                       \
      printf("  %-44s 0x%08x (expected 0x%08x)%s\n", what, g_, w_, g_ == w_ ? "" : "  <-- WRONG"); \
      if (g_ != w_)                                                                           \
         fail = 1;                                                                            \
   } while (0)
   printf("case %s:\n", name);
   switch (which) {
   case 0:
      EXPECT("read inside the range (word 0)", out.map[0], MARK);
      EXPECT("read the last word of the range (word 15)", out.map[1], MARK);
      EXPECT("read beyond the range, inside the buffer", out.map[2], 0);
      EXPECT("read beyond the buffer", out.map[3], 0);
      EXPECT("write beyond the range (word 16) dropped", under.map[16], MARK);
      EXPECT("write beyond the buffer (word 40) dropped", under.map[40], MARK);
      break;
   case 1:
      EXPECT("read inside the range (v[0].x)", out.map[0], MARK);
      EXPECT("read the last vec4 of the range (v[3].w)", out.map[1], MARK);
      /* Byte 64 is past the range; it may return data only if the rounded range covers it. */
      if (ualign <= 64)
         EXPECT("read at byte 64, past the range", out.map[2], 0);
      else
         printf("  %-44s 0x%08x (inside the range rounded up to %u: any value)\n", "read at byte 64, past the range", out.map[2], ualign);
      EXPECT("read at byte 256, past the rounded range", out.map[3], 0);
      EXPECT("read at byte 640, past the rounded range", out.map[4], 0);
      break;
   case 2:
      EXPECT("imageLoad inside the image", out.map[0], 7);
      EXPECT("imageLoad at (10,10)", out.map[1], 0);
      EXPECT("imageLoad at (-1,0)", out.map[2], 0);
      EXPECT("imageLoad after an in-range store", out.map[3], 5);
      EXPECT("sum of all texels (7*15+5; stray store?)", out.map[4], 110);
      break;
   default:
      EXPECT("read of the first null descriptor", out.map[0], 0);
      EXPECT("read of the second null descriptor", out.map[1], 0);
      EXPECT("the shader ran to the end", out.map[2], 1);
      break;
   }
   printf("%s: %s\n", name, fail ? "FAIL" : "ok");
   return fail;
}
