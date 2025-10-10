use crate::modules::systems::navigation;
use crate::utils::collections::fold_sum;

pub fn project_route(weights: [Field; 8], hazards: [Field; 8]) -> Field {
    let nav = navigation::weighted_course(weights, hazards);
    nav + fold_sum(weights)
}
