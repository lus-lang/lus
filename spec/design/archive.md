# Archives

`vector.archive` holds two kinds of tables. The codecs `gzip`, `deflate`, `zstd`, `brotli`, and `lz4` compress one stream of bytes. The containers `zip` and `tar` hold many named entries, which is what package bundles, release downloads, and uploaded files are. This note describes the containers.

## Functions

Each container table has four functions with the same shapes.

| Function | Result |
|---|---|
| `list(archive)` | An array of entry tables in archive order. |
| `read(archive, name [, max])` | The contents of one file as a vector, or `nil`. |
| `pack(entries [, options])` | A new archive as a vector. |
| `unpack(archive, directory [, options])` | The number of entries written under `directory`. |

An entry table has `name`, `kind` (`"file"`, `"directory"`, `"symlink"`, and for tar `"link"` and `"special"`), `size`, `mode`, `mtime` in seconds since the Unix epoch, `target` for a link, and for ZIP `method` and `compressed`. `pack` takes entries in the same shape, so a listing of one archive describes how to build another. A `.tar.gz` file is a tar archive inside the gzip codec, so tar has no compression option of its own.

## Sources

An archive is a string, a vector, or an open file. A file is read with positional reads from its start, which leave its position unchanged. `list` and `read` touch only the headers and the one entry they need. `unpack` streams each entry to disk in blocks. A program unpacks a download of several gigabytes without holding it in memory. Strings and vectors take the same code through a source that copies from memory.

## Formats

The readers and writers are written here over the ZIP application note and POSIX ustar and pax. `std.zip` reads only from a seekable file and extracts with policies of its own. `std.tar` hides the time field and the hard-link and device entries that `list` reports, so neither fits as the reader. Deflate comes from `std.compress.flate` and CRC-32 from `std.hash.Crc32`.

- **ZIP.** The reader finds the end of the central directory, follows ZIP64 records, and takes each entry's name, sizes, method, and Unix mode from the central directory, with the Unix timestamp field over the DOS date when both are there. Store and deflate are read. Encrypted entries and other methods raise. The writer stores names in UTF-8, writes Unix modes and the Unix timestamp field, and adds ZIP64 records only when a size, an offset, or the entry count needs them.
- **tar.** The reader takes ustar headers with their prefix field, pax records for `path`, `linkpath`, `size`, and `mtime`, and GNU long-name records. Base-256 numbers are read. An archive must end with a zero block, so a cut between two entries reads as truncated. The writer writes ustar headers and adds a pax record for any name, link target, size, or time that ustar cannot hold.

Names and link targets are read as text, with bytes that are not UTF-8 replaced by U+FFFD, since names in Lus are strings.

## Safety

`unpack` writes only inside its target directory. No option turns these rules off.

- **Names.** An entry name is split on `/`. A name that is absolute, starts with a drive letter, or holds a backslash, a NUL byte, or a `..` component raises. Empty and `.` components are dropped. `read` applies the same rule to its argument. `pack` refuses to write such names.
- **Links.** A symlink is created only when its target is relative, every `..` of the target comes before its other components, and the `..` components climb no higher than the directory of the link. Once the climb ends the target only descends, so it cannot pass through another link to a place above the target directory. Hard links, devices, and FIFOs raise.
- **No writes through links.** Every directory on the way to an entry is opened relative to its parent without following a symbolic link. An entry under a link, whether an earlier entry made the link or it was on disk before, raises. With `overwrite`, an existing file or link is removed and replaced, never written through.
- **Check first.** Every name, type, and link target is checked before the first write, so a hostile archive leaves the file system unchanged.
- **Limits.** `max` bounds the bytes written, 512 MiB by default as for the codecs. `entries` bounds the entry count, 10,000 by default. Sizes are counted from the bytes actually decompressed, never from the sizes the headers declare. A size that differs from its header raises. ZIP entries whose bytes overlap raise, which stops the bomb that points many central directory records at one compressed block. A nested archive is just a file, since `unpack` never opens the archives it writes.
- **Integrity.** ZIP local headers must repeat the name of their central directory record. Every entry's CRC-32 is checked. Tar header checksums are checked.
- **Modes.** Files get `0644`, or `0755` when the entry is executable. Directories get `0755`. Setuid, setgid, and sticky bits and owners are ignored.

A file that exists raises `file exists`. Directories that exist are merged. `options.overwrite` replaces files.

## Permissions

`unpack` requires `fs:write` for the target directory and for every path it creates. `list`, `read`, and `pack` work on values the program holds, so they require no permission. An open file was already opened under `fs:read`.

## Testing

The conformance suite reads archives that Python's zipfile and tarfile wrote in every layout, round-trips every field through `pack` and `list`, and unpacks hostile archives built by `tests/conformance/fixtures/archive/make.py`: traversal and absolute names, links that escape directly or through another link, writes through links made by the archive or found on disk, overlapping ZIP entries, headers that lie about sizes and checksums, and encrypted entries. The corrupt harness and the fuzz targets feed truncated and mutated archives to both readers.
