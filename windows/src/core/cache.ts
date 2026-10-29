// Small persistent cache (port of DiskCache.swift). In the app it's IndexedDB inside the
// app's own WebView2 data folder; tests use memory.

export interface Store {
  load<T>(name: string): Promise<T | undefined>;
  save(name: string, value: unknown): Promise<void>;
  remove(name: string): Promise<void>;
  keys(): Promise<string[]>;
}

class MemoryStore implements Store {
  private map = new Map<string, string>();
  async load<T>(name: string) {
    const v = this.map.get(name);
    return v === undefined ? undefined : (JSON.parse(v) as T);
  }
  async save(name: string, value: unknown) {
    this.map.set(name, JSON.stringify(value));
  }
  async remove(name: string) {
    this.map.delete(name);
  }
  async keys() {
    return [...this.map.keys()];
  }
}

class IDBStore implements Store {
  private db: Promise<IDBDatabase>;
  constructor() {
    this.db = new Promise((resolve, reject) => {
      const req = indexedDB.open("anitrack", 1);
      req.onupgradeneeded = () => req.result.createObjectStore("cache");
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  }
  private async tx<T>(mode: IDBTransactionMode, run: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> {
    const db = await this.db;
    return new Promise((resolve, reject) => {
      const req = run(db.transaction("cache", mode).objectStore("cache"));
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  }
  async load<T>(name: string) {
    try {
      return (await this.tx("readonly", (s) => s.get(name))) as T | undefined;
    } catch {
      return undefined;
    }
  }
  async save(name: string, value: unknown) {
    try {
      // structuredClone strips class instances and functions, like a JSON round trip would.
      await this.tx("readwrite", (s) => s.put(JSON.parse(JSON.stringify(value)), name));
    } catch {
      /* best effort, like the phone's cache */
    }
  }
  async remove(name: string) {
    try {
      await this.tx("readwrite", (s) => s.delete(name));
    } catch {
      /* ignore */
    }
  }
  async keys() {
    try {
      return (await this.tx("readonly", (s) => s.getAllKeys())).map(String);
    } catch {
      return [];
    }
  }
}

export const DiskCache: Store = typeof indexedDB !== "undefined" ? new IDBStore() : new MemoryStore();

/** Log-out: removes only what belongs to an account (list, picks, fan signals, profile). */
export async function clearPersonal() {
  for (const key of await DiskCache.keys()) {
    if (["viewer", "list-", "feed", "fans"].some((p) => key.startsWith(p))) await DiskCache.remove(key);
  }
}

/** Small synchronous settings (localStorage, like UserDefaults). */
export const Defaults = {
  get<T>(key: string, fallback: T): T {
    try {
      const raw = globalThis.localStorage?.getItem(key);
      return raw == null ? fallback : (JSON.parse(raw) as T);
    } catch {
      return fallback;
    }
  },
  has(key: string): boolean {
    try {
      return globalThis.localStorage?.getItem(key) != null;
    } catch {
      return false;
    }
  },
  set(key: string, value: unknown) {
    try {
      globalThis.localStorage?.setItem(key, JSON.stringify(value));
    } catch {
      /* ignore */
    }
  },
  remove(key: string) {
    try {
      globalThis.localStorage?.removeItem(key);
    } catch {
      /* ignore */
    }
  },
};
