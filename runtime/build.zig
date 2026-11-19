const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lus_mod = b.createModule(.{
        .root_source_file = b.path("src/lus.zig"),
        .target = target,
        .optimize = optimize,
    });
    lus_mod.linkLibrary(compressionLibrary(b, target));

    const exe = b.addExecutable(.{
        .name = "lus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lus", .module = lus_mod }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Run the lus interpreter").dependOn(&run.step);

    const unit = b.addTest(.{ .root_module = lus_mod });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit).step);
}

/// Builds the vendored Brotli and Zstandard C sources used by
/// `vector.archive`. The upstream libraries are mature and fuzzed, so they
/// always build optimized and without the undefined behavior sanitizer,
/// whatever mode the runtime itself uses.
fn compressionLibrary(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "lus_compress",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    const flags: []const []const u8 = &.{"-fno-sanitize=undefined"};

    const brotli = b.dependency("brotli", .{});
    lib.root_module.addIncludePath(brotli.path("c/include"));
    lib.root_module.addCSourceFiles(.{
        .root = brotli.path("c"),
        .files = &.{
            "common/constants.c",         "common/context.c",
            "common/dictionary.c",        "common/platform.c",
            "common/shared_dictionary.c", "common/transform.c",
            "dec/bit_reader.c",           "dec/decode.c",
            "dec/huffman.c",              "dec/state.c",
            "enc/backward_references.c",  "enc/backward_references_hq.c",
            "enc/bit_cost.c",             "enc/block_splitter.c",
            "enc/brotli_bit_stream.c",    "enc/cluster.c",
            "enc/command.c",              "enc/compound_dictionary.c",
            "enc/compress_fragment.c",    "enc/compress_fragment_two_pass.c",
            "enc/dictionary_hash.c",      "enc/encode.c",
            "enc/encoder_dict.c",         "enc/entropy_encode.c",
            "enc/fast_log.c",             "enc/histogram.c",
            "enc/literal_cost.c",         "enc/memory.c",
            "enc/metablock.c",            "enc/static_dict.c",
            "enc/utf8_util.c",
        },
        .flags = flags,
    });

    // Zstandard builds without its x86 assembly decoder loop, so one
    // source list serves every target.
    const zstd = b.dependency("zstd", .{});
    lib.root_module.addCMacro("ZSTD_DISABLE_ASM", "1");
    lib.root_module.addCMacro("ZSTD_MULTITHREAD_SUPPORT_DEFAULT", "0");
    lib.root_module.addIncludePath(zstd.path("lib"));
    lib.root_module.addCSourceFiles(.{
        .root = zstd.path("lib"),
        .files = &.{
            "common/debug.c",                      "common/entropy_common.c",
            "common/error_private.c",              "common/fse_decompress.c",
            "common/pool.c",                       "common/threading.c",
            "common/xxhash.c",                     "common/zstd_common.c",
            "compress/fse_compress.c",             "compress/hist.c",
            "compress/huf_compress.c",             "compress/zstd_compress.c",
            "compress/zstd_compress_literals.c",   "compress/zstd_compress_sequences.c",
            "compress/zstd_compress_superblock.c", "compress/zstd_double_fast.c",
            "compress/zstd_fast.c",                "compress/zstd_lazy.c",
            "compress/zstd_ldm.c",                 "compress/zstd_opt.c",
            "compress/zstd_preSplit.c",            "compress/zstdmt_compress.c",
            "decompress/huf_decompress.c",         "decompress/zstd_ddict.c",
            "decompress/zstd_decompress.c",        "decompress/zstd_decompress_block.c",
        },
        .flags = flags,
    });
    return lib;
}
