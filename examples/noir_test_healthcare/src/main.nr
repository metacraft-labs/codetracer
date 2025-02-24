mod eligibility;

use crate::eligibility::verify_eligibility;

fn main(
    patient_score: pub Field, 
    min_score: pub Field, 
    hashed_patient_data: pub Field, 
    provided_hash: Field
) {
    // Call the eligibility verification function
    let eligibility_status = verify_eligibility(patient_score, min_score, hashed_patient_data, provided_hash);

    // Assert that the eligibility status is valid
    assert(eligibility_status == 1);
}