pub fn iterate_asteroids(initial_shield: Field, shield_base_regen: Field, masses: [Field; 8]) -> bool {
    let mut remaining_shield = initial_shield;
    for i in 0..8 {
        let mass = masses[i];
        let damage = calculate_damage(initial_shield, remaining_shield, mass);
        remaining_shield -= damage;
        let regeneration = calculate_shield_regeneration(initial_shield, shield_base_regen);
        remaining_shield += regeneration;
        status_report(i, initial_shield, remaining_shield, damage, regeneration);
    }
    
    // We need to have at least 1 unit of shields left in order to survive the cosmic radiation.
    let result = remaining_shield as i32 > 0;
    result
}

fn calculate_damage(initial_shield: Field, remaining_shield: Field, mass: Field) -> Field {
    // Shields get exponentially less efficient
    // At 100% shields 1 unit of mass will drain 1 point of energy
    // At 50% shields 1 unit of mass will drain 50 points of energy
    let shield_pct = calculate_remaining_shield_pct(initial_shield, remaining_shield);
    let damage = mass * (100 - shield_pct);
    damage as Field
}

fn calculate_shield_regeneration(initial_shield:Field, shield_regen_percentage: Field) -> Field{
    // shields regain a percentage of the maxium capacity after each hit
    let result = (initial_shield * shield_regen_percentage) / 100;
    result as Field
}

fn calculate_remaining_shield_pct(initial_shield: Field, remaining_shield: Field) -> Field {
    let result = (remaining_shield * 100) as i32 / initial_shield as i32;
    result as Field
}

fn status_report(iteration: u32 ,initial_shield: Field, remaining_shield: Field, damage: Field, regenerated_shield: Field){
    println(f"----- iteration {iteration} -----");

    // in noir, fields can't be printed directly so we convert them to an integer type first
    let damage_as_i32 = damage as i32;
    println(f"Damage: {damage_as_i32}");

    let regenerated_shield_as_i32 = regenerated_shield as i32;
    println(f"Regenerated {regenerated_shield_as_i32} energy");

    let remaining_shield_as_i32 = remaining_shield as i32;
    let remaining_shield_pct = calculate_remaining_shield_pct(initial_shield, remaining_shield);
    let remaining_shield_pct_as_i32 = remaining_shield_pct as i32;
    println(f"Shield status {remaining_shield_pct_as_i32}% {remaining_shield_as_i32}");
}