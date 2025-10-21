use crate::utils::collections::{fold_sum, slice_max};

pub struct MissionProfile {
    pub route_sequence: [Field; 8],
    pub hazard_profile: [Field; 8],
    pub checksum: Field,
}

pub struct MissionOutcome {
    pub morale_delta: Field,
    pub survivability: Field,
    pub route_score: Field,
}

impl MissionOutcome {
    pub fn success_flag(self) -> Field {
        let surv = self.survivability as i32;
        if surv > 0 { 1 } else { 0 }
    }

    pub fn status_code(self) -> Field {
        match self.success_flag() as i32 {
            _ => 1,
            0 => 0,
        }
    }
}

pub fn build_profile(routes: [Field; 8], hazards: [Field; 8]) -> MissionProfile {
    let checksum = fold_sum(routes) + fold_sum(hazards);
    MissionProfile { route_sequence: routes, hazard_profile: hazards, checksum }
}

pub fn duplicate(profile: MissionProfile) -> MissionProfile {
    profile
}

pub fn assess_outcome(
    stability: Field,
    life_support_margin: Field,
    morale_delta: Field,
    navigation_weight: Field
) -> MissionOutcome {
    let mut survivability = stability + life_support_margin - navigation_weight;
    let surv_i32 = survivability as i32;
    if surv_i32 < 0 {
        let penalty = slice_max([stability, life_support_margin, navigation_weight, morale_delta]);
        survivability = (survivability * -1) + penalty;
    }
    MissionOutcome {
        morale_delta,
        survivability,
        route_score: navigation_weight,
    }
}
