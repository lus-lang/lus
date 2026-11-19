// A small WASI preview 1 host written for lus.wasm. It implements the
// calls the runtime imports: standard streams captured into JavaScript
// callbacks, an in-memory file system with "/" as the only preopened
// directory, environment variables, clocks, randomness, and sleeping.
// Every other call returns ENOSYS.

import { MemNode, splitPath } from "./memfs.js";

const E = {
  SUCCESS: 0,
  ACCES: 2,
  BADF: 8,
  EXIST: 20,
  INVAL: 28,
  IO: 29,
  ISDIR: 31,
  NAMETOOLONG: 37,
  NOENT: 44,
  NOSYS: 52,
  NOTDIR: 54,
  NOTEMPTY: 55,
  NOTSUP: 58,
  PERM: 63,
  SPIPE: 70,
};

const FILETYPE = { CHAR: 2, DIRECTORY: 3, REGULAR: 4 };
const OFLAGS = { CREAT: 1, DIRECTORY: 2, EXCL: 4, TRUNC: 8 };
const FDFLAGS = { APPEND: 1 };
const RIGHTS_ALL = 0x1fffffffn;
const READ_RIGHTS = (1n << 1n) | (1n << 14n); // fd_read, path_open bits
const WRITE_RIGHTS = 1n << 6n; // fd_write

/** Thrown by proc_exit. The instance is unusable afterwards. */
export class WasiExit extends Error {
  constructor(code) {
    super(`exit ${code}`);
    this.code = code;
  }
}

const decoder = new TextDecoder();
const encoder = new TextEncoder();

function sleepMs(ms) {
  if (ms <= 0) return;
  // Atomics.wait blocks without spinning where it is allowed (Node and
  // workers). A browser main thread falls back to a busy wait.
  try {
    const cell = new Int32Array(new SharedArrayBuffer(4));
    Atomics.wait(cell, 0, 0, ms);
    return;
  } catch {
    const end = performance.now() + ms;
    while (performance.now() < end) {
      // Busy wait.
    }
  }
}

export class Wasi {
  /**
   * @param {object} options
   * @param {import("./memfs.js").MemFS} options.fs
   * @param {() => Record<string, string>} [options.env] Read at each environment query.
   * @param {(bytes: Uint8Array) => void} options.stdout
   * @param {(bytes: Uint8Array) => void} options.stderr
   * @param {() => Uint8Array | null} [options.stdin]
   */
  constructor(options) {
    this.fs = options.fs;
    this.env = options.env ?? (() => ({}));
    this.stdout = options.stdout;
    this.stderr = options.stderr;
    this.stdin = options.stdin ?? (() => null);
    this.memory = null;
    this.start = performance.now();
    this.fds = new Map();
    this.fds.set(0, { kind: "stdin" });
    this.fds.set(1, { kind: "stdout" });
    this.fds.set(2, { kind: "stderr" });
    this.fds.set(3, { kind: "node", node: this.fs.root, preopen: "/", pos: 0 });
    this.nextFd = 4;
    this.imports = this.makeImports();
  }

  bind(memory) {
    this.memory = memory;
  }

  view() {
    return new DataView(this.memory.buffer);
  }

  bytes(ptr, len) {
    return new Uint8Array(this.memory.buffer, ptr, len);
  }

  string(ptr, len) {
    return decoder.decode(this.bytes(ptr, len));
  }

  /** Resolves `path` relative to directory descriptor `fd`. */
  resolve(fd, path) {
    const entry = this.fds.get(fd);
    if (!entry || entry.kind !== "node" || entry.node.kind !== "dir") return { error: E.BADF };
    // Absolute paths resolve from the root, since "/" is the only preopen.
    const base = path.startsWith("/") ? this.fs.root : entry.node;
    const parts = splitPath(path);
    let dir = base;
    for (let i = 0; i < parts.length - 1; i++) {
      const next = dir.entries.get(parts[i]);
      if (!next) return { error: E.NOENT };
      if (next.kind !== "dir") return { error: E.NOTDIR };
      dir = next;
    }
    const name = parts.length ? parts[parts.length - 1] : null;
    const node = name === null ? base : dir.entries.get(name) ?? null;
    return { dir: name === null ? null : dir, name, node };
  }

  writeFilestat(ptr, node) {
    const v = this.view();
    v.setBigUint64(ptr, 0n, true);
    v.setBigUint64(ptr + 8, node.ino, true);
    v.setUint8(ptr + 16, node.kind === "dir" ? FILETYPE.DIRECTORY : FILETYPE.REGULAR);
    v.setBigUint64(ptr + 24, 1n, true);
    v.setBigUint64(ptr + 32, BigInt(node.kind === "dir" ? 0 : node.size), true);
    v.setBigUint64(ptr + 40, node.mtime, true);
    v.setBigUint64(ptr + 48, node.mtime, true);
    v.setBigUint64(ptr + 56, node.mtime, true);
  }

  gatherIovs(iovs, count) {
    const v = this.view();
    const parts = [];
    for (let i = 0; i < count; i++) {
      const ptr = v.getUint32(iovs + i * 8, true);
      const len = v.getUint32(iovs + i * 8 + 4, true);
      parts.push([ptr, len]);
    }
    return parts;
  }

  makeImports() {
    const self = this;
    const wasi = {
      args_sizes_get(argc, size) {
        const v = self.view();
        v.setUint32(argc, 0, true);
        v.setUint32(size, 0, true);
        return E.SUCCESS;
      },
      args_get() {
        return E.SUCCESS;
      },
      environ_sizes_get(countPtr, sizePtr) {
        const entries = Object.entries(self.env());
        let size = 0;
        for (const [k, val] of entries) size += encoder.encode(`${k}=${val}`).length + 1;
        const v = self.view();
        v.setUint32(countPtr, entries.length, true);
        v.setUint32(sizePtr, size, true);
        return E.SUCCESS;
      },
      environ_get(environPtr, bufPtr) {
        const v = self.view();
        let offset = bufPtr;
        let i = 0;
        for (const [k, val] of Object.entries(self.env())) {
          const bytes = encoder.encode(`${k}=${val}\0`);
          self.bytes(offset, bytes.length).set(bytes);
          v.setUint32(environPtr + i * 4, offset, true);
          offset += bytes.length;
          i++;
        }
        return E.SUCCESS;
      },
      clock_res_get(_id, resPtr) {
        self.view().setBigUint64(resPtr, 1000n, true);
        return E.SUCCESS;
      },
      clock_time_get(id, _precision, timePtr) {
        let ns;
        if (id === 0) {
          ns = BigInt(Date.now()) * 1_000_000n;
        } else {
          ns = BigInt(Math.round((performance.now() - (id === 1 ? 0 : self.start)) * 1e6));
        }
        self.view().setBigUint64(timePtr, ns, true);
        return E.SUCCESS;
      },
      random_get(ptr, len) {
        const out = self.bytes(ptr, len);
        for (let i = 0; i < len; i += 65536) {
          crypto.getRandomValues(out.subarray(i, Math.min(len, i + 65536)));
        }
        return E.SUCCESS;
      },
      proc_exit(code) {
        throw new WasiExit(code);
      },
      sched_yield() {
        return E.SUCCESS;
      },
      poll_oneoff(inPtr, outPtr, nsubs, neventsPtr) {
        const v = self.view();
        let wait = 0;
        let events = 0;
        for (let i = 0; i < nsubs; i++) {
          const sub = inPtr + i * 48;
          const userdata = v.getBigUint64(sub, true);
          const tag = v.getUint8(sub + 8);
          let error = E.SUCCESS;
          if (tag === 0) {
            const clock = v.getUint32(sub + 16, true);
            let timeout = Number(v.getBigUint64(sub + 24, true)) / 1e6;
            const absolute = (v.getUint16(sub + 40, true) & 1) !== 0;
            if (absolute) {
              const current = clock === 0 ? Date.now() : performance.now();
              timeout -= current;
            }
            wait = Math.max(wait, timeout);
          } else {
            error = E.NOTSUP;
          }
          const ev = outPtr + events * 32;
          v.setBigUint64(ev, userdata, true);
          v.setUint16(ev + 8, error, true);
          v.setUint8(ev + 10, tag);
          events++;
        }
        sleepMs(wait);
        v.setUint32(neventsPtr, events, true);
        return E.SUCCESS;
      },
      fd_write(fd, iovs, count, nwrittenPtr) {
        const entry = self.fds.get(fd);
        if (!entry) return E.BADF;
        let total = 0;
        const chunks = [];
        for (const [ptr, len] of self.gatherIovs(iovs, count)) {
          chunks.push(self.bytes(ptr, len).slice());
          total += len;
        }
        const data = new Uint8Array(total);
        let off = 0;
        for (const c of chunks) {
          data.set(c, off);
          off += c.length;
        }
        if (entry.kind === "stdout") self.stdout(data);
        else if (entry.kind === "stderr") self.stderr(data);
        else if (entry.kind === "node" && entry.node.kind === "file" && entry.write) {
          if (entry.append) entry.pos = entry.node.size;
          entry.node.writeAt(data, entry.pos);
          entry.pos += data.length;
        } else return E.BADF;
        self.view().setUint32(nwrittenPtr, total, true);
        return E.SUCCESS;
      },
      fd_pwrite(fd, iovs, count, offset, nwrittenPtr) {
        const entry = self.fds.get(fd);
        if (!entry || entry.kind !== "node" || entry.node.kind !== "file" || !entry.write) return E.BADF;
        let pos = Number(offset);
        let total = 0;
        for (const [ptr, len] of self.gatherIovs(iovs, count)) {
          entry.node.writeAt(self.bytes(ptr, len).slice(), pos);
          pos += len;
          total += len;
        }
        self.view().setUint32(nwrittenPtr, total, true);
        return E.SUCCESS;
      },
      fd_read(fd, iovs, count, nreadPtr) {
        const entry = self.fds.get(fd);
        if (!entry) return E.BADF;
        let total = 0;
        if (entry.kind === "stdin") {
          if (!self.pendingStdin || self.pendingStdin.length === 0) {
            self.pendingStdin = self.stdin() ?? new Uint8Array(0);
          }
          for (const [ptr, len] of self.gatherIovs(iovs, count)) {
            const n = Math.min(len, self.pendingStdin.length);
            self.bytes(ptr, n).set(self.pendingStdin.subarray(0, n));
            self.pendingStdin = self.pendingStdin.subarray(n);
            total += n;
            if (n < len) break;
          }
        } else if (entry.kind === "node" && entry.node.kind === "file" && entry.read) {
          for (const [ptr, len] of self.gatherIovs(iovs, count)) {
            const n = Math.max(0, Math.min(len, entry.node.size - entry.pos));
            self.bytes(ptr, n).set(entry.node.data.subarray(entry.pos, entry.pos + n));
            entry.pos += n;
            total += n;
            if (n < len) break;
          }
        } else if (entry.kind === "node" && entry.node.kind === "dir") {
          return E.ISDIR;
        } else {
          return E.BADF;
        }
        self.view().setUint32(nreadPtr, total, true);
        return E.SUCCESS;
      },
      fd_pread(fd, iovs, count, offset, nreadPtr) {
        const entry = self.fds.get(fd);
        if (!entry || entry.kind !== "node" || entry.node.kind !== "file") return E.BADF;
        let pos = Number(offset);
        let total = 0;
        for (const [ptr, len] of self.gatherIovs(iovs, count)) {
          const n = Math.max(0, Math.min(len, entry.node.size - pos));
          self.bytes(ptr, n).set(entry.node.data.subarray(pos, pos + n));
          pos += n;
          total += n;
          if (n < len) break;
        }
        self.view().setUint32(nreadPtr, total, true);
        return E.SUCCESS;
      },
      fd_seek(fd, offset, whence, newPtr) {
        const entry = self.fds.get(fd);
        if (!entry) return E.BADF;
        if (entry.kind !== "node") return E.SPIPE;
        const size = entry.node.kind === "file" ? entry.node.size : 0;
        const base = whence === 0 ? 0 : whence === 1 ? entry.pos : size;
        const next = base + Number(offset);
        if (next < 0) return E.INVAL;
        entry.pos = next;
        self.view().setBigUint64(newPtr, BigInt(next), true);
        return E.SUCCESS;
      },
      fd_tell(fd, ptr) {
        const entry = self.fds.get(fd);
        if (!entry || entry.kind !== "node") return E.BADF;
        self.view().setBigUint64(ptr, BigInt(entry.pos), true);
        return E.SUCCESS;
      },
      fd_close(fd) {
        if (!self.fds.has(fd)) return E.BADF;
        if (fd > 3) self.fds.delete(fd);
        return E.SUCCESS;
      },
      fd_sync() {
        return E.SUCCESS;
      },
      fd_datasync() {
        return E.SUCCESS;
      },
      fd_advise() {
        return E.SUCCESS;
      },
      fd_fdstat_get(fd, ptr) {
        const entry = self.fds.get(fd);
        if (!entry) return E.BADF;
        const v = self.view();
        let type = FILETYPE.CHAR;
        if (entry.kind === "node") type = entry.node.kind === "dir" ? FILETYPE.DIRECTORY : FILETYPE.REGULAR;
        v.setUint8(ptr, type);
        v.setUint16(ptr + 2, entry.append ? FDFLAGS.APPEND : 0, true);
        v.setBigUint64(ptr + 8, RIGHTS_ALL, true);
        v.setBigUint64(ptr + 16, RIGHTS_ALL, true);
        return E.SUCCESS;
      },
      fd_fdstat_set_flags(fd, flags) {
        const entry = self.fds.get(fd);
        if (!entry) return E.BADF;
        entry.append = (flags & FDFLAGS.APPEND) !== 0;
        return E.SUCCESS;
      },
      fd_filestat_get(fd, ptr) {
        const entry = self.fds.get(fd);
        if (!entry) return E.BADF;
        if (entry.kind !== "node") {
          const v = self.view();
          for (let i = 0; i < 64; i += 8) v.setBigUint64(ptr + i, 0n, true);
          v.setUint8(ptr + 16, FILETYPE.CHAR);
          return E.SUCCESS;
        }
        self.writeFilestat(ptr, entry.node);
        return E.SUCCESS;
      },
      fd_filestat_set_size(fd, size) {
        const entry = self.fds.get(fd);
        if (!entry || entry.kind !== "node" || entry.node.kind !== "file") return E.BADF;
        entry.node.truncate(Number(size));
        return E.SUCCESS;
      },
      fd_filestat_set_times() {
        return E.SUCCESS;
      },
      fd_prestat_get(fd, ptr) {
        const entry = self.fds.get(fd);
        if (!entry || !entry.preopen) return E.BADF;
        const v = self.view();
        v.setUint8(ptr, 0);
        v.setUint32(ptr + 4, encoder.encode(entry.preopen).length, true);
        return E.SUCCESS;
      },
      fd_prestat_dir_name(fd, ptr, len) {
        const entry = self.fds.get(fd);
        if (!entry || !entry.preopen) return E.BADF;
        const bytes = encoder.encode(entry.preopen);
        self.bytes(ptr, Math.min(len, bytes.length)).set(bytes.subarray(0, len));
        return E.SUCCESS;
      },
      fd_readdir(fd, buf, bufLen, cookie, usedPtr) {
        const entry = self.fds.get(fd);
        if (!entry || entry.kind !== "node" || entry.node.kind !== "dir") return E.BADF;
        const names = [".", "..", ...entry.node.entries.keys()];
        const v = self.view();
        let used = 0;
        for (let i = Number(cookie); i < names.length && used < bufLen; i++) {
          const name = encoder.encode(names[i]);
          const child = i < 2 ? entry.node : entry.node.entries.get(names[i]);
          const header = new Uint8Array(24);
          const hv = new DataView(header.buffer);
          hv.setBigUint64(0, BigInt(i + 1), true);
          hv.setBigUint64(8, child.ino, true);
          hv.setUint32(16, name.length, true);
          hv.setUint8(20, child.kind === "dir" ? FILETYPE.DIRECTORY : FILETYPE.REGULAR);
          const record = new Uint8Array(24 + name.length);
          record.set(header);
          record.set(name, 24);
          const n = Math.min(record.length, bufLen - used);
          self.bytes(buf + used, n).set(record.subarray(0, n));
          used += n;
        }
        v.setUint32(usedPtr, used, true);
        return E.SUCCESS;
      },
      path_open(dirfd, _dirflags, pathPtr, pathLen, oflags, rightsBase, _rightsInh, fdflags, fdPtr) {
        const r = self.resolve(dirfd, self.string(pathPtr, pathLen));
        if (r.error) return r.error;
        let node = r.node;
        if (node && (oflags & OFLAGS.CREAT) && (oflags & OFLAGS.EXCL)) return E.EXIST;
        if (!node) {
          if (!(oflags & OFLAGS.CREAT) || !r.dir) return E.NOENT;
          node = new MemNode("file");
          r.dir.entries.set(r.name, node);
        }
        if ((oflags & OFLAGS.DIRECTORY) && node.kind !== "dir") return E.NOTDIR;
        const base = BigInt(rightsBase);
        const write = (base & WRITE_RIGHTS) !== 0n || (oflags & OFLAGS.TRUNC) !== 0;
        if (node.kind === "dir" && write) return E.ISDIR;
        if ((oflags & OFLAGS.TRUNC) && node.kind === "file") node.truncate(0);
        const fd = self.nextFd++;
        self.fds.set(fd, {
          kind: "node",
          node,
          pos: 0,
          read: (base & READ_RIGHTS) !== 0n || !write,
          write,
          append: (fdflags & FDFLAGS.APPEND) !== 0,
        });
        self.view().setUint32(fdPtr, fd, true);
        return E.SUCCESS;
      },
      path_filestat_get(dirfd, _flags, pathPtr, pathLen, ptr) {
        const r = self.resolve(dirfd, self.string(pathPtr, pathLen));
        if (r.error) return r.error;
        if (!r.node) return E.NOENT;
        self.writeFilestat(ptr, r.node);
        return E.SUCCESS;
      },
      path_filestat_set_times() {
        return E.SUCCESS;
      },
      path_create_directory(dirfd, pathPtr, pathLen) {
        const r = self.resolve(dirfd, self.string(pathPtr, pathLen));
        if (r.error) return r.error;
        if (r.node) return E.EXIST;
        if (!r.dir) return E.INVAL;
        r.dir.entries.set(r.name, new MemNode("dir"));
        return E.SUCCESS;
      },
      path_remove_directory(dirfd, pathPtr, pathLen) {
        const r = self.resolve(dirfd, self.string(pathPtr, pathLen));
        if (r.error) return r.error;
        if (!r.node) return E.NOENT;
        if (r.node.kind !== "dir") return E.NOTDIR;
        if (r.node.entries.size > 0) return E.NOTEMPTY;
        if (!r.dir) return E.ACCES;
        r.dir.entries.delete(r.name);
        return E.SUCCESS;
      },
      path_unlink_file(dirfd, pathPtr, pathLen) {
        const r = self.resolve(dirfd, self.string(pathPtr, pathLen));
        if (r.error) return r.error;
        if (!r.node) return E.NOENT;
        if (r.node.kind === "dir") return E.ISDIR;
        r.dir.entries.delete(r.name);
        return E.SUCCESS;
      },
      path_rename(fd, oldPtr, oldLen, newFd, newPtr, newLen) {
        const from = self.resolve(fd, self.string(oldPtr, oldLen));
        if (from.error) return from.error;
        if (!from.node || !from.dir) return E.NOENT;
        const to = self.resolve(newFd, self.string(newPtr, newLen));
        if (to.error) return to.error;
        if (!to.dir) return E.INVAL;
        if (to.node && to.node.kind === "dir" && to.node.entries.size > 0) return E.NOTEMPTY;
        from.dir.entries.delete(from.name);
        to.dir.entries.set(to.name, from.node);
        return E.SUCCESS;
      },
      path_readlink() {
        return E.INVAL;
      },
      path_link() {
        return E.NOTSUP;
      },
      path_symlink() {
        return E.NOTSUP;
      },
    };
    return {
      wasi_snapshot_preview1: new Proxy(wasi, {
        get(target, name) {
          return target[name] ?? (() => E.NOSYS);
        },
      }),
    };
  }
}
