// An in-memory file system for the WASI host. Paths are absolute and use
// forward slashes. Directories hold their entries in a Map, and files hold
// their bytes in a Uint8Array that grows by doubling.

const encoder = new TextEncoder();
const decoder = new TextDecoder();

let nextInode = 1n;

function now() {
  return BigInt(Date.now()) * 1_000_000n;
}

export class MemNode {
  constructor(kind) {
    this.kind = kind;
    this.ino = nextInode++;
    this.mtime = now();
    if (kind === "dir") {
      this.entries = new Map();
    } else {
      this.data = new Uint8Array(0);
      this.size = 0;
    }
  }

  /** The file contents as a fresh copy. */
  bytes() {
    return this.data.slice(0, this.size);
  }

  /** Grows the backing store so it holds at least `size` bytes. */
  reserve(size) {
    if (size <= this.data.length) return;
    let capacity = Math.max(this.data.length, 64);
    while (capacity < size) capacity *= 2;
    const next = new Uint8Array(capacity);
    next.set(this.data.subarray(0, this.size));
    this.data = next;
  }

  /** Sets the file size, filling new bytes with zeros. */
  truncate(size) {
    this.reserve(size);
    if (size > this.size) this.data.fill(0, this.size, size);
    this.size = size;
    this.mtime = now();
  }

  /** Writes `bytes` at `offset` and returns the number written. */
  writeAt(bytes, offset) {
    const end = offset + bytes.length;
    this.reserve(end);
    if (offset > this.size) this.data.fill(0, this.size, offset);
    this.data.set(bytes, offset);
    if (end > this.size) this.size = end;
    this.mtime = now();
    return bytes.length;
  }
}

/** Splits an absolute or relative path into its non-empty components. */
export function splitPath(path) {
  const parts = [];
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") parts.pop();
    else parts.push(part);
  }
  return parts;
}

export class MemFS {
  constructor() {
    this.root = new MemNode("dir");
  }

  /** Finds the node at `path`, or returns null. */
  lookup(path, base = this.root) {
    let node = base;
    for (const part of splitPath(path)) {
      if (node.kind !== "dir") return null;
      node = node.entries.get(part);
      if (!node) return null;
    }
    return node;
  }

  /** Creates every missing directory on `path` and returns the last. */
  mkdir(path) {
    let node = this.root;
    for (const part of splitPath(path)) {
      let child = node.entries.get(part);
      if (!child) {
        child = new MemNode("dir");
        node.entries.set(part, child);
      } else if (child.kind !== "dir") {
        throw new Error(`${path}: not a directory`);
      }
      node = child;
    }
    return node;
  }

  /** Writes a whole file, creating its parent directories. */
  writeFile(path, contents) {
    const parts = splitPath(path);
    if (parts.length === 0) throw new Error("writeFile needs a file path");
    const name = parts.pop();
    const dir = this.mkdir(parts.join("/"));
    let node = dir.entries.get(name);
    if (!node) {
      node = new MemNode("file");
      dir.entries.set(name, node);
    } else if (node.kind !== "file") {
      throw new Error(`${path}: is a directory`);
    }
    const bytes =
      typeof contents === "string" ? encoder.encode(contents) : new Uint8Array(contents);
    node.truncate(0);
    node.writeAt(bytes, 0);
  }

  /** Reads a whole file as bytes, or as a string with `encoding: "utf8"`. */
  readFile(path, options = {}) {
    const node = this.lookup(path);
    if (!node) throw new Error(`${path}: no such file`);
    if (node.kind !== "file") throw new Error(`${path}: is a directory`);
    const bytes = node.bytes();
    return options.encoding === "utf8" ? decoder.decode(bytes) : bytes;
  }

  /** Reports whether `path` names a file or directory. */
  exists(path) {
    return this.lookup(path) !== null;
  }

  /** Lists the names in a directory. */
  readdir(path) {
    const node = this.lookup(path);
    if (!node || node.kind !== "dir") throw new Error(`${path}: not a directory`);
    return [...node.entries.keys()];
  }

  /** Removes a file or an empty directory. */
  remove(path) {
    const parts = splitPath(path);
    const name = parts.pop();
    const dir = this.lookup(parts.join("/"));
    if (!dir || dir.kind !== "dir" || !dir.entries.has(name)) {
      throw new Error(`${path}: no such file`);
    }
    dir.entries.delete(name);
  }

  /** Writes every file of a `{ path: contents }` object under `prefix`. */
  mount(files, prefix = "/") {
    for (const [name, contents] of Object.entries(files)) {
      this.writeFile(`${prefix}/${name}`, contents);
    }
  }
}
