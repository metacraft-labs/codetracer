use noir_galactic_diff::entrypoints::mission_ops;

fn test_route_projection() {
    let weights: [Field; 8] = [1,2,3,4,5,6,7,8];
    let hazards: [Field; 8] = [8,7,6,5,4,3,2,1];
    let route = mission_ops::project_route(weights, hazards);
    assert(route > 0);
}
