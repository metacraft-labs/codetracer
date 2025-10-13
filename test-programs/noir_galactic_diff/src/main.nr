mod entrypoints;
mod components;
mod modules;
mod utils;

use crate::components::crew_registry;
use crate::components::mission_profile::MissionOutcome;
use crate::entrypoints::mission_ops;
use crate::modules::telemetry::{aggregator, archives::historical::mega_trace, features::signal_probe, log_dispatcher};
use crate::modules::algorithms::{statistics, pathfinding};
use crate::modules::systems::{navigation, shield_matrix, legacy};
use crate::utils::math_helpers;

fn main(
    initial_power: Field,
    regen_rate: Field,
    route_weights: pub [Field; 8],
    hazard_intensity: pub [Field; 8],
    crew_morale: pub [Field; 4],
    logistic_payload: pub [Field; 4]
) -> pub Field {
    println("== noir_galactic_diff run ==");

    let (manifest, manifest_summary) = components::crew_registry::build_manifest(initial_power, crew_morale, logistic_payload);
    let mission = components::mission_profile::build_profile(route_weights, hazard_intensity);

    let mut stability = shield_matrix::evaluate_matrix(manifest.shield_state, regen_rate, hazard_intensity);
    let navigation_weight = navigation::weighted_course(route_weights, hazard_intensity);
    let life_support_margin = legacy::life_support::estimate_margin(manifest.life_support_grid, crew_morale);

    let path_score = pathfinding::compute_galactic_path(route_weights, hazard_intensity);
    let morale_delta = statistics::normalize_morale(crew_morale);

    let mission_checksum = mission.checksum;
    let route_sequence = mission.route_sequence;
    let hazard_profile = mission.hazard_profile;
    let recorded = mission_ops::record_snapshot(manifest_summary, mission_checksum, route_sequence, hazard_profile, path_score, morale_delta, stability);
    let stability_flag = (stability as i32) > 0;
    log_dispatcher::print_log_summary(recorded.log_entries, stability_flag);

    let telemetry_total = aggregator::collect_streams(
        manifest.shield_state,
        stability,
        route_sequence,
        path_score
    );

    let probe_window = [stability, path_score, navigation_weight, life_support_margin];
    let probe_signal = signal_probe::probe_signal(probe_window);

    let mega = mega_trace::emit_trace_summary(telemetry_total + navigation_weight + probe_signal);
    stability = stability + mega;

    if (stability as i32) <= 0 {
        println("Shield stability dropped below threshold, forcing fallback!");
        stability = stability + math_helpers::recovery_boost(regen_rate, hazard_intensity);
    }

    let outcome: MissionOutcome = components::mission_profile::assess_outcome(
        stability,
        life_support_margin,
        morale_delta,
        navigation_weight
    );

    println("Mission status code:");
    println(outcome.status_code() as i32);

    let checksum = math_helpers::checksum([
        stability,
        navigation_weight,
        life_support_margin,
        path_score,
        morale_delta,
        mega
    ]);

    checksum
}
