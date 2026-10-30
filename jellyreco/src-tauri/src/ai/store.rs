//! Append-only vector file ("ATW1" | u32 dim | records: i64 id + dim × f32), like the iPhone's.
//! Each batch appends only its new vectors; the file is compacted when it's mostly duplicates.

use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;

const MAGIC: &[u8; 4] = b"ATW1";
const MAX_CACHED: usize = 6000;

pub struct VectorStore {
    path: PathBuf,
    dim: usize,
    vectors: HashMap<i64, Vec<f32>>,
    records_on_disk: usize,
}

impl VectorStore {
    pub fn open(path: PathBuf) -> Self {
        let mut s = Self { path, dim: 0, vectors: HashMap::new(), records_on_disk: 0 };
        if let Ok(bytes) = fs::read(&s.path) {
            if bytes.len() >= 8 && &bytes[0..4] == MAGIC {
                let dim = u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as usize;
                let stride = 8 + dim * 4;
                if dim > 0 {
                    s.dim = dim;
                    let mut off = 8;
                    while off + stride <= bytes.len() {
                        let id = i64::from_le_bytes(bytes[off..off + 8].try_into().unwrap());
                        let v = bytes[off + 8..off + stride]
                            .chunks_exact(4)
                            .map(|c| f32::from_le_bytes(c.try_into().unwrap()))
                            .collect();
                        s.vectors.insert(id, v); // later records win
                        s.records_on_disk += 1;
                        off += stride;
                    }
                }
            }
        }
        s
    }

    pub fn get(&self, id: i64) -> Option<&[f32]> {
        self.vectors.get(&id).map(|v| v.as_slice())
    }

    pub fn append(&mut self, fresh: &[(i64, Vec<f32>)]) {
        if fresh.is_empty() {
            return;
        }
        if self.dim == 0 {
            self.dim = fresh[0].1.len();
        }
        for (id, v) in fresh {
            if v.len() == self.dim {
                self.vectors.insert(*id, v.clone());
            }
        }
        if self.vectors.len() > MAX_CACHED {
            let extra = self.vectors.len() - MAX_CACHED;
            let drop: Vec<i64> = self.vectors.keys().take(extra).copied().collect();
            for id in drop {
                self.vectors.remove(&id);
            }
            return self.compact();
        }
        if self.records_on_disk > 0 && self.records_on_disk + fresh.len() > self.vectors.len() * 3 / 2 + 50 {
            return self.compact();
        }
        let new_file = !self.path.exists();
        let mut data = Vec::new();
        if new_file {
            data.extend_from_slice(&self.header());
            self.records_on_disk = 0;
        }
        for (id, v) in fresh {
            if v.len() == self.dim {
                record(&mut data, *id, v);
                self.records_on_disk += 1;
            }
        }
        if let Some(dir) = self.path.parent() {
            let _ = fs::create_dir_all(dir);
        }
        if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&self.path) {
            let _ = f.write_all(&data);
        }
    }

    fn header(&self) -> Vec<u8> {
        let mut h = MAGIC.to_vec();
        h.extend_from_slice(&(self.dim as u32).to_le_bytes());
        h
    }

    fn compact(&mut self) {
        let mut data = self.header();
        let mut n = 0;
        for (id, v) in &self.vectors {
            if v.len() == self.dim {
                record(&mut data, *id, v);
                n += 1;
            }
        }
        if let Some(dir) = self.path.parent() {
            let _ = fs::create_dir_all(dir);
        }
        let tmp = self.path.with_extension("tmp");
        if fs::write(&tmp, &data).is_ok() && fs::rename(&tmp, &self.path).is_ok() {
            self.records_on_disk = n;
        }
    }
}

fn record(out: &mut Vec<u8>, id: i64, v: &[f32]) {
    out.extend_from_slice(&id.to_le_bytes());
    for x in v {
        out.extend_from_slice(&x.to_le_bytes());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_and_compaction() {
        let dir = std::env::temp_dir().join(format!("jellyreco-store-{}", std::process::id()));
        let path = dir.join("v.bin");
        let _ = fs::remove_dir_all(&dir);
        let mut s = VectorStore::open(path.clone());
        s.append(&[(1, vec![1.0, 0.0]), (2, vec![0.0, 1.0])]);
        s.append(&[(1, vec![0.5, 0.5])]);
        let r = VectorStore::open(path.clone());
        assert_eq!(r.get(1), Some(&[0.5f32, 0.5][..]));
        assert_eq!(r.get(2), Some(&[0.0f32, 1.0][..]));
        for i in 0..200 {
            s.append(&[(1, vec![i as f32, 0.0])]);
        }
        let r = VectorStore::open(path);
        assert_eq!(r.get(1), Some(&[199.0f32, 0.0][..]));
        assert!(r.records_on_disk < 100, "compacted");
        let _ = fs::remove_dir_all(&dir);
    }
}
