use crate::utils::collections::fold_sum_small;

pub struct CrewMemberSummary {
    pub rank: Field,
    pub morale: Field,
    pub load: Field,
}

pub struct CrewManifest {
    pub shield_state: Field,
    pub life_support_grid: Field,
    pub crew: [CrewMemberSummary; 4],
}

pub fn build_manifest(initial_power: Field, crew_morale: [Field; 4], payload: [Field; 4]) -> (CrewManifest, Field) {
    let mut summaries: [CrewMemberSummary; 4] = [
        CrewMemberSummary { morale: crew_morale[0], load: payload[0], rank: 1 },
        CrewMemberSummary { morale: crew_morale[1], load: payload[1], rank: 2 },
        CrewMemberSummary { morale: crew_morale[2], load: payload[2], rank: 3 },
        CrewMemberSummary { morale: crew_morale[3], load: payload[3], rank: 4 }
    ];

    let mut total_summary = 0;
    for i in 0..4 {
        let morale_i32 = summaries[i].morale as i32;
        if morale_i32 < 0 {
            summaries[i].morale = (morale_i32 * -1) as Field;
        }
        total_summary += summaries[i].morale + summaries[i].load;
    }

    let grid = fold_sum_small(payload) + initial_power + 1;
    let manifest = CrewManifest {
        shield_state: initial_power + fold_sum_small(crew_morale),
        life_support_grid: grid,
        crew: summaries,
    };

    (manifest, total_summary)
}
