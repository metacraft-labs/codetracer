pub fn probe_signal(window: [Field; 4]) -> Field {
    let mut sum = 0;
    for idx in 0..window.len() {
        sum += window[idx] * (idx + 1) as Field;
    }
    sum / 2
}
