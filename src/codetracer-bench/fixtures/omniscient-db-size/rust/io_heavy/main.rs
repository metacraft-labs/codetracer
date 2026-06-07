// omniscient-db-size / rust / io_heavy
use std::env;
use std::fs;
use std::io::{Read, Write};
use std::path::PathBuf;

fn main() {
    let scratch = env::temp_dir().join(format!("ct-bench-io-{}", std::process::id()));
    fs::create_dir_all(&scratch).expect("mkdir");
    let mut sizes: Vec<usize> = Vec::new();
    for i in 0..64usize {
        let path: PathBuf = scratch.join(format!("chunk_{i:02}.bin"));
        let payload: Vec<u8> = "abcdefgh".repeat(i + 1).into_bytes();
        let mut f = fs::File::create(&path).expect("create");
        f.write_all(&payload).expect("write");
        drop(f);
        let mut f = fs::File::open(&path).expect("open");
        let mut buf = Vec::new();
        f.read_to_end(&mut buf).expect("read");
        sizes.push(buf.len());
    }
    fs::remove_dir_all(&scratch).expect("rmdir");
    let total: usize = sizes.iter().sum();
    println!("{}", total);
}
