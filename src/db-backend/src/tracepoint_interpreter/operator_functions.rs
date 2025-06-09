use num_bigint::{BigInt, Sign};
use num_traits::ToPrimitive;
use runtime_tracing::{TypeKind, ValueRecord, NONE_TYPE_ID};

fn bigint_from_valuerecord(record: &ValueRecord) -> BigInt {
    if let ValueRecord::BigInt { b, negative, .. } = record {
        let sign = if *negative { Sign::Minus } else { Sign::Plus };
        BigInt::from_bytes_be(sign, b)
    } else {
        unreachable!("Expected BigInt value record")
    }
}

fn valuerecord_from_bigint(value: BigInt) -> ValueRecord {
    let (sign, bytes) = value.to_bytes_be();
    let negative = sign == Sign::Minus;
    ValueRecord::BigInt {
        b: bytes,
        negative,
        type_id: NONE_TYPE_ID,
    }
}

use crate::value::{Type, Value};

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_not(v: ValueRecord, eval_error_type: &Type) -> Result<ValueRecord, Value> {
    let res = match v {
        ValueRecord::Bool { b, type_id: _ } => !b,

        _ => {
            let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
            err_value.msg = "Not received non-boolean value!".to_string();
            return Err(err_value);
        }
    };

    // TODO: what type_id
    Ok(ValueRecord::Bool {
        b: res,
        type_id: NONE_TYPE_ID,
    })
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_negation(v: ValueRecord, eval_error_type: &Type) -> Result<ValueRecord, Value> {
    match v {
        ValueRecord::Int { i, type_id: _ } => Ok(ValueRecord::Int {
            i: -i,
            type_id: NONE_TYPE_ID,
        }),

        ValueRecord::Float { f, type_id: _ } => Ok(ValueRecord::Float {
            f: -f,
            type_id: NONE_TYPE_ID,
        }),

        bi @ ValueRecord::BigInt { .. } => {
            let res = -bigint_from_valuerecord(&bi);
            Ok(valuerecord_from_bigint(res))
        }

        _ => {
            let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
            err_value.msg = "Unary - not defined for this value!".to_string();
            Err(err_value)
        }
    }
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_and(v1: ValueRecord, v2: ValueRecord, eval_error_type: &Type) -> Result<ValueRecord, Value> {
    let res = match (v1, v2) {
        (ValueRecord::Bool { b: b1, type_id: _ }, ValueRecord::Bool { b: b2, type_id: _ }) => b1 && b2,

        _ => {
            let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
            err_value.msg = "Logic operator received non-boolean argument!".to_string();
            return Err(err_value);
        }
    };

    // TODO: what type_id
    Ok(ValueRecord::Bool {
        b: res,
        type_id: NONE_TYPE_ID,
    })
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_or(v1: ValueRecord, v2: ValueRecord, eval_error_type: &Type) -> Result<ValueRecord, Value> {
    let res = match (v1, v2) {
        (ValueRecord::Bool { b: b1, type_id: _ }, ValueRecord::Bool { b: b2, type_id: _ }) => b1 || b2,

        _ => {
            let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
            err_value.msg = "Logic operator received non-boolean argument!".to_string();
            return Err(err_value);
        }
    };

    // TODO: what type_id
    Ok(ValueRecord::Bool {
        b: res,
        type_id: NONE_TYPE_ID,
    })
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_plus(v1: ValueRecord, v2: ValueRecord, eval_error_type: &Type) -> Result<ValueRecord, Value> {
    match (v1, v2) {
        (ValueRecord::Int { i: i1, type_id: _ }, ValueRecord::Int { i: i2, type_id: _ }) => Ok(ValueRecord::Int {
            i: i1 + i2,
            type_id: NONE_TYPE_ID,
        }),

        (ValueRecord::Float { f: f1, type_id: _ }, ValueRecord::Float { f: f2, type_id: _ }) => {
            Ok(ValueRecord::Float {
                f: f1 + f2,
                type_id: NONE_TYPE_ID,
            })
        }

        (ValueRecord::Int { i, type_id: _ }, ValueRecord::Float { f, type_id: _ })
        | (ValueRecord::Float { f, type_id: _ }, ValueRecord::Int { i, type_id: _ }) => Ok(ValueRecord::Float {
            f: i as f64 + f,
            type_id: NONE_TYPE_ID,
        }),

        (bi1 @ ValueRecord::BigInt { .. }, bi2 @ ValueRecord::BigInt { .. }) => {
            let res = bigint_from_valuerecord(&bi1) + bigint_from_valuerecord(&bi2);
            Ok(valuerecord_from_bigint(res))
        }

        (bi @ ValueRecord::BigInt { .. }, ValueRecord::Int { i, type_id: _ }) => {
            let res = bigint_from_valuerecord(&bi) + BigInt::from(i);
            Ok(valuerecord_from_bigint(res))
        }

        (ValueRecord::Int { i, type_id: _ }, bi @ ValueRecord::BigInt { .. }) => {
            let res = BigInt::from(i) + bigint_from_valuerecord(&bi);
            Ok(valuerecord_from_bigint(res))
        }

        (bi @ ValueRecord::BigInt { .. }, ValueRecord::Float { f, type_id: _ }) => {
            if let Some(b) = bigint_from_valuerecord(&bi).to_f64() {
                Ok(ValueRecord::Float {
                    f: b + f,
                    type_id: NONE_TYPE_ID,
                })
            } else {
                let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                err_value.msg = "+ not defined for these values".to_string();
                Err(err_value)
            }
        }

        (ValueRecord::Float { f, type_id: _ }, bi @ ValueRecord::BigInt { .. }) => {
            if let Some(b) = bigint_from_valuerecord(&bi).to_f64() {
                Ok(ValueRecord::Float {
                    f: f + b,
                    type_id: NONE_TYPE_ID,
                })
            } else {
                let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                err_value.msg = "+ not defined for these values".to_string();
                Err(err_value)
            }
        }

        _ => {
            let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
            err_value.msg = "+ not defined for these values".to_string();
            Err(err_value)
        }
    }
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_minus(v1: ValueRecord, v2: ValueRecord, eval_error_type: &Type) -> Result<ValueRecord, Value> {
    match (v1, v2) {
        (ValueRecord::Int { i: i1, type_id: _ }, ValueRecord::Int { i: i2, type_id: _ }) => Ok(ValueRecord::Int {
            i: i1 - i2,
            type_id: NONE_TYPE_ID,
        }),

        (ValueRecord::Float { f: f1, type_id: _ }, ValueRecord::Float { f: f2, type_id: _ }) => {
            Ok(ValueRecord::Float {
                f: f1 - f2,
                type_id: NONE_TYPE_ID,
            })
        }

        (ValueRecord::Int { i, type_id: _ }, ValueRecord::Float { f, type_id: _ }) => Ok(ValueRecord::Float {
            f: i as f64 - f,
            type_id: NONE_TYPE_ID,
        }),

        (ValueRecord::Float { f, type_id: _ }, ValueRecord::Int { i, type_id: _ }) => Ok(ValueRecord::Float {
            f: f - i as f64,
            type_id: NONE_TYPE_ID,
        }),

        (bi1 @ ValueRecord::BigInt { .. }, bi2 @ ValueRecord::BigInt { .. }) => {
            let res = bigint_from_valuerecord(&bi1) - bigint_from_valuerecord(&bi2);
            Ok(valuerecord_from_bigint(res))
        }

        (bi @ ValueRecord::BigInt { .. }, ValueRecord::Int { i, type_id: _ }) => {
            let res = bigint_from_valuerecord(&bi) - BigInt::from(i);
            Ok(valuerecord_from_bigint(res))
        }

        (ValueRecord::Int { i, type_id: _ }, bi @ ValueRecord::BigInt { .. }) => {
            let res = BigInt::from(i) - bigint_from_valuerecord(&bi);
            Ok(valuerecord_from_bigint(res))
        }

        (bi @ ValueRecord::BigInt { .. }, ValueRecord::Float { f, type_id: _ }) => {
            if let Some(b) = bigint_from_valuerecord(&bi).to_f64() {
                Ok(ValueRecord::Float {
                    f: b - f,
                    type_id: NONE_TYPE_ID,
                })
            } else {
                let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                err_value.msg = "- not defined for these values".to_string();
                return Err(err_value);
            }
        }

        (ValueRecord::Float { f, type_id: _ }, bi @ ValueRecord::BigInt { .. }) => {
            if let Some(b) = bigint_from_valuerecord(&bi).to_f64() {
                Ok(ValueRecord::Float {
                    f: f - b,
                    type_id: NONE_TYPE_ID,
                })
            } else {
                let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                err_value.msg = "- not defined for these values".to_string();
                return Err(err_value);
            }
        }

        _ => {
            let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
            err_value.msg = "- not defined for these values".to_string();
            Err(err_value)
        }
    }
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_mult(v1: ValueRecord, v2: ValueRecord, eval_error_type: &Type) -> Result<ValueRecord, Value> {
    match (v1, v2) {
        (ValueRecord::Int { i: i1, type_id: _ }, ValueRecord::Int { i: i2, type_id: _ }) => Ok(ValueRecord::Int {
            i: i1 * i2,
            type_id: NONE_TYPE_ID,
        }),

        (ValueRecord::Float { f: f1, type_id: _ }, ValueRecord::Float { f: f2, type_id: _ }) => {
            Ok(ValueRecord::Float {
                f: f1 * f2,
                type_id: NONE_TYPE_ID,
            })
        }

        (ValueRecord::Int { i, type_id: _ }, ValueRecord::Float { f, type_id: _ })
        | (ValueRecord::Float { f, type_id: _ }, ValueRecord::Int { i, type_id: _ }) => Ok(ValueRecord::Float {
            f: i as f64 * f,
            type_id: NONE_TYPE_ID,
        }),

        (bi1 @ ValueRecord::BigInt { .. }, bi2 @ ValueRecord::BigInt { .. }) => {
            let res = bigint_from_valuerecord(&bi1) * bigint_from_valuerecord(&bi2);
            Ok(valuerecord_from_bigint(res))
        }

        (bi @ ValueRecord::BigInt { .. }, ValueRecord::Int { i, type_id: _ }) => {
            let res = bigint_from_valuerecord(&bi) * BigInt::from(i);
            Ok(valuerecord_from_bigint(res))
        }

        (ValueRecord::Int { i, type_id: _ }, bi @ ValueRecord::BigInt { .. }) => {
            let res = BigInt::from(i) * bigint_from_valuerecord(&bi);
            Ok(valuerecord_from_bigint(res))
        }

        (bi @ ValueRecord::BigInt { .. }, ValueRecord::Float { f, type_id: _ }) => {
            if let Some(b) = bigint_from_valuerecord(&bi).to_f64() {
                Ok(ValueRecord::Float {
                    f: b * f,
                    type_id: NONE_TYPE_ID,
                })
            } else {
                let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                err_value.msg = "* not defined for these values".to_string();
                return Err(err_value);
            }
        }

        (ValueRecord::Float { f, type_id: _ }, bi @ ValueRecord::BigInt { .. }) => {
            if let Some(b) = bigint_from_valuerecord(&bi).to_f64() {
                Ok(ValueRecord::Float {
                    f: f * b,
                    type_id: NONE_TYPE_ID,
                })
            } else {
                let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                err_value.msg = "* not defined for these values".to_string();
                return Err(err_value);
            }
        }

        _ => {
            let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
            err_value.msg = "* not defined for these values".to_string();
            Err(err_value)
        }
    }
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_div(v1: ValueRecord, v2: ValueRecord, eval_error_type: &Type) -> Result<ValueRecord, Value> {
    match (v1, v2) {
        (ValueRecord::Int { i: i1, type_id: _ }, ValueRecord::Int { i: i2, type_id: _ }) => Ok(ValueRecord::Int {
            i: i1 / i2,
            type_id: NONE_TYPE_ID,
        }),

        (ValueRecord::Float { f: f1, type_id: _ }, ValueRecord::Float { f: f2, type_id: _ }) => {
            Ok(ValueRecord::Float {
                f: f1 / f2,
                type_id: NONE_TYPE_ID,
            })
        }

        (ValueRecord::Int { i, type_id: _ }, ValueRecord::Float { f, type_id: _ }) => Ok(ValueRecord::Float {
            f: i as f64 / f,
            type_id: NONE_TYPE_ID,
        }),

        (ValueRecord::Float { f, type_id: _ }, ValueRecord::Int { i, type_id: _ }) => Ok(ValueRecord::Float {
            f: f / i as f64,
            type_id: NONE_TYPE_ID,
        }),

        (bi1 @ ValueRecord::BigInt { .. }, bi2 @ ValueRecord::BigInt { .. }) => {
            let res = bigint_from_valuerecord(&bi1) / bigint_from_valuerecord(&bi2);
            Ok(valuerecord_from_bigint(res))
        }

        (bi @ ValueRecord::BigInt { .. }, ValueRecord::Int { i, type_id: _ }) => {
            let res = bigint_from_valuerecord(&bi) / BigInt::from(i);
            Ok(valuerecord_from_bigint(res))
        }

        (ValueRecord::Int { i, type_id: _ }, bi @ ValueRecord::BigInt { .. }) => {
            let res = BigInt::from(i) / bigint_from_valuerecord(&bi);
            Ok(valuerecord_from_bigint(res))
        }

        (bi @ ValueRecord::BigInt { .. }, ValueRecord::Float { f, type_id: _ }) => {
            if let Some(b) = bigint_from_valuerecord(&bi).to_f64() {
                Ok(ValueRecord::Float {
                    f: b / f,
                    type_id: NONE_TYPE_ID,
                })
            } else {
                let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                err_value.msg = "/ not defined for these values".to_string();
                return Err(err_value);
            }
        }

        (ValueRecord::Float { f, type_id: _ }, bi @ ValueRecord::BigInt { .. }) => {
            if let Some(b) = bigint_from_valuerecord(&bi).to_f64() {
                Ok(ValueRecord::Float {
                    f: f / b,
                    type_id: NONE_TYPE_ID,
                })
            } else {
                let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                err_value.msg = "/ not defined for these values".to_string();
                return Err(err_value);
            }
        }

        _ => {
            let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
            err_value.msg = "/ not defined for these values".to_string();
            Err(err_value)
        }
    }
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_rem(v1: ValueRecord, v2: ValueRecord, eval_error_type: &Type) -> Result<ValueRecord, Value> {
    match (v1, v2) {
        (ValueRecord::Int { i: i1, type_id: _ }, ValueRecord::Int { i: i2, type_id: _ }) => Ok(ValueRecord::Int {
            i: i1 % i2,
            type_id: NONE_TYPE_ID,
        }),

        (ValueRecord::Float { f: f1, type_id: _ }, ValueRecord::Float { f: f2, type_id: _ }) => {
            Ok(ValueRecord::Float {
                f: f1 % f2,
                type_id: NONE_TYPE_ID,
            })
        }

        (ValueRecord::Int { i, type_id: _ }, ValueRecord::Float { f, type_id: _ }) => Ok(ValueRecord::Float {
            f: i as f64 % f,
            type_id: NONE_TYPE_ID,
        }),

        (ValueRecord::Float { f, type_id: _ }, ValueRecord::Int { i, type_id: _ }) => Ok(ValueRecord::Float {
            f: f % i as f64,
            type_id: NONE_TYPE_ID,
        }),

        (bi1 @ ValueRecord::BigInt { .. }, bi2 @ ValueRecord::BigInt { .. }) => {
            let res = bigint_from_valuerecord(&bi1) % bigint_from_valuerecord(&bi2);
            Ok(valuerecord_from_bigint(res))
        }

        (bi @ ValueRecord::BigInt { .. }, ValueRecord::Int { i, type_id: _ }) => {
            let res = bigint_from_valuerecord(&bi) % BigInt::from(i);
            Ok(valuerecord_from_bigint(res))
        }

        (ValueRecord::Int { i, type_id: _ }, bi @ ValueRecord::BigInt { .. }) => {
            let res = BigInt::from(i) % bigint_from_valuerecord(&bi);
            Ok(valuerecord_from_bigint(res))
        }

        (bi @ ValueRecord::BigInt { .. }, ValueRecord::Float { f, type_id: _ }) => {
            if let Some(b) = bigint_from_valuerecord(&bi).to_f64() {
                Ok(ValueRecord::Float {
                    f: b % f,
                    type_id: NONE_TYPE_ID,
                })
            } else {
                let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                err_value.msg = "% not defined for these values".to_string();
                return Err(err_value);
            }
        }

        (ValueRecord::Float { f, type_id: _ }, bi @ ValueRecord::BigInt { .. }) => {
            if let Some(b) = bigint_from_valuerecord(&bi).to_f64() {
                Ok(ValueRecord::Float {
                    f: f % b,
                    type_id: NONE_TYPE_ID,
                })
            } else {
                let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                err_value.msg = "% not defined for these values".to_string();
                return Err(err_value);
            }
        }

        _ => {
            let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
            err_value.msg = "% not defined for these values".to_string();
            Err(err_value)
        }
    }
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_equal(v1: ValueRecord, v2: ValueRecord, _eval_error_type: &Type) -> Result<ValueRecord, Value> {
    let res = match (v1, v2) {
        (ValueRecord::Bool { b: b1, type_id: _ }, ValueRecord::Bool { b: b2, type_id: _ }) => b1 == b2,

        (ValueRecord::Int { i: i1, type_id: _ }, ValueRecord::Int { i: i2, type_id: _ }) => i1 == i2,

        (bi1 @ ValueRecord::BigInt { .. }, bi2 @ ValueRecord::BigInt { .. }) => {
            bigint_from_valuerecord(&bi1) == bigint_from_valuerecord(&bi2)
        }

        (bi @ ValueRecord::BigInt { .. }, ValueRecord::Int { i, type_id: _ }) => {
            bigint_from_valuerecord(&bi) == BigInt::from(i)
        }

        (ValueRecord::Int { i, type_id: _ }, bi @ ValueRecord::BigInt { .. }) => {
            BigInt::from(i) == bigint_from_valuerecord(&bi)
        }

        (ValueRecord::String { text: s1, type_id: _ }, ValueRecord::String { text: s2, type_id: _ }) => s1 == s2,

        (ValueRecord::Int { i, type_id: _ }, ValueRecord::Float { f, type_id: _ }) => (i as f64) == f,

        (ValueRecord::Float { f, type_id: _ }, ValueRecord::Int { i, type_id: _ }) => f == i as f64,

        (bi @ ValueRecord::BigInt { .. }, ValueRecord::Float { f, type_id: _ }) => {
            if let Some(b) = bigint_from_valuerecord(&bi).to_f64() {
                b == f
            } else {
                false
            }
        }

        (ValueRecord::Float { f, type_id: _ }, bi @ ValueRecord::BigInt { .. }) => {
            if let Some(b) = bigint_from_valuerecord(&bi).to_f64() {
                f == b
            } else {
                false
            }
        }

        (ValueRecord::Float { f: f1, type_id: _ }, ValueRecord::Float { f: f2, type_id: _ }) => f1 == f2,

        _ => {
            // TODO: discuss if error or false on different types. Maybe change the behaviour based on the targeted language?

            false

            // let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
            // err_value.msg = "These values cannot be compared!".to_string();
            // return Err(err_value);
        }
    };

    // TODO: what type_id
    Ok(ValueRecord::Bool {
        b: res,
        type_id: NONE_TYPE_ID,
    })
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_not_equal(v1: ValueRecord, v2: ValueRecord, eval_error_type: &Type) -> Result<ValueRecord, Value> {
    let equal_check = operator_equal(v1, v2, eval_error_type);
    if let Ok(ValueRecord::Bool { b: res, type_id: _ }) = equal_check {
        Ok(ValueRecord::Bool {
            b: !res,
            type_id: NONE_TYPE_ID,
        })
    } else {
        equal_check
    }
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_less(v1: ValueRecord, v2: ValueRecord, eval_error_type: &Type) -> Result<ValueRecord, Value> {
    let res = match (v1, v2) {
        (ValueRecord::Int { i: i1, type_id: _ }, ValueRecord::Int { i: i2, type_id: _ }) => i1 < i2,

        (ValueRecord::Float { f: f1, type_id: _ }, ValueRecord::Float { f: f2, type_id: _ }) => f1 < f2,

        (ValueRecord::Int { i, type_id: _ }, ValueRecord::Float { f, type_id: _ }) => (i as f64) < f,

        (ValueRecord::Float { f, type_id: _ }, ValueRecord::Int { i, type_id: _ }) => f < i as f64,

        (bi1 @ ValueRecord::BigInt { .. }, bi2 @ ValueRecord::BigInt { .. }) => {
            bigint_from_valuerecord(&bi1) < bigint_from_valuerecord(&bi2)
        }

        (bi @ ValueRecord::BigInt { .. }, ValueRecord::Int { i, type_id: _ }) => {
            bigint_from_valuerecord(&bi) < BigInt::from(i)
        }

        (ValueRecord::Int { i, type_id: _ }, bi @ ValueRecord::BigInt { .. }) => {
            BigInt::from(i) < bigint_from_valuerecord(&bi)
        }

        (bi @ ValueRecord::BigInt { .. }, ValueRecord::Float { f, type_id: _ }) => {
            if let Some(b) = bigint_from_valuerecord(&bi).to_f64() {
                b < f
            } else {
                false
            }
        }

        (ValueRecord::Float { f, type_id: _ }, bi @ ValueRecord::BigInt { .. }) => {
            if let Some(b) = bigint_from_valuerecord(&bi).to_f64() {
                f < b
            } else {
                false
            }
        }

        _ => {
            let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
            err_value.msg = "< not defined for these values".to_string();
            return Err(err_value);
        }
    };

    // TODO: what type_id
    Ok(ValueRecord::Bool {
        b: res,
        type_id: NONE_TYPE_ID,
    })
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_less_equal(v1: ValueRecord, v2: ValueRecord, eval_error_type: &Type) -> Result<ValueRecord, Value> {
    let res = match (v1, v2) {
        (ValueRecord::Int { i: i1, type_id: _ }, ValueRecord::Int { i: i2, type_id: _ }) => i1 <= i2,

        (ValueRecord::Float { f: f1, type_id: _ }, ValueRecord::Float { f: f2, type_id: _ }) => f1 <= f2,

        (ValueRecord::Int { i, type_id: _ }, ValueRecord::Float { f, type_id: _ }) => (i as f64) <= f,

        (ValueRecord::Float { f, type_id: _ }, ValueRecord::Int { i, type_id: _ }) => f <= i as f64,

        (bi1 @ ValueRecord::BigInt { .. }, bi2 @ ValueRecord::BigInt { .. }) => {
            bigint_from_valuerecord(&bi1) <= bigint_from_valuerecord(&bi2)
        }

        (bi @ ValueRecord::BigInt { .. }, ValueRecord::Int { i, type_id: _ }) => {
            bigint_from_valuerecord(&bi) <= BigInt::from(i)
        }

        (ValueRecord::Int { i, type_id: _ }, bi @ ValueRecord::BigInt { .. }) => {
            BigInt::from(i) <= bigint_from_valuerecord(&bi)
        }

        (bi @ ValueRecord::BigInt { .. }, ValueRecord::Float { f, type_id: _ }) => {
            if let Some(b) = bigint_from_valuerecord(&bi).to_f64() {
                b <= f
            } else {
                false
            }
        }

        (ValueRecord::Float { f, type_id: _ }, bi @ ValueRecord::BigInt { .. }) => {
            if let Some(b) = bigint_from_valuerecord(&bi).to_f64() {
                f <= b
            } else {
                false
            }
        }

        _ => {
            let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
            err_value.msg = "<= not defined for these values".to_string();
            return Err(err_value);
        }
    };

    // TODO: what type_id
    Ok(ValueRecord::Bool {
        b: res,
        type_id: NONE_TYPE_ID,
    })
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_greater(v1: ValueRecord, v2: ValueRecord, eval_error_type: &Type) -> Result<ValueRecord, Value> {
    let res = match (v1, v2) {
        (ValueRecord::Int { i: i1, type_id: _ }, ValueRecord::Int { i: i2, type_id: _ }) => i1 > i2,

        (ValueRecord::Float { f: f1, type_id: _ }, ValueRecord::Float { f: f2, type_id: _ }) => f1 > f2,

        (ValueRecord::Int { i, type_id: _ }, ValueRecord::Float { f, type_id: _ }) => (i as f64) > f,

        (ValueRecord::Float { f, type_id: _ }, ValueRecord::Int { i, type_id: _ }) => f > i as f64,

        (bi1 @ ValueRecord::BigInt { .. }, bi2 @ ValueRecord::BigInt { .. }) => {
            bigint_from_valuerecord(&bi1) > bigint_from_valuerecord(&bi2)
        }

        (bi @ ValueRecord::BigInt { .. }, ValueRecord::Int { i, type_id: _ }) => {
            bigint_from_valuerecord(&bi) > BigInt::from(i)
        }

        (ValueRecord::Int { i, type_id: _ }, bi @ ValueRecord::BigInt { .. }) => {
            BigInt::from(i) > bigint_from_valuerecord(&bi)
        }

        (bi @ ValueRecord::BigInt { .. }, ValueRecord::Float { f, type_id: _ }) => {
            if let Some(b) = bigint_from_valuerecord(&bi).to_f64() {
                b > f
            } else {
                false
            }
        }

        (ValueRecord::Float { f, type_id: _ }, bi @ ValueRecord::BigInt { .. }) => {
            if let Some(b) = bigint_from_valuerecord(&bi).to_f64() {
                f > b
            } else {
                false
            }
        }

        _ => {
            let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
            err_value.msg = "> not defined for these values".to_string();
            return Err(err_value);
        }
    };

    // TODO: what type_id
    Ok(ValueRecord::Bool {
        b: res,
        type_id: NONE_TYPE_ID,
    })
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_greater_equal(v1: ValueRecord, v2: ValueRecord, eval_error_type: &Type) -> Result<ValueRecord, Value> {
    let res = match (v1, v2) {
        (ValueRecord::Int { i: i1, type_id: _ }, ValueRecord::Int { i: i2, type_id: _ }) => i1 >= i2,

        (ValueRecord::Float { f: f1, type_id: _ }, ValueRecord::Float { f: f2, type_id: _ }) => f1 >= f2,

        (ValueRecord::Int { i, type_id: _ }, ValueRecord::Float { f, type_id: _ }) => (i as f64) >= f,

        (ValueRecord::Float { f, type_id: _ }, ValueRecord::Int { i, type_id: _ }) => f >= i as f64,

        (bi1 @ ValueRecord::BigInt { .. }, bi2 @ ValueRecord::BigInt { .. }) => {
            bigint_from_valuerecord(&bi1) >= bigint_from_valuerecord(&bi2)
        }

        (bi @ ValueRecord::BigInt { .. }, ValueRecord::Int { i, type_id: _ }) => {
            bigint_from_valuerecord(&bi) >= BigInt::from(i)
        }

        (ValueRecord::Int { i, type_id: _ }, bi @ ValueRecord::BigInt { .. }) => {
            BigInt::from(i) >= bigint_from_valuerecord(&bi)
        }

        (bi @ ValueRecord::BigInt { .. }, ValueRecord::Float { f, type_id: _ }) => {
            if let Some(b) = bigint_from_valuerecord(&bi).to_f64() {
                b >= f
            } else {
                false
            }
        }

        (ValueRecord::Float { f, type_id: _ }, bi @ ValueRecord::BigInt { .. }) => {
            if let Some(b) = bigint_from_valuerecord(&bi).to_f64() {
                f >= b
            } else {
                false
            }
        }

        _ => {
            let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
            err_value.msg = ">= not defined for these values".to_string();
            return Err(err_value);
        }
    };

    // TODO: what type_id
    Ok(ValueRecord::Bool {
        b: res,
        type_id: NONE_TYPE_ID,
    })
}
