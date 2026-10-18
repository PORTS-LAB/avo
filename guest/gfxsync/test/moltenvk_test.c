// Makes a pipeline with a fragment shader on the emulator's MoltenVK (what
// gfxstream runs guest Vulkan on), draws a 2x1 image into `attachments`
// colour attachments and prints each attachment's two pixels as RRGGBBAA.
// --split first passes the shader through the layer's avo_split_output_arrays,
// and --write saves what the driver got (for spirv-val). Exit status 2: the
// pipeline failed (MoltenVK prints why).
//
//   moltenvk_test <libMoltenVK.dylib> <vert.spv> <frag.spv> <attachments> [--split] [--write <file>]
#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#include "../src/frag_outputs.h"

#define CHECK(call)                                                                  \
    do {                                                                             \
        VkResult result_ = (call);                                                   \
        if (result_ != VK_SUCCESS) {                                                 \
            fprintf(stderr, "%s:%d: %s: %d\n", __FILE__, __LINE__, #call, result_); \
            exit(1);                                                                 \
        }                                                                            \
    } while (0)

enum { MAX_ATTACHMENTS = 8, WIDTH = 2 };

static PFN_vkGetInstanceProcAddr gipa;
static VkInstance instance;
#define FN(name) PFN_vk##name name = (PFN_vk##name)gipa(instance, "vk" #name)

static uint32_t* read_file(const char* path, size_t* words) {
    FILE* file = fopen(path, "rb");
    if (!file) {
        perror(path);
        exit(1);
    }
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    fseek(file, 0, SEEK_SET);
    uint32_t* code = malloc((size_t)size);
    if (!code || fread(code, 1, (size_t)size, file) != (size_t)size) exit(1);
    fclose(file);
    *words = (size_t)size / 4;
    return code;
}

static uint32_t memory_type(VkPhysicalDevice physical, uint32_t bits, VkMemoryPropertyFlags flags) {
    FN(GetPhysicalDeviceMemoryProperties);
    VkPhysicalDeviceMemoryProperties properties;
    GetPhysicalDeviceMemoryProperties(physical, &properties);
    for (uint32_t i = 0; i < properties.memoryTypeCount; i++) {
        if ((bits & 1u << i) && (properties.memoryTypes[i].propertyFlags & flags) == flags) return i;
    }
    fprintf(stderr, "no memory type\n");
    exit(1);
}

int main(int argc, char** argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: %s <libMoltenVK.dylib> <vert.spv> <frag.spv> <attachments> [--split] [--write <file>]\n", argv[0]);
        return 1;
    }
    uint32_t attachments = (uint32_t)atoi(argv[4]);
    bool split = false;
    const char* write_path = NULL;
    for (int i = 5; i < argc; i++) {
        if (strcmp(argv[i], "--split") == 0) split = true;
        if (strcmp(argv[i], "--write") == 0 && i + 1 < argc) write_path = argv[++i];
    }
    if (attachments < 1 || attachments > MAX_ATTACHMENTS) return 1;

    size_t vert_words, frag_words;
    uint32_t* vert = read_file(argv[2], &vert_words);
    uint32_t* frag = read_file(argv[3], &frag_words);
    if (split) {
        size_t words = 0;
        uint32_t* rewritten = avo_split_output_arrays(frag, frag_words, &words);
        fprintf(stderr, rewritten ? "split: %zu -> %zu words\n" : "split: unchanged (%zu words)\n", frag_words, words);
        if (rewritten) {
            free(frag);
            frag = rewritten;
            frag_words = words;
        }
    }
    if (write_path) {
        FILE* file = fopen(write_path, "wb");
        if (!file || fwrite(frag, 4, frag_words, file) != frag_words) return 1;
        fclose(file);
    }

    void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library || !(gipa = (PFN_vkGetInstanceProcAddr)dlsym(library, "vkGetInstanceProcAddr"))) {
        fprintf(stderr, "%s\n", dlerror());
        return 1;
    }
    FN(CreateInstance);
    const VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_1};
    CHECK(CreateInstance(&(VkInstanceCreateInfo){.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app},
                         NULL, &instance));

    FN(EnumeratePhysicalDevices);
    uint32_t count = 1;
    VkPhysicalDevice physical;
    VkResult enumerated = EnumeratePhysicalDevices(instance, &count, &physical);
    if ((enumerated != VK_SUCCESS && enumerated != VK_INCOMPLETE) || count < 1) return 1;

    FN(GetPhysicalDeviceQueueFamilyProperties);
    VkQueueFamilyProperties families[16];
    count = 16;
    GetPhysicalDeviceQueueFamilyProperties(physical, &count, families);
    uint32_t family = 0;
    while (family < count && !(families[family].queueFlags & VK_QUEUE_GRAPHICS_BIT)) family++;
    if (family == count) return 1;

    FN(EnumerateDeviceExtensionProperties);
    VkExtensionProperties extensions[512];
    count = 512;
    EnumerateDeviceExtensionProperties(physical, NULL, &count, extensions);
    const char* portability = NULL;
    for (uint32_t i = 0; i < count; i++) {
        if (strcmp(extensions[i].extensionName, "VK_KHR_portability_subset") == 0) portability = "VK_KHR_portability_subset";
    }
    FN(CreateDevice);
    VkDevice device;
    CHECK(CreateDevice(physical,
                       &(VkDeviceCreateInfo){
                           .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                           .queueCreateInfoCount = 1,
                           .pQueueCreateInfos =
                               &(VkDeviceQueueCreateInfo){
                                   .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                   .queueFamilyIndex = family,
                                   .queueCount = 1,
                                   .pQueuePriorities = (float[]){1.0f},
                               },
                           .enabledExtensionCount = portability ? 1 : 0,
                           .ppEnabledExtensionNames = &portability,
                       },
                       NULL, &device));

    FN(CreateImage);
    FN(GetImageMemoryRequirements);
    FN(AllocateMemory);
    FN(BindImageMemory);
    FN(CreateImageView);
    VkImage images[MAX_ATTACHMENTS];
    VkImageView views[MAX_ATTACHMENTS];
    for (uint32_t i = 0; i < attachments; i++) {
        CHECK(CreateImage(device,
                          &(VkImageCreateInfo){
                              .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                              .imageType = VK_IMAGE_TYPE_2D,
                              .format = VK_FORMAT_R8G8B8A8_UNORM,
                              .extent = {WIDTH, 1, 1},
                              .mipLevels = 1,
                              .arrayLayers = 1,
                              .samples = VK_SAMPLE_COUNT_1_BIT,
                              .tiling = VK_IMAGE_TILING_OPTIMAL,
                              .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                          },
                          NULL, &images[i]));
        VkMemoryRequirements needs;
        GetImageMemoryRequirements(device, images[i], &needs);
        VkDeviceMemory memory;
        CHECK(AllocateMemory(device,
                             &(VkMemoryAllocateInfo){
                                 .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                 .allocationSize = needs.size,
                                 .memoryTypeIndex = memory_type(physical, needs.memoryTypeBits, 0),
                             },
                             NULL, &memory));
        CHECK(BindImageMemory(device, images[i], memory, 0));
        CHECK(CreateImageView(device,
                              &(VkImageViewCreateInfo){
                                  .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                                  .image = images[i],
                                  .viewType = VK_IMAGE_VIEW_TYPE_2D,
                                  .format = VK_FORMAT_R8G8B8A8_UNORM,
                                  .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
                              },
                              NULL, &views[i]));
    }

    FN(CreateBuffer);
    FN(GetBufferMemoryRequirements);
    FN(BindBufferMemory);
    FN(MapMemory);
    VkBuffer buffer;
    CHECK(CreateBuffer(device,
                       &(VkBufferCreateInfo){
                           .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                           .size = attachments * WIDTH * 4,
                           .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                       },
                       NULL, &buffer));
    VkMemoryRequirements needs;
    GetBufferMemoryRequirements(device, buffer, &needs);
    VkDeviceMemory buffer_memory;
    CHECK(AllocateMemory(device,
                         &(VkMemoryAllocateInfo){
                             .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                             .allocationSize = needs.size,
                             .memoryTypeIndex = memory_type(physical, needs.memoryTypeBits,
                                                            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
                                                                | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
                         },
                         NULL, &buffer_memory));
    CHECK(BindBufferMemory(device, buffer, buffer_memory, 0));

    VkAttachmentDescription descriptions[MAX_ATTACHMENTS];
    VkAttachmentReference references[MAX_ATTACHMENTS];
    VkPipelineColorBlendAttachmentState blends[MAX_ATTACHMENTS];
    for (uint32_t i = 0; i < attachments; i++) {
        descriptions[i] = (VkAttachmentDescription){
            .format = VK_FORMAT_R8G8B8A8_UNORM,
            .samples = VK_SAMPLE_COUNT_1_BIT,
            .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        };
        references[i] = (VkAttachmentReference){i, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
        blends[i] = (VkPipelineColorBlendAttachmentState){.colorWriteMask = 0xf};
    }
    FN(CreateRenderPass);
    VkRenderPass render_pass;
    CHECK(CreateRenderPass(device,
                           &(VkRenderPassCreateInfo){
                               .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
                               .attachmentCount = attachments,
                               .pAttachments = descriptions,
                               .subpassCount = 1,
                               .pSubpasses =
                                   &(VkSubpassDescription){
                                       .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
                                       .colorAttachmentCount = attachments,
                                       .pColorAttachments = references,
                                   },
                               .dependencyCount = 1,
                               .pDependencies =
                                   &(VkSubpassDependency){
                                       .srcSubpass = 0,
                                       .dstSubpass = VK_SUBPASS_EXTERNAL,
                                       .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                                       .dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT,
                                       .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                                       .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
                                   },
                           },
                           NULL, &render_pass));
    FN(CreateFramebuffer);
    VkFramebuffer framebuffer;
    CHECK(CreateFramebuffer(device,
                            &(VkFramebufferCreateInfo){
                                .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                                .renderPass = render_pass,
                                .attachmentCount = attachments,
                                .pAttachments = views,
                                .width = WIDTH,
                                .height = 1,
                                .layers = 1,
                            },
                            NULL, &framebuffer));

    FN(CreateShaderModule);
    VkShaderModule modules[2];
    CHECK(CreateShaderModule(device,
                             &(VkShaderModuleCreateInfo){
                                 .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
                                 .codeSize = vert_words * 4,
                                 .pCode = vert,
                             },
                             NULL, &modules[0]));
    CHECK(CreateShaderModule(device,
                             &(VkShaderModuleCreateInfo){
                                 .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
                                 .codeSize = frag_words * 4,
                                 .pCode = frag,
                             },
                             NULL, &modules[1]));
    FN(CreatePipelineLayout);
    VkPipelineLayout layout;
    CHECK(CreatePipelineLayout(device, &(VkPipelineLayoutCreateInfo){.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO},
                               NULL, &layout));
    const VkPipelineShaderStageCreateInfo stages[2] = {
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_VERTEX_BIT, modules[0], "main", NULL},
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_FRAGMENT_BIT, modules[1], "main", NULL},
    };
    FN(CreateGraphicsPipelines);
    VkPipeline pipeline;
    VkResult made = CreateGraphicsPipelines(
        device, VK_NULL_HANDLE, 1,
        &(VkGraphicsPipelineCreateInfo){
            .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .stageCount = 2,
            .pStages = stages,
            .pVertexInputState = &(VkPipelineVertexInputStateCreateInfo){.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO},
            .pInputAssemblyState =
                &(VkPipelineInputAssemblyStateCreateInfo){
                    .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
                    .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
                },
            .pViewportState =
                &(VkPipelineViewportStateCreateInfo){
                    .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
                    .viewportCount = 1,
                    .pViewports = &(VkViewport){0, 0, WIDTH, 1, 0, 1},
                    .scissorCount = 1,
                    .pScissors = &(VkRect2D){{0, 0}, {WIDTH, 1}},
                },
            .pRasterizationState =
                &(VkPipelineRasterizationStateCreateInfo){
                    .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
                    .polygonMode = VK_POLYGON_MODE_FILL,
                    .cullMode = VK_CULL_MODE_NONE,
                    .lineWidth = 1,
                },
            .pMultisampleState =
                &(VkPipelineMultisampleStateCreateInfo){
                    .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
                    .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
                },
            .pColorBlendState =
                &(VkPipelineColorBlendStateCreateInfo){
                    .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
                    .attachmentCount = attachments,
                    .pAttachments = blends,
                },
            .layout = layout,
            .renderPass = render_pass,
        },
        NULL, &pipeline);
    if (made != VK_SUCCESS) {
        fprintf(stderr, "vkCreateGraphicsPipelines: %d\n", made);
        return 2;
    }

    FN(CreateCommandPool);
    FN(AllocateCommandBuffers);
    FN(BeginCommandBuffer);
    FN(CmdBeginRenderPass);
    FN(CmdBindPipeline);
    FN(CmdDraw);
    FN(CmdEndRenderPass);
    FN(CmdCopyImageToBuffer);
    FN(EndCommandBuffer);
    FN(GetDeviceQueue);
    FN(QueueSubmit);
    FN(QueueWaitIdle);
    VkCommandPool pool;
    CHECK(CreateCommandPool(device,
                            &(VkCommandPoolCreateInfo){.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = family},
                            NULL, &pool));
    VkCommandBuffer commands;
    CHECK(AllocateCommandBuffers(device,
                                 &(VkCommandBufferAllocateInfo){
                                     .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                                     .commandPool = pool,
                                     .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                                     .commandBufferCount = 1,
                                 },
                                 &commands));
    CHECK(BeginCommandBuffer(commands, &(VkCommandBufferBeginInfo){.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}));
    VkClearValue clears[MAX_ATTACHMENTS];
    memset(clears, 0, sizeof clears);
    CmdBeginRenderPass(commands,
                       &(VkRenderPassBeginInfo){
                           .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                           .renderPass = render_pass,
                           .framebuffer = framebuffer,
                           .renderArea = {{0, 0}, {WIDTH, 1}},
                           .clearValueCount = attachments,
                           .pClearValues = clears,
                       },
                       VK_SUBPASS_CONTENTS_INLINE);
    CmdBindPipeline(commands, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    CmdDraw(commands, 3, 1, 0, 0);
    CmdEndRenderPass(commands);
    for (uint32_t i = 0; i < attachments; i++) {
        CmdCopyImageToBuffer(commands, images[i], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1,
                             &(VkBufferImageCopy){
                                 .bufferOffset = i * WIDTH * 4,
                                 .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
                                 .imageExtent = {WIDTH, 1, 1},
                             });
    }
    CHECK(EndCommandBuffer(commands));
    VkQueue queue;
    GetDeviceQueue(device, family, 0, &queue);
    CHECK(QueueSubmit(queue, 1,
                      &(VkSubmitInfo){.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &commands},
                      VK_NULL_HANDLE));
    CHECK(QueueWaitIdle(queue));

    const uint8_t* pixels;
    CHECK(MapMemory(device, buffer_memory, 0, VK_WHOLE_SIZE, 0, (void**)&pixels));
    for (uint32_t i = 0; i < attachments * WIDTH; i++) {
        printf("%s%02x%02x%02x%02x", i ? " " : "", pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2], pixels[i * 4 + 3]);
    }
    printf("\n");
    return 0;
}
