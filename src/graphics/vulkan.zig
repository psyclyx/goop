//! Vulkan instance/device ownership with no window-system dependency.

const std = @import("std");

pub const vk = @cImport({
    @cInclude("vulkan/vulkan.h");
});

pub const Error = error{
    InstanceCreationFailed,
    NoPhysicalDevice,
    NoQueueFamily,
    DeviceCreationFailed,
    OutOfHostMemory,
    OutOfDeviceMemory,
    VulkanFailure,
};

pub const Instance = struct {
    handle: vk.VkInstance,

    pub fn init(
        application_name: [*:0]const u8,
        extensions: []const [*c]const u8,
    ) Error!Instance {
        const app_info = std.mem.zeroInit(vk.VkApplicationInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_APPLICATION_INFO)),
            .pApplicationName = application_name,
            .applicationVersion = vk.VK_MAKE_VERSION(0, 1, 0),
            .pEngineName = "goop",
            .engineVersion = vk.VK_MAKE_VERSION(0, 1, 0),
            .apiVersion = vk.VK_API_VERSION_1_2,
        });
        const create_info = std.mem.zeroInit(vk.VkInstanceCreateInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO)),
            .pApplicationInfo = &app_info,
            .enabledExtensionCount = @as(u32, @intCast(extensions.len)),
            .ppEnabledExtensionNames = if (extensions.len == 0) null else extensions.ptr,
        });

        var handle: vk.VkInstance = null;
        try result(vk.vkCreateInstance(&create_info, null, &handle));
        if (handle == null) return error.InstanceCreationFailed;
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Instance) void {
        if (self.handle != null) vk.vkDestroyInstance(self.handle, null);
        self.* = undefined;
    }
};

pub const Device = struct {
    physical: vk.VkPhysicalDevice,
    handle: vk.VkDevice,
    graphics_queue: vk.VkQueue,
    present_queue: vk.VkQueue,
    graphics_family: u32,
    present_family: u32,
    supports_dual_source_blend: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        instance: Instance,
        surface: ?vk.VkSurfaceKHR,
    ) (Error || std.mem.Allocator.Error)!Device {
        var physical_count: u32 = 0;
        try result(vk.vkEnumeratePhysicalDevices(instance.handle, &physical_count, null));
        if (physical_count == 0) return error.NoPhysicalDevice;

        const physical_devices = try allocator.alloc(vk.VkPhysicalDevice, physical_count);
        defer allocator.free(physical_devices);
        try result(vk.vkEnumeratePhysicalDevices(
            instance.handle,
            &physical_count,
            physical_devices.ptr,
        ));

        var selected: ?Selection = null;
        for (physical_devices[0..physical_count]) |physical| {
            selected = try selectQueues(allocator, physical, surface);
            if (selected != null) break;
        }
        const choice = selected orelse return error.NoQueueFamily;

        const priority: f32 = 1;
        var queue_infos: [2]vk.VkDeviceQueueCreateInfo = undefined;
        queue_infos[0] = std.mem.zeroInit(vk.VkDeviceQueueCreateInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO)),
            .queueFamilyIndex = choice.graphics_family,
            .queueCount = 1,
            .pQueuePriorities = &priority,
        });
        var queue_info_count: u32 = 1;
        if (choice.present_family != choice.graphics_family) {
            queue_infos[1] = std.mem.zeroInit(vk.VkDeviceQueueCreateInfo, .{
                .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO)),
                .queueFamilyIndex = choice.present_family,
                .queueCount = 1,
                .pQueuePriorities = &priority,
            });
            queue_info_count = 2;
        }

        var available_features: vk.VkPhysicalDeviceFeatures = undefined;
        vk.vkGetPhysicalDeviceFeatures(choice.physical, &available_features);
        const enabled_features = std.mem.zeroInit(vk.VkPhysicalDeviceFeatures, .{
            .dualSrcBlend = available_features.dualSrcBlend,
        });

        const swapchain_extensions = [_][*c]const u8{
            vk.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
        };
        const extensions: []const [*c]const u8 = if (surface != null)
            &swapchain_extensions
        else
            &.{};
        const create_info = std.mem.zeroInit(vk.VkDeviceCreateInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO)),
            .queueCreateInfoCount = queue_info_count,
            .pQueueCreateInfos = &queue_infos,
            .enabledExtensionCount = @as(u32, @intCast(extensions.len)),
            .ppEnabledExtensionNames = if (extensions.len == 0) null else extensions.ptr,
            .pEnabledFeatures = &enabled_features,
        });

        var handle: vk.VkDevice = null;
        try result(vk.vkCreateDevice(choice.physical, &create_info, null, &handle));
        if (handle == null) return error.DeviceCreationFailed;
        errdefer vk.vkDestroyDevice(handle, null);

        var graphics_queue: vk.VkQueue = null;
        var present_queue: vk.VkQueue = null;
        vk.vkGetDeviceQueue(handle, choice.graphics_family, 0, &graphics_queue);
        vk.vkGetDeviceQueue(handle, choice.present_family, 0, &present_queue);

        return .{
            .physical = choice.physical,
            .handle = handle,
            .graphics_queue = graphics_queue,
            .present_queue = present_queue,
            .graphics_family = choice.graphics_family,
            .present_family = choice.present_family,
            .supports_dual_source_blend = available_features.dualSrcBlend == vk.VK_TRUE,
        };
    }

    pub fn waitIdle(self: *const Device) void {
        if (self.handle != null) _ = vk.vkDeviceWaitIdle(self.handle);
    }

    pub fn deinit(self: *Device) void {
        self.waitIdle();
        if (self.handle != null) vk.vkDestroyDevice(self.handle, null);
        self.* = undefined;
    }

    pub fn context(self: *const Device) Context {
        return .{
            .physical_device = self.physical,
            .device = self.handle,
            .graphics_queue = self.graphics_queue,
            .graphics_family = self.graphics_family,
            .supports_dual_source_blend = self.supports_dual_source_blend,
        };
    }
};

pub const Context = struct {
    physical_device: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    graphics_queue: vk.VkQueue,
    graphics_family: u32,
    supports_dual_source_blend: bool,
};

const Selection = struct {
    physical: vk.VkPhysicalDevice,
    graphics_family: u32,
    present_family: u32,
};

fn selectQueues(
    allocator: std.mem.Allocator,
    physical: vk.VkPhysicalDevice,
    surface: ?vk.VkSurfaceKHR,
) (Error || std.mem.Allocator.Error)!?Selection {
    var family_count: u32 = 0;
    vk.vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, null);
    if (family_count == 0) return null;

    const families = try allocator.alloc(vk.VkQueueFamilyProperties, family_count);
    defer allocator.free(families);
    vk.vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, families.ptr);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = if (surface == null) null else null;
    for (families[0..family_count], 0..) |family, index| {
        const family_index: u32 = @intCast(index);
        if (graphics_family == null and
            family.queueCount > 0 and
            family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT != 0)
        {
            graphics_family = family_index;
        }
        if (surface) |surface_handle| {
            var supported: vk.VkBool32 = vk.VK_FALSE;
            try result(vk.vkGetPhysicalDeviceSurfaceSupportKHR(
                physical,
                family_index,
                surface_handle,
                &supported,
            ));
            if (present_family == null and supported == vk.VK_TRUE) {
                present_family = family_index;
            }
        }
    }

    const graphics = graphics_family orelse return null;
    const present = if (surface == null) graphics else present_family orelse return null;
    return .{
        .physical = physical,
        .graphics_family = graphics,
        .present_family = present,
    };
}

pub fn result(code: vk.VkResult) Error!void {
    return switch (code) {
        vk.VK_SUCCESS => {},
        vk.VK_ERROR_OUT_OF_HOST_MEMORY => error.OutOfHostMemory,
        vk.VK_ERROR_OUT_OF_DEVICE_MEMORY => error.OutOfDeviceMemory,
        else => error.VulkanFailure,
    };
}

test "Vulkan context is graphics-only data" {
    try std.testing.expect(@sizeOf(Context) > 0);
    try std.testing.expect(!@hasField(Context, "surface"));
    try std.testing.expect(!@hasField(Context, "swapchain"));
}
