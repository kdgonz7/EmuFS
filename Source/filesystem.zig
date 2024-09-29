// Copyright (C) Kai D. Gonzalez, licensed under the MIT license.

const std = @import("std");

const Writer = std.io.GenericWriter;

const FileError = error{
    OutOfMemory,
    EndOfBuffer,
    EndOfFile,
    ContentBiggerThanContentCap,
    ClosedFile,
    InsufficientPermissionsForAppend,
    InsufficientPermissionsForRead,
};

const FilesError = error{
    OutOfMemory,
};

const GenError = error{};

const FSError = error{
    EntryNotFound,
    EntryNotAFile,
    EntryNotADirectory,
};

const Permission = enum(usize) {
    /// Allows for reads from a file.
    read = 1,

    /// Allows for writes to a file.
    write = 2,

    /// The created file permission, grants full write access
    /// until proper permissions set with setPermissions
    temporary_created = 3,

    /// No permissions. A deadlocked file
    none = 4,
};

const Permissions = struct {
    perm_array: std.AutoHashMap(Permission, usize),

    pub fn none(allocator: std.mem.Allocator) Permissions {
        const arr = std.AutoHashMap(Permission, usize).init(allocator);
        _ = arr;
    }
};

/// Files can hold content, and permissions, and their permissions can be set
/// with `.setFilePermissions`
const File = struct {
    name: []const u8,

    contents: []i8,
    size: usize = 0,
    capacity: usize = 0,

    stream_pos: usize = 0,

    permissions: usize,
    allocator: std.mem.Allocator,

    const Write = Writer(*File, FileError, appendWrite);
    const Reader = std.io.Reader(*File, FileError, read);

    /// Returns a new `File` struct with the name `name`, leaving the contents
    /// blank.
    pub fn createWithName(allocator: std.mem.Allocator, name: []const u8) File {
        return File{
            .contents = &[_]i8{},
            .name = name,
            .permissions = @intFromEnum(Permission.temporary_created),
            .allocator = allocator,
        };
    }

    /// Allocates space for `how_much` bytes.
    pub fn allocateContentMemory(self: *File, how_much: usize) FileError!void {
        if (how_much == 0) {
            return;
        }

        if (self.capacity == 0) {
            self.contents = try self.allocator.alloc(i8, how_much);
        } else {
            self.contents = try self.allocator.realloc(self.contents, self.capacity + how_much);
        }

        self.capacity += how_much;
    }

    /// Appends a `[]const u8` into the file's contents.
    pub fn appendU8String(self: *File, slice: []const u8) FileError!void {
        if (slice.len == 0) {
            return;
        }

        // if our permissions aren't temporary, and we don't have write
        // permissions, we can't add to the file
        if (self.permissions != @intFromEnum(Permission.temporary_created) and self.permissions & @intFromEnum(Permission.write) == 0) {
            return error.InsufficientPermissionsForAppend;
        }

        try self.allocateContentMemory(slice.len);

        for (0..slice.len) |i| {
            if (self.size >= self.contents.len) {
                return error.ContentBiggerThanContentCap;
            }

            self.contents[self.size] = @intCast(slice[i]);
            self.size += 1;
        }
    }

    /// function signature for `GenericWriter`.
    pub fn appendWrite(self: *File, data: []const u8) FileError!usize {
        const old_size = self.size;

        try self.appendU8String(data);

        return self.size - old_size;
    }

    /// The writer interface for the `File` struct.
    pub fn writer(self: *File) Write {
        return .{ .context = self };
    }

    /// Reads the file content from `stream_pos` into
    /// `buffer`. Can return EofError
    pub fn read(self: *File, buffer: []u8) FileError!usize {
        if (!self.hasPermission(Permission.read)) {
            return error.InsufficientPermissionsForRead;
        }
        const position = self.stream_pos;

        if (position + buffer.len > self.capacity) {
            return error.EndOfFile;
        }

        for (0..buffer.len) |i| {
            buffer[i] = @intCast(self.contents[self.stream_pos]);
            self.stream_pos += 1;
        }

        return self.stream_pos - position;
    }

    pub fn reader(self: *File) Reader {
        return .{ .context = self };
    }

    pub fn asEntry(self: *File) Entry {
        return Entry{ .file = self };
    }

    /// Checks if the current file has the the permission `given`.
    pub fn hasPermission(self: *const File, given: Permission) bool {
        return self.permissions & @intFromEnum(given) > 0;
    }

    /// Sets the file's permissions
    pub fn setPermission(self: *File, perms: usize) void {
        self.permissions = perms;
    }

    /// Deallocates the file's contents.
    pub fn deinit(self: *File) void {
        self.allocator.free(self.contents);
    }
};

const Entries = struct {
    entry_list: std.StringHashMap(*Entry),
    allocator: std.mem.Allocator,

    /// Creates the wrapper around the string hash-map used
    /// for O(1) file lookup
    pub fn create(allocator: std.mem.Allocator) Entries {
        return Entries{
            .allocator = allocator,
            .entry_list = std.StringHashMap(*Entry).init(allocator),
        };
    }

    /// O(1) insertion, worst case O(n)
    pub fn newEntry(self: *Entries, name: []const u8, with_struct: *Entry) FilesError!void {
        try self.entry_list.put(name, with_struct);
    }

    /// O(1)
    pub fn findEntry(self: *Entries, name: []const u8) FSError!*Entry {
        const potential_file = self.entry_list.get(name);

        if (potential_file) |file| {
            return file;
        }

        return error.EntryNotFound;
    }
};

const EntryTag = enum {
    file,
    dir,
};

/// An entry represents an entity in the filesystem.
/// Functions like `isDirectory()` and `asFile()`
/// can convert the entry into the designated type.
const Entry = union(EntryTag) {
    file: *File,
    dir: *Directory,

    pub fn isDirectory(self: *const Entry) bool {
        return switch (self.*) {
            .file => false,
            .dir => true,
        };
    }

    pub fn isFile(self: *const Entry) bool {
        return !self.isDirectory();
    }

    pub fn asFile(self: *Entry) !*File {
        if (!self.isDirectory()) {
            return self.file;
        } else {
            return error.EntryNotAFile;
        }
    }

    pub fn asDirectory(self: *Entry) !*Directory {
        if (self.isDirectory()) {
            return self.dir;
        } else {
            return error.EntryNotADirectory;
        }
    }
};

const Directory = struct {
    name: []const u8,
    entries: Entries,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, name: []const u8) Directory {
        return Directory{
            .name = name,
            .entries = Entries.create(allocator),
            .allocator = allocator,
        };
    }

    pub fn asEntry(self: *Directory) Entry {
        return Entry{ .dir = self };
    }
};

// const Generator = struct {
//     root: *Entry,
//     buffer: std.fs.File.Writer,
//     allocator: std.mem.Allocator,

//     pub fn createGenerator(allocator: std.mem.Allocator, root: *Entry, writer: std.fs.File.Writer) Generator {
//         return Generator{
//             .root = root,
//             .buffer = writer,
//             .allocator = allocator,
//         };
//     }

//     pub fn generateFromNode(self: *Generator, node: *Entry) !void {
//         switch (node.*) {
//             .file => |file| {
//                 // 0xFF represents a file (EMU_FILE)
//                 // EMU_FILE NAME_LEN NAME PERMISSIONS SIZE CONTENTS
//                 try self.buffer.writeInt(i64, 0xFF, std.builtin.Endian.little);
//                 try self.buffer.writeInt(usize, file.name.len, std.builtin.Endian.little);
//                 try self.buffer.writeAll(file.name);

//                 try self.buffer.writeInt(usize, file.permissions, std.builtin.Endian.little);
//                 try self.buffer.writeInt(usize, file.size, std.builtin.Endian.little);

//                 for (file.contents) |byt| {
//                     try self.buffer.writeInt(i8, byt, std.builtin.Endian.little);
//                 }
//             },
//             .dir => |dir| {
//                 // 0xAF represents a directory
//                 // 0xAB ends a directory
//                 // EMU_DIRECTORY NAME_LEN NAME <SUB> EMU_END_DIRECTORY

//                 try self.buffer.writeInt(i64, 0xAF, std.builtin.Endian.little);
//                 try self.buffer.writeInt(usize, dir.name.len, std.builtin.Endian.little);
//                 try self.buffer.writeAll(dir.name);
//                 var it = dir.entries.entry_list.iterator();
//                 while (it.next()) |ent| {
//                     try self.generateFromNode(ent.value_ptr.*);
//                 }

//                 try self.buffer.writeInt(i64, 0xAB, std.builtin.Endian.little);
//             },
//         }
//     }

//     pub fn generateEmuDiskIntoBuffer(self: *Generator) !void {
//         try self.generateFromNode(self.root);
//     }

//     pub fn readEmuDisk(self: *Generator, disk: std.fs.File) !Entry {
//         var i: usize = 0;
//         var size = try disk.getEndPos();

//         var reader = disk.reader();

//         while (i < size) {
//             var byte = try reader.readInt(i64, std.builtin.Endian.little);

//             switch (byte) {
//                 0xFF => { //file

//                 },
//             }
//             i += 1;
//         }
//     }
// };

test "creating a simple file and appending a 5-length string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const file_arena = arena.allocator();
    defer arena.deinit();

    var f = File.createWithName(file_arena, "my_file.txt");
    try f.appendU8String("hello");

    try std.testing.expect(f.hasPermission(Permission.temporary_created));
    try std.testing.expect(std.mem.eql(i8, f.contents, &[_]i8{ 104, 101, 108, 108, 111 }));
    try std.testing.expect(f.size == 5);
    try std.testing.expect(f.capacity == 5);
    try std.testing.expect(f.permissions == @intFromEnum(Permission.temporary_created));
}

test "checking for bitset permissions" {
    const read_write =
        @intFromEnum(Permission.read) | @intFromEnum(Permission.write);

    try std.testing.expect(read_write & @intFromEnum(Permission.read) == 1);
    try std.testing.expect(read_write & @intFromEnum(Permission.write) == 2);
    try std.testing.expect(read_write & @intFromEnum(Permission.none) == 0);
}

test "set permissions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const file_arena = arena.allocator();
    defer arena.deinit();

    var f = File.createWithName(file_arena, "my_file.txt");
    f.setPermission(@intFromEnum(Permission.write) | @intFromEnum(Permission.read));

    try std.testing.expectEqual(f.hasPermission(Permission.write), true);
    try std.testing.expectEqual(f.hasPermission(Permission.read), true);
    try std.testing.expectEqual(f.hasPermission(Permission.temporary_created), true);
    try std.testing.expectEqual(f.hasPermission(Permission.none), false);
}

test "trying to write to a read-only file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const file_arena = arena.allocator();
    defer arena.deinit();

    var f = File.createWithName(file_arena, "my_file.txt");
    f.setPermission(@intFromEnum(Permission.read));

    try std.testing.expectError(error.InsufficientPermissionsForAppend, f.appendU8String("should error"));
}

test "multiple writes to one file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const file_arena = arena.allocator();
    defer arena.deinit();

    var our_file = File.createWithName(file_arena, "a.txt");
    our_file.setPermission(@intFromEnum(Permission.write)); // w

    // Fixed a bug where multiple writes would cause a misalignment in capacity
    // and size
    try our_file.appendU8String("a");
    try our_file.appendU8String("b");
    try our_file.appendU8String("c");
    try our_file.appendU8String("\n");

    try std.testing.expectEqual(4, our_file.size);
    try std.testing.expectEqual(4, our_file.capacity);

    try std.testing.expectEqual('a', our_file.contents[0]);
    try std.testing.expectEqual('b', our_file.contents[1]);
    try std.testing.expectEqual('c', our_file.contents[2]);
    try std.testing.expectEqual('\n', our_file.contents[3]);

    try std.testing.expectEqual(@intFromEnum(Permission.write), our_file.permissions);
}

test "empty writes" {
    var our_file = File.createWithName(std.testing.allocator, "a.txt");
    our_file.setPermission(@intFromEnum(Permission.write)); // w
    defer our_file.deinit();

    try our_file.appendU8String("");
    try our_file.appendU8String("");
    try our_file.appendU8String("");
    try our_file.appendU8String("");
}

test "using a file writer instead of appendU8String" {
    var our_file = File.createWithName(std.testing.allocator, "a.txt");
    our_file.setPermission(@intFromEnum(Permission.write)); // w
    defer our_file.deinit();

    const writer = our_file.writer();

    _ = try writer.write("hello, world!");

    try std.testing.expectEqual(our_file.size, 13);
    try std.testing.expectEqual(our_file.capacity, 13);
}

test "reading bytes from a file" {
    var our_file = File.createWithName(std.testing.allocator, "a.txt");
    our_file.setPermission(@intFromEnum(Permission.write) | @intFromEnum(Permission.read)); // w
    defer our_file.deinit();

    _ = try our_file.writer().write("abc");

    var str = our_file.reader();

    try std.testing.expectEqual('a', str.readByteSigned());
    try std.testing.expectEqual('b', str.readByteSigned());
    try std.testing.expectEqual('c', str.readByteSigned());
    try std.testing.expectError(error.EndOfFile, str.readByteSigned());

    our_file.setPermission(@intFromEnum(Permission.write)); // we no longer can read this file

    try std.testing.expectError(error.InsufficientPermissionsForRead, str.readByte());
}

test "reading integers from a file using the provided writer/readers" {
    var our_file = File.createWithName(std.testing.allocator, "a.txt");
    our_file.setPermission(@intFromEnum(Permission.write) | @intFromEnum(Permission.read)); // w
    defer our_file.deinit();

    _ = try our_file.writer().writeInt(i32, 325, std.builtin.Endian.little);
    _ = try our_file.writer().writeByte('a');

    const read_byte = try our_file.reader().readInt(i32, std.builtin.Endian.little);
    const next_byte = try our_file.reader().readByte();

    try std.testing.expectEqual(325, read_byte);
    try std.testing.expectEqual('a', next_byte);
}

test "creating a list of files using an allocator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const file_arena = arena.allocator();
    defer arena.deinit();

    var our_file = File.createWithName(file_arena, "a.txt");
    our_file.setPermission(@intFromEnum(Permission.read) | @intFromEnum(Permission.write)); // rw

    var another_file = File.createWithName(file_arena, "b.txt");

    another_file.setPermission(@intFromEnum(Permission.read) | @intFromEnum(Permission.write)); // rw

    try our_file.appendU8String("hello,");
    try another_file.appendU8String("abc");

    var files = Entries.create(file_arena);

    var ourfile_as_entry = our_file.asEntry();
    var another_file_entry = another_file.asEntry();

    try files.newEntry("a.txt", &ourfile_as_entry);
    try files.newEntry("b.txt", &another_file_entry);

    // testing
    try std.testing.expectError(error.EntryNotFound, files.findEntry("a.fafftxt"));

    const f_entry = try files.findEntry("a.txt");
    const f = try f_entry.asFile();

    try std.testing.expectEqual(f.*.contents[0], 104);
    try std.testing.expectEqual(f.*.contents[1], 101);
    try std.testing.expectEqual(f.*.contents[2], 108);
    try std.testing.expectEqual(f.*.contents[3], 108);
    try std.testing.expectEqual(f.*.contents[4], 111);
    try std.testing.expectEqual(f.*.contents[5], 44);

    try f.*.appendU8String(" world"); // append ` world`, creating `hello, world`

    try std.testing.expectEqual(f.*.contents[0], 104);
    try std.testing.expectEqual(f.*.contents[1], 101);
    try std.testing.expectEqual(f.*.contents[2], 108);
    try std.testing.expectEqual(f.*.contents[3], 108);
    try std.testing.expectEqual(f.*.contents[4], 111);
    try std.testing.expectEqual(f.*.contents[5], 44);
    try std.testing.expectEqual(f.*.contents[6], 32);
    try std.testing.expectEqual(f.*.contents[7], 119);
    try std.testing.expectEqual(f.*.contents[8], 111);
    try std.testing.expectEqual(f.*.contents[9], 114);
    try std.testing.expectEqual(f.*.contents[10], 108);
    try std.testing.expectEqual(f.*.contents[11], 100);

    const other_file = try (try files.findEntry("b.txt")).asFile();

    try std.testing.expectEqual(other_file.contents[0], 97); // a
    try std.testing.expectEqual(other_file.contents[1], 98); // b
    try std.testing.expectEqual(other_file.contents[2], 99); // c
}

test "entry unwrapping" {
    var ent = File.createWithName(std.testing.allocator, "hello.txt");
    defer ent.deinit();

    var as_entry = ent.asEntry();

    try std.testing.expectEqual(true, !as_entry.isDirectory());
    try std.testing.expectError(error.EntryNotADirectory, as_entry.asDirectory());
}

test "creating a directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const file_arena = arena.allocator();
    defer arena.deinit();

    var f1 = File.createWithName(file_arena, "");
    var f1_as_entry = f1.asEntry();

    var dir = Directory.create(file_arena, "my directory");
    try dir.entries.newEntry("a.txt", &f1_as_entry);

    const entity = try dir.entries.findEntry("a.txt");

    try std.testing.expectEqual(true, !entity.isDirectory());
    try std.testing.expectEqual(true, entity.isFile());
}

test "iterating a single directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const file_arena = arena.allocator();
    defer arena.deinit();

    var f1 = File.createWithName(file_arena, "");
    var f2 = File.createWithName(file_arena, "");
    var f1_as_entry = f1.asEntry();
    var f2_as_entry = f2.asEntry();

    var dir = Directory.create(file_arena, "directory with empty files");

    try dir.entries.newEntry("a.txt", &f1_as_entry);
    try dir.entries.newEntry("b.txt", &f2_as_entry);

    var it = dir.entries.entry_list.iterator();

    while (it.next()) |entity| {
        try std.testing.expectEqual(true, entity.value_ptr.*.isFile());
    }
}

test "generator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const file_arena = arena.allocator();
    defer arena.deinit();

    var f1 = File.createWithName(file_arena, "a.txt");
    var f2 = File.createWithName(file_arena, "b.txt");

    _ = try f1.writer().write("hello, world!");

    var f1_as_entry = f1.asEntry();
    var f2_as_entry = f2.asEntry();

    var dir = Directory.create(file_arena, "my test directory");

    try dir.entries.newEntry("a.txt", &f1_as_entry);
    try dir.entries.newEntry("b.txt", &f2_as_entry);

    var bytes = try std.fs.cwd().createFile("output.efs", .{
        .read = true,
    });
    defer bytes.close();

    var directory_ent = dir.asEntry();
    var gen = Generator.createGenerator(file_arena, &directory_ent, bytes.writer());

    try gen.generateEmuDiskIntoBuffer();
}
