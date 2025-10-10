use noir_galactic_diff::modules::telemetry::aggregator;

fn test_collect_streams() {
    let streams = aggregator::collect_streams(10, 20, [1,2,3,4,5,6,7,8], 9);
    assert(streams > 0);
}
