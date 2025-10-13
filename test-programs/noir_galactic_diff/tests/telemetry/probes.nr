use noir_galactic_diff::modules::telemetry::aggregator;

fn test_collect_streams() {
    let streams = aggregator::collect_streams(10, 20, [8,7,6,5,4,3,2,1], 9);
    assert(streams > 0);
}
