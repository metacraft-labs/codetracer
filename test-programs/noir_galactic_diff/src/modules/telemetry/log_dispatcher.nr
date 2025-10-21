pub fn print_log_summary(log_entries: [Field; 4], stable: bool) {
    println("-- telemetry summary --");
    for idx in 0..log_entries.len() {
        let value = log_entries[idx] as i32;
        println(f"entry[{idx}] = {value}");
    }
    if !stable {
        println("system unstable");
    } else {
        println("system stable");
    }
}
