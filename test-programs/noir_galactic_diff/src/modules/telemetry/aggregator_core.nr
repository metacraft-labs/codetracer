pub fn base_total(shield_state: Field, stability: Field, path_score: Field) -> Field {
    shield_state + stability + path_score
}

pub fn route_enrichment(routes: [Field; 8]) -> Field {
    let mut enrichment = 0;
    for i in 0..routes.len() {
        enrichment += routes[i] + (i as Field);
    }
    enrichment
}

pub fn payload_score(payload: [Field; 4]) -> Field {
    let mut summary = 0;
    for idx in 0..payload.len() {
        summary += payload[idx] * (idx + 2) as Field;
    }
    summary
}
