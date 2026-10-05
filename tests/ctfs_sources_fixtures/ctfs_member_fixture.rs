use codetracer_ctfs::{reader::CtfsReader, CtfsWriter};
use std::{env, fs, path::Path};
fn main() {
    let out = env::args()
        .nth(1)
        .expect("unique owned fixture output directory");
    let out = Path::new(&out);
    assert!(out.is_dir());
    for (label, size) in [("empty", 0usize), ("direct", 127), ("mapped", 12289)] {
        let path = out.join(format!("{label}.ct"));
        assert!(!path.exists());
        let expected: Vec<u8> = (0..size).map(|i| ((i * 17 + 3) % 251) as u8).collect();
        let mut writer = CtfsWriter::create(&path, 4096, 31).expect("real frozen writer create");
        let member = writer.add_file("payload").expect("real member");
        writer.write(member, &expected).expect("real bytes");
        writer.close().expect("real finalized container");
        let bytes = fs::read(&path).unwrap();
        assert_eq!(bytes[5], 5);
        let mut reader = CtfsReader::open(&path).expect("canonical frozen reader");
        assert_eq!(reader.read_file("payload").unwrap(), expected);
        fs::write(out.join(format!("{label}.expected")), &expected).unwrap();
        println!(
            "fixture={label} container_bytes={} member_bytes={size}",
            bytes.len()
        );
    }
}
