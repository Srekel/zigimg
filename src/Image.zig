const AllImageFormats = @import("formats/all.zig");
const Allocator = std.mem.Allocator;
const Colorf32 = color.Colorf32;
const PixelStorage = color.PixelStorage;
const FormatInterface = @import("format_interface.zig").FormatInterface;
const PixelFormat = @import("pixel_format.zig").PixelFormat;
const color = @import("color.zig");
const io = std.io;
const std = @import("std");
const utils = @import("utils.zig");

pub const Error = error{
    Unsupported,
};

pub const ReadError = Error ||
    std.mem.Allocator.Error ||
    utils.StructReadError ||
    std.io.StreamSource.SeekError ||
    std.io.StreamSource.GetSeekPosError ||
    error{ EndOfStream, StreamTooLong, InvalidData };

pub const WriteError = Error ||
    std.mem.Allocator.Error ||
    std.io.StreamSource.WriteError ||
    std.io.StreamSource.SeekError ||
    std.io.StreamSource.GetSeekPosError ||
    std.fs.File.OpenError ||
    error{InvalidData};

pub const Format = enum {
    bmp,
    jpg,
    pbm,
    pcx,
    pgm,
    png,
    ppm,
    qoi,
    tga,
};

pub const Stream = io.StreamSource;

pub const EncoderOptions = AllImageFormats.ImageEncoderOptions;

pub const AnimationLoopInfinite = -1;

pub const AnimationFrame = struct {
    pixels: PixelStorage,
    duration: f32,
};

pub const Animation = struct {
    frames: std.ArrayListUnmanaged(AnimationFrame),
    loop_count: i32 = AnimationLoopInfinite,

    pub fn deinit(self: *Animation, allocator: std.mem.Allocator) void {
        for (self.frames.items) |frame| {
            frame.pixels.deinit(allocator);
        }

        self.frames.deinit(allocator);
    }
};

pub const Data = union(enum) {
    empty: void,
    image: PixelStorage,
    animation: Animation,

    pub fn deinit(self: *Data, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .empty => {},
            .image => |image| {
                image.deinit(allocator);
            },
            .animation => |*animation| {
                animation.deinit(allocator);
            },
        }
    }
};

/// Format-independant image
allocator: Allocator = undefined,
width: usize = 0,
height: usize = 0,
data: Data = .{ .empty = void{} },

const Self = @This();

const FormatInteraceFnType = fn () FormatInterface;
const all_interface_funcs = blk: {
    const allFormatDecls = std.meta.declarations(AllImageFormats);
    var result: [allFormatDecls.len]FormatInteraceFnType = undefined;
    var index: usize = 0;
    for (allFormatDecls) |decl| {
        const decl_value = @field(AllImageFormats, decl.name);
        const entry_type = @TypeOf(decl_value);
        if (entry_type == type) {
            const entryTypeInfo = @typeInfo(decl_value);
            if (entryTypeInfo == .Struct) {
                for (entryTypeInfo.Struct.decls) |structEntry| {
                    if (std.mem.eql(u8, structEntry.name, "formatInterface")) {
                        result[index] = @field(decl_value, structEntry.name);
                        index += 1;
                        break;
                    }
                }
            }
        }
    }

    break :blk result[0..index];
};

/// Init an empty image with no pixel data
pub fn init(allocator: Allocator) Self {
    return Self{
        .allocator = allocator,
    };
}

/// Deinit the image
pub fn deinit(self: *Self) void {
    self.data.deinit(self.allocator);
}

/// Load an image from a file path
pub fn fromFilePath(allocator: Allocator, file_path: []const u8) !Self {
    var file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    return fromFile(allocator, &file);
}

/// Load an image from a standard library std.fs.File
pub fn fromFile(allocator: Allocator, file: *std.fs.File) !Self {
    var stream_source = io.StreamSource{ .file = file.* };
    return internalRead(allocator, &stream_source);
}

/// Load an image from a memory buffer
pub fn fromMemory(allocator: Allocator, buffer: []const u8) !Self {
    var stream_source = io.StreamSource{ .const_buffer = io.fixedBufferStream(buffer) };
    return internalRead(allocator, &stream_source);
}

/// Create a pixel surface from scratch
pub fn create(allocator: Allocator, width: usize, height: usize, pixel_format: PixelFormat) !Self {
    var result = Self{
        .allocator = allocator,
        .width = width,
        .height = height,
        .data = .{
            .image = try PixelStorage.init(allocator, pixel_format, width * height),
        },
    };

    return result;
}

/// Return the pixel format of the image
pub fn pixelFormat(self: Self) ?PixelFormat {
    return switch (self.data) {
        .empty => {
            return null;
        },
        .image => |image| {
            return std.meta.activeTag(image);
        },
        .animation => |animation| {
            if (animation.frames.items.len > 0) {
                return std.meta.activeTag(animation.frames.items[0].pixels);
            }

            return null;
        },
    };
}

/// Return the pixel data as a const byte slice. In case of an animation, it return the pixel data of the first frame.
pub fn rawBytes(self: Self) []const u8 {
    return switch (self.data) {
        .image => |image| {
            return image.asBytes();
        },
        .animation => |animation| {
            if (animation.frames.items.len > 0) {
                return animation.frames.items[0].pixels.asBytes();
            }

            return &[_]u8{};
        },
        else => {
            return &[_]u8{};
        },
    };
}

/// Return the byte size of a row in the image
pub fn rowByteSize(self: Self) usize {
    return self.imageByteSize() / self.height;
}

/// Return the byte size of the whole image
pub fn imageByteSize(self: Self) usize {
    return self.rawBytes().len;
}

/// Is this image is an animation?
pub fn isAnimation(self: Self) bool {
    return switch (self.data) {
        .animation => true,
        else => false,
    };
}

/// Write the image to an image format to the specified path
pub fn writeToFilePath(self: Self, file_path: []const u8, image_format: Format, encoder_options: EncoderOptions) WriteError!void {
    if (self.data == .empty) {
        return WriteError.InvalidData;
    }

    var file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    try self.writeToFile(&file, image_format, encoder_options);
}

/// Write the image to an image format to the specified std.fs.File
pub fn writeToFile(self: Self, file: *std.fs.File, image_format: Format, encoder_options: EncoderOptions) WriteError!void {
    var stream_source = io.StreamSource{ .file = file.* };

    try self.internalWrite(&stream_source, image_format, encoder_options);
}

/// Write the image to an image format in a memory buffer. The memory buffer is not grown
/// for you so make sure you pass a large enough buffer.
pub fn writeToMemory(self: Self, write_buffer: []u8, image_format: Format, encoder_options: EncoderOptions) WriteError![]u8 {
    var stream_source = io.StreamSource{ .buffer = std.io.fixedBufferStream(write_buffer) };

    try self.internalWrite(&stream_source, image_format, encoder_options);

    return stream_source.buffer.getWritten();
}

/// Iterate the pixel in pixel-format agnostic way. In the case of an animation, it returns an iterator for the first frame. The iterator is read-only.
pub fn iterator(self: Self) color.PixelStorageIterator {
    return switch (self.data) {
        .image => |*image| {
            return color.PixelStorageIterator.init(image);
        },
        .animation => |animation| {
            if (animation.frames.items.len > 0) {
                return color.PixelStorageIterator.init(&animation.frames.items[0].pixels);
            }

            return color.PixelStorageIterator.initNull();
        },
        else => {
            return color.PixelStorageIterator.initNull();
        },
    };
}

fn internalRead(allocator: Allocator, stream: *Stream) !Self {
    const format_interface = try findImageInterfaceFromStream(stream);

    try stream.seekTo(0);

    return try format_interface.readImage(allocator, stream);
}

fn internalWrite(self: Self, stream: *Stream, image_format: Format, encoder_options: EncoderOptions) WriteError!void {
    if (self.data == .empty) {
        return WriteError.InvalidData;
    }

    var format_interface = try findImageInterfaceFromImageFormat(image_format);

    try format_interface.writeImage(self.allocator, stream, self, encoder_options);
}

fn findImageInterfaceFromStream(stream: *Stream) !FormatInterface {
    for (all_interface_funcs) |intefaceFn| {
        const formatInterface = intefaceFn();

        try stream.seekTo(0);
        const found = try formatInterface.formatDetect(stream);
        if (found) {
            return formatInterface;
        }
    }

    return Error.Unsupported;
}

fn findImageInterfaceFromImageFormat(image_format: Format) !FormatInterface {
    for (all_interface_funcs) |interface_fn| {
        const format_interface = interface_fn();

        if (format_interface.format() == image_format) {
            return format_interface;
        }
    }

    return Error.Unsupported;
}
