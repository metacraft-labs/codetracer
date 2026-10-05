// Real frozen producer APIs create these finalized fixtures. Deliberately small
// protocol subjects isolate path-ID/layout boundaries; no compiler, reader,
// filesystem or launcher is mocked. Malformed variants are separate controls.
use codetracer_ctfs::{reader::CtfsReader, CtfsWriter};
use codetracer_trace_writer::{column_aware, interning_tables, meta_dat};
use std::{env, fs, path::Path};
fn write_container(out: &Path, label: &str, flags: u16, records: Option<Vec<Vec<u8>>>) {
    let path = out.join(format!("{label}.ct"));
    assert!(!path.exists());
    let meta = meta_dat::encode_meta_dat(
        "019f1234-5678-7abc-8def-0123456789ab",
        "fixture-program",
        &["arg one".into(), "arg-two".into()],
        "/fixture/workdir",
        "fixture-recorder",
        flags,
    );
    assert_eq!(meta_dat::decode_meta_dat(&meta).unwrap().version, 6);
    let mut writer = CtfsWriter::create(&path, 4096, 31).unwrap();
    let member = writer.add_file("meta.dat").unwrap();
    writer.write(member, &meta).unwrap();
    if let Some(records) = records {
        let (data, offsets) = interning_tables::encode_raw_table(&records);
        let member = writer.add_file("paths.dat").unwrap();
        writer.write(member, &data).unwrap();
        let member = writer.add_file("paths.off").unwrap();
        writer.write(member, &offsets).unwrap();
    }
    writer.close().unwrap();
    let mut reader = CtfsReader::open(&path).unwrap();
    assert_eq!(reader.read_file("meta.dat").unwrap(), meta);
    println!("fixture={label} finalized schema=6 flags={flags}");
}
fn main() {
    let args: Vec<String> = env::args().collect();
    assert_eq!(args.len(), 3);
    let out = Path::new(&args[1]);
    assert!(out.is_dir());
    write_container(out, "schema6-absent", 0, None);
    write_container(out, "schema6-empty", 0, Some(vec![]));
    write_container(
        out,
        "schema6-bare-ids",
        0,
        Some(vec![
            b"/fixture/one".to_vec(),
            b"/fixture/one".to_vec(),
            vec![],
        ]),
    );
    write_container(
        out,
        "schema6-columns",
        0x10,
        Some(vec![
            column_aware::encode_path_record_layout_a("/fixture/columns", &[8, 3, 0]),
            column_aware::encode_path_record_layout_a("/fixture/conventional", &[]),
        ]),
    );
    let trace = Path::new(&args[2]);
    let mut reader = CtfsReader::open(trace).unwrap();
    let bytes = reader.read_file("meta.dat").unwrap();
    let meta = meta_dat::decode_meta_dat(&bytes).unwrap();
    assert_eq!(meta.version, 6);
    let expected = serde_json::json!({"version":meta.version,"flags":meta.flags,"ext_flags":meta.ext_flags,"recording_id":meta.recording_id,"program":meta.program,"args":meta.args,"workdir":meta.workdir,"recorder_id":meta.recorder_id});
    fs::write(
        out.join("retained-python-meta.expected.json"),
        serde_json::to_vec_pretty(&expected).unwrap(),
    )
    .unwrap();
    fs::write(out.join("retained-python-meta.dat"), bytes).unwrap();
    println!("retained Python member parsed by actual frozen Rust schema6 decoder");
}
