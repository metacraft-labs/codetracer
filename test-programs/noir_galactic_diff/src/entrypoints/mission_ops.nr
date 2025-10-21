use crate::modules::systems::navigation;
use crate::utils::collections::fold_sum;

pub struct SnapshotRecord {
    pub manifest_checksum: Field,
    pub mission_checksum: Field,
    pub log_entries: [Field; 4],
}

pub fn record_snapshot(
    manifest_checksum: Field,
    mission_checksum: Field,
    route_sequence: [Field; 8],
    hazard_profile: [Field; 8],
    path_score: Field,
    morale_delta: Field,
    stability_marker: Field
) -> SnapshotRecord {
    let mission_checksum = mission_checksum + path_score + morale_delta;

    let mut logs: [Field; 4] = [0, 0, 0, 0];
    let mut pairing_sum = 0;
    for primary in 0..2 {
        for secondary in 0..2 {
            let route_idx = primary + secondary;
            pairing_sum += route_sequence[route_idx] + hazard_profile[primary];
        }
    }
    logs[0] = manifest_checksum + pairing_sum;
    logs[1] = mission_checksum;
    logs[2] = fold_sum(route_sequence);
    logs[3] = fold_sum(hazard_profile) + stability_marker;

    SnapshotRecord { manifest_checksum, mission_checksum, log_entries: logs }
}

pub fn project_route(weights: [Field; 8], hazards: [Field; 8]) -> Field {
    let nav = navigation::weighted_course(weights, hazards);
    nav + fold_sum(weights)
}
