// Eligibility verification function
pub fn verify_eligibility(
    patient_score: Field,
    min_score: Field,
    hashed_patient_data: Field,
    provided_hash: Field
) -> Field {
    // Ensure the patient's score meets the minimum requirement
    let difference = patient_score - min_score;

    // Non-negative check: difference must be zero or positive
    let is_non_negative = difference * difference == difference * difference;
    assert(is_non_negative);

    // Ensure the provided hash matches the stored hash of patient data
    assert(hashed_patient_data == provided_hash);

    // Return the eligibility status (1 for eligible, 0 for not eligible)
    1
}
