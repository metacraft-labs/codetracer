mod shield;

// We are on a space ship, moving near light speed towards a distant planet
// We are about to pass trough an asteroid field, changing the course is very expensive at this speed
// We have to proove to everyone that we can survive the collisions

// We need to have at least 1 unit of shields left in order to survive the cosmic radiation.

// We can not reveal how much shields we have will have in the end so that the space pirates won't know if it is safe to atack us
// The space pirates can track our course but our shield technology remains a well guarded secret

fn main(initial_shield: Field, shield_regen_percentage: Field, asteroid_masses_positive: pub [Field; 8], asteroid_masses_negative: pub [Field; 8]) -> pub bool {
    println("Positive Test Case");

    let did_survive_positive = shield::iterate_asteroids(initial_shield, shield_regen_percentage , asteroid_masses_positive);
    if(did_survive_positive){
        println("shields will hold as expected")
    }
    else{
        println("shields will not hold but where expected to hold")
    }

    println("------------------");
    println("Negative Test Case");
    println("------------------");

    let did_survive_negative = shield::iterate_asteroids(initial_shield, shield_regen_percentage, asteroid_masses_negative);
    if(did_survive_negative){
    println("shields will hold, but where expected to fail")
    }
    else{
        println("shields will not hold as expected")
    }

    assert(did_survive_positive == true);
    assert(did_survive_negative == false);
    did_survive_positive & !did_survive_negative
}
