use num_bigint::{BigInt, Sign};
use num_traits::ToPrimitive;
use runtime_tracing::{TypeKind, TypeRecord, TypeSpecificInfo};

use crate::value::{Type, Value, ValueRecordWithType};

fn simple_type_record(kind: TypeKind, lang_type: &str) -> TypeRecord {
    TypeRecord {
        kind,
        lang_type: lang_type.to_string(),
        specific_info: TypeSpecificInfo::None,
    }
}

fn bool_type_record() -> TypeRecord {
    simple_type_record(TypeKind::Bool, "bool")
}

fn bigint_from_parts(bytes: &[u8], negative: bool) -> BigInt {
    let sign = if negative { Sign::Minus } else { Sign::Plus };
    BigInt::from_bytes_be(sign, bytes)
}

fn valuerecord_from_bigint(value: BigInt, typ: &TypeRecord) -> ValueRecordWithType {
    let (sign, bytes) = value.to_bytes_be();
    let negative = sign == Sign::Minus;
    ValueRecordWithType::BigInt {
        b: bytes,
        negative,
        typ: typ.clone(),
    }
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_not(v: ValueRecordWithType, eval_error_type: &Type) -> Result<ValueRecordWithType, Value> {
    match v {
        ValueRecordWithType::Bool { b, typ } => Ok(ValueRecordWithType::Bool { b: !b, typ }),

        _ => {
            let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
            err_value.msg = "Not received non-boolean value!".to_string();
            Err(err_value)
        }
    }
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_negation(v: ValueRecordWithType, eval_error_type: &Type) -> Result<ValueRecordWithType, Value> {
    match v {
        ValueRecordWithType::Int { i, typ } => Ok(ValueRecordWithType::Int { i: -i, typ }),

        ValueRecordWithType::Float { f, typ } => Ok(ValueRecordWithType::Float { f: -f, typ }),

        ValueRecordWithType::BigInt { b, negative, typ } => {
            let res = -bigint_from_parts(&b, negative);
            Ok(valuerecord_from_bigint(res, &typ))
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
pub fn operator_and(
    v1: ValueRecordWithType,
    v2: ValueRecordWithType,
    eval_error_type: &Type,
) -> Result<ValueRecordWithType, Value> {
    match (v1, v2) {
        (ValueRecordWithType::Bool { b: b1, typ }, ValueRecordWithType::Bool { b: b2, .. }) => Ok(
            ValueRecordWithType::Bool {
                b: b1 && b2,
                typ,
            },
        ),

        _ => {
            let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
            err_value.msg = "Logic operator received non-boolean argument!".to_string();
            Err(err_value)
        }
    }
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_or(
    v1: ValueRecordWithType,
    v2: ValueRecordWithType,
    eval_error_type: &Type,
) -> Result<ValueRecordWithType, Value> {
    match (v1, v2) {
        (ValueRecordWithType::Bool { b: b1, typ }, ValueRecordWithType::Bool { b: b2, .. }) => Ok(
            ValueRecordWithType::Bool {
                b: b1 || b2,
                typ,
            },
        ),

        _ => {
            let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
            err_value.msg = "Logic operator received non-boolean argument!".to_string();
            Err(err_value)
        }
    }
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_plus(
    v1: ValueRecordWithType,
    v2: ValueRecordWithType,
    eval_error_type: &Type,
) -> Result<ValueRecordWithType, Value> {
    match (v1, v2) {
        (ValueRecordWithType::Int { i: i1, typ }, ValueRecordWithType::Int { i: i2, .. }) => {
            Ok(ValueRecordWithType::Int { i: i1 + i2, typ })
        }

        (ValueRecordWithType::Float { f: f1, typ }, ValueRecordWithType::Float { f: f2, .. }) => {
            Ok(ValueRecordWithType::Float { f: f1 + f2, typ })
        }

        (ValueRecordWithType::Int { i, .. }, ValueRecordWithType::Float { f, typ })
        | (ValueRecordWithType::Float { f, typ }, ValueRecordWithType::Int { i, .. }) => {
            Ok(ValueRecordWithType::Float {
                f: i as f64 + f,
                typ,
            })
        }

        (
            ValueRecordWithType::BigInt {
                b: b1,
                negative: n1,
                typ,
            },
            ValueRecordWithType::BigInt {
                b: b2,
                negative: n2,
                ..
            },
        ) => {
            let res = bigint_from_parts(&b1, n1) + bigint_from_parts(&b2, n2);
            Ok(valuerecord_from_bigint(res, &typ))
        }

        (ValueRecordWithType::BigInt { b, negative, typ }, ValueRecordWithType::Int { i, .. }) => {
            let res = bigint_from_parts(&b, negative) + BigInt::from(i);
            Ok(valuerecord_from_bigint(res, &typ))
        }

        (ValueRecordWithType::Int { i, .. }, ValueRecordWithType::BigInt { b, negative, typ }) => {
            let res = BigInt::from(i) + bigint_from_parts(&b, negative);
            Ok(valuerecord_from_bigint(res, &typ))
        }

        (
            ValueRecordWithType::BigInt { b, negative, .. },
            ValueRecordWithType::Float { f, typ },
        )
        | (
            ValueRecordWithType::Float { f, typ },
            ValueRecordWithType::BigInt { b, negative, .. },
        ) => {
            if let Some(b) = bigint_from_parts(&b, negative).to_f64() {
                Ok(ValueRecordWithType::Float { f: b + f, typ })
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
pub fn operator_minus(
    v1: ValueRecordWithType,
    v2: ValueRecordWithType,
    eval_error_type: &Type,
) -> Result<ValueRecordWithType, Value> {
    match (v1, v2) {
        (ValueRecordWithType::Int { i: i1, typ }, ValueRecordWithType::Int { i: i2, .. }) => {
            Ok(ValueRecordWithType::Int { i: i1 - i2, typ })
        }

        (ValueRecordWithType::Float { f: f1, typ }, ValueRecordWithType::Float { f: f2, .. }) => {
            Ok(ValueRecordWithType::Float { f: f1 - f2, typ })
        }

        (ValueRecordWithType::Int { i, .. }, ValueRecordWithType::Float { f, typ }) => {
            Ok(ValueRecordWithType::Float {
                f: i as f64 - f,
                typ,
            })
        }

        (ValueRecordWithType::Float { f, typ }, ValueRecordWithType::Int { i, .. }) => {
            Ok(ValueRecordWithType::Float {
                f: f - i as f64,
                typ,
            })
        }

        (
            ValueRecordWithType::BigInt {
                b: b1,
                negative: n1,
                typ,
            },
            ValueRecordWithType::BigInt {
                b: b2,
                negative: n2,
                ..
            },
        ) => {
            let res = bigint_from_parts(&b1, n1) - bigint_from_parts(&b2, n2);
            Ok(valuerecord_from_bigint(res, &typ))
        }

        (ValueRecordWithType::BigInt { b, negative, typ }, ValueRecordWithType::Int { i, .. }) => {
            let res = bigint_from_parts(&b, negative) - BigInt::from(i);
            Ok(valuerecord_from_bigint(res, &typ))
        }

        (ValueRecordWithType::Int { i, .. }, ValueRecordWithType::BigInt { b, negative, typ }) => {
            let res = BigInt::from(i) - bigint_from_parts(&b, negative);
            Ok(valuerecord_from_bigint(res, &typ))
        }

        (ValueRecordWithType::BigInt { b, negative, .. }, ValueRecordWithType::Float { f, typ }) => {
            if let Some(b) = bigint_from_parts(&b, negative).to_f64() {
                Ok(ValueRecordWithType::Float { f: b - f, typ })
            } else {
                let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                err_value.msg = "- not defined for these values".to_string();
                Err(err_value)
            }
        }

        (ValueRecordWithType::Float { f, typ }, ValueRecordWithType::BigInt { b, negative, .. }) => {
            if let Some(b) = bigint_from_parts(&b, negative).to_f64() {
                Ok(ValueRecordWithType::Float { f: f - b, typ })
            } else {
                let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                err_value.msg = "- not defined for these values".to_string();
                Err(err_value)
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
pub fn operator_mult(
    v1: ValueRecordWithType,
    v2: ValueRecordWithType,
    eval_error_type: &Type,
) -> Result<ValueRecordWithType, Value> {
    match (v1, v2) {
        (ValueRecordWithType::Int { i: i1, typ }, ValueRecordWithType::Int { i: i2, .. }) => {
            Ok(ValueRecordWithType::Int { i: i1 * i2, typ })
        }

        (ValueRecordWithType::Float { f: f1, typ }, ValueRecordWithType::Float { f: f2, .. }) => {
            Ok(ValueRecordWithType::Float { f: f1 * f2, typ })
        }

        (ValueRecordWithType::Int { i, .. }, ValueRecordWithType::Float { f, typ })
        | (ValueRecordWithType::Float { f, typ }, ValueRecordWithType::Int { i, .. }) => {
            Ok(ValueRecordWithType::Float {
                f: i as f64 * f,
                typ,
            })
        }

        (
            ValueRecordWithType::BigInt {
                b: b1,
                negative: n1,
                typ,
            },
            ValueRecordWithType::BigInt {
                b: b2,
                negative: n2,
                ..
            },
        ) => {
            let res = bigint_from_parts(&b1, n1) * bigint_from_parts(&b2, n2);
            Ok(valuerecord_from_bigint(res, &typ))
        }

        (ValueRecordWithType::BigInt { b, negative, typ }, ValueRecordWithType::Int { i, .. }) => {
            let res = bigint_from_parts(&b, negative) * BigInt::from(i);
            Ok(valuerecord_from_bigint(res, &typ))
        }

        (ValueRecordWithType::Int { i, .. }, ValueRecordWithType::BigInt { b, negative, typ }) => {
            let res = BigInt::from(i) * bigint_from_parts(&b, negative);
            Ok(valuerecord_from_bigint(res, &typ))
        }

        (
            ValueRecordWithType::BigInt { b, negative, .. },
            ValueRecordWithType::Float { f, typ },
        )
        | (
            ValueRecordWithType::Float { f, typ },
            ValueRecordWithType::BigInt { b, negative, .. },
        ) => {
            if let Some(b) = bigint_from_parts(&b, negative).to_f64() {
                Ok(ValueRecordWithType::Float { f: b * f, typ })
            } else {
                let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                err_value.msg = "* not defined for these values".to_string();
                Err(err_value)
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
pub fn operator_div(
    v1: ValueRecordWithType,
    v2: ValueRecordWithType,
    eval_error_type: &Type,
) -> Result<ValueRecordWithType, Value> {
    match (v1, v2) {
        (ValueRecordWithType::Int { i: i1, typ }, ValueRecordWithType::Int { i: i2, .. }) => {
            Ok(ValueRecordWithType::Int { i: i1 / i2, typ })
        }

        (ValueRecordWithType::Float { f: f1, typ }, ValueRecordWithType::Float { f: f2, .. }) => {
            Ok(ValueRecordWithType::Float { f: f1 / f2, typ })
        }

        (ValueRecordWithType::Int { i, .. }, ValueRecordWithType::Float { f, typ }) => {
            Ok(ValueRecordWithType::Float {
                f: i as f64 / f,
                typ,
            })
        }

        (ValueRecordWithType::Float { f, typ }, ValueRecordWithType::Int { i, .. }) => {
            Ok(ValueRecordWithType::Float {
                f: f / i as f64,
                typ,
            })
        }

        (
            ValueRecordWithType::BigInt {
                b: b1,
                negative: n1,
                typ,
            },
            ValueRecordWithType::BigInt {
                b: b2,
                negative: n2,
                ..
            },
        ) => {
            let res = bigint_from_parts(&b1, n1) / bigint_from_parts(&b2, n2);
            Ok(valuerecord_from_bigint(res, &typ))
        }

        (ValueRecordWithType::BigInt { b, negative, typ }, ValueRecordWithType::Int { i, .. }) => {
            let res = bigint_from_parts(&b, negative) / BigInt::from(i);
            Ok(valuerecord_from_bigint(res, &typ))
        }

        (ValueRecordWithType::Int { i, .. }, ValueRecordWithType::BigInt { b, negative, typ }) => {
            let res = BigInt::from(i) / bigint_from_parts(&b, negative);
            Ok(valuerecord_from_bigint(res, &typ))
        }

        (ValueRecordWithType::BigInt { b, negative, .. }, ValueRecordWithType::Float { f, typ }) => {
            if let Some(b) = bigint_from_parts(&b, negative).to_f64() {
                Ok(ValueRecordWithType::Float { f: b / f, typ })
            } else {
                let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                err_value.msg = "/ not defined for these values".to_string();
                Err(err_value)
            }
        }

        (ValueRecordWithType::Float { f, typ }, ValueRecordWithType::BigInt { b, negative, .. }) => {
            if let Some(b) = bigint_from_parts(&b, negative).to_f64() {
                Ok(ValueRecordWithType::Float { f: f / b, typ })
            } else {
                let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                err_value.msg = "/ not defined for these values".to_string();
                Err(err_value)
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
pub fn operator_rem(
    v1: ValueRecordWithType,
    v2: ValueRecordWithType,
    eval_error_type: &Type,
) -> Result<ValueRecordWithType, Value> {
    match (v1, v2) {
        (ValueRecordWithType::Int { i: i1, typ }, ValueRecordWithType::Int { i: i2, .. }) => {
            Ok(ValueRecordWithType::Int { i: i1 % i2, typ })
        }

        (ValueRecordWithType::Float { f: f1, typ }, ValueRecordWithType::Float { f: f2, .. }) => {
            Ok(ValueRecordWithType::Float { f: f1 % f2, typ })
        }

        (ValueRecordWithType::Int { i, .. }, ValueRecordWithType::Float { f, typ }) => {
            Ok(ValueRecordWithType::Float {
                f: i as f64 % f,
                typ,
            })
        }

        (ValueRecordWithType::Float { f, typ }, ValueRecordWithType::Int { i, .. }) => {
            Ok(ValueRecordWithType::Float {
                f: f % i as f64,
                typ,
            })
        }

        (
            ValueRecordWithType::BigInt {
                b: b1,
                negative: n1,
                typ,
            },
            ValueRecordWithType::BigInt {
                b: b2,
                negative: n2,
                ..
            },
        ) => {
            let res = bigint_from_parts(&b1, n1) % bigint_from_parts(&b2, n2);
            Ok(valuerecord_from_bigint(res, &typ))
        }

        (ValueRecordWithType::BigInt { b, negative, typ }, ValueRecordWithType::Int { i, .. }) => {
            let res = bigint_from_parts(&b, negative) % BigInt::from(i);
            Ok(valuerecord_from_bigint(res, &typ))
        }

        (ValueRecordWithType::Int { i, .. }, ValueRecordWithType::BigInt { b, negative, typ }) => {
            let res = BigInt::from(i) % bigint_from_parts(&b, negative);
            Ok(valuerecord_from_bigint(res, &typ))
        }

        (ValueRecordWithType::BigInt { b, negative, .. }, ValueRecordWithType::Float { f, typ }) => {
            if let Some(b) = bigint_from_parts(&b, negative).to_f64() {
                Ok(ValueRecordWithType::Float { f: b % f, typ })
            } else {
                let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                err_value.msg = "% not defined for these values".to_string();
                Err(err_value)
            }
        }

        (ValueRecordWithType::Float { f, typ }, ValueRecordWithType::BigInt { b, negative, .. }) => {
            if let Some(b) = bigint_from_parts(&b, negative).to_f64() {
                Ok(ValueRecordWithType::Float { f: f % b, typ })
            } else {
                let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                err_value.msg = "% not defined for these values".to_string();
                Err(err_value)
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
pub fn operator_equal(
    v1: ValueRecordWithType,
    v2: ValueRecordWithType,
    _eval_error_type: &Type,
) -> Result<ValueRecordWithType, Value> {
    let res = match (v1, v2) {
        (ValueRecordWithType::Bool { b: b1, .. }, ValueRecordWithType::Bool { b: b2, .. }) => b1 == b2,

        (ValueRecordWithType::Int { i: i1, .. }, ValueRecordWithType::Int { i: i2, .. }) => i1 == i2,

        (
            ValueRecordWithType::BigInt {
                b: b1,
                negative: n1,
                ..
            },
            ValueRecordWithType::BigInt {
                b: b2,
                negative: n2,
                ..
            },
        ) => bigint_from_parts(&b1, n1) == bigint_from_parts(&b2, n2),

        (ValueRecordWithType::BigInt { b, negative, .. }, ValueRecordWithType::Int { i, .. }) => {
            bigint_from_parts(&b, negative) == BigInt::from(i)
        }

        (ValueRecordWithType::Int { i, .. }, ValueRecordWithType::BigInt { b, negative, .. }) => {
            BigInt::from(i) == bigint_from_parts(&b, negative)
        }

        (ValueRecordWithType::String { text: s1, .. }, ValueRecordWithType::String { text: s2, .. }) => {
            s1 == s2
        }

        (ValueRecordWithType::Int { i, .. }, ValueRecordWithType::Float { f, .. }) => (i as f64) == f,

        (ValueRecordWithType::Float { f, .. }, ValueRecordWithType::Int { i, .. }) => f == i as f64,

        (ValueRecordWithType::BigInt { b, negative, .. }, ValueRecordWithType::Float { f, .. })
        | (ValueRecordWithType::Float { f, .. }, ValueRecordWithType::BigInt { b, negative, .. }) => {
            if let Some(b) = bigint_from_parts(&b, negative).to_f64() {
                b == f
            } else {
                false
            }
        }

        (ValueRecordWithType::Float { f: f1, .. }, ValueRecordWithType::Float { f: f2, .. }) => f1 == f2,

        _ => {
            // TODO: discuss if error or false on different types. Maybe change the behaviour based on the targeted language?
            false
        }
    };

    Ok(ValueRecordWithType::Bool {
        b: res,
        typ: bool_type_record(),
    })
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_not_equal(
    v1: ValueRecordWithType,
    v2: ValueRecordWithType,
    eval_error_type: &Type,
) -> Result<ValueRecordWithType, Value> {
    let equal_check = operator_equal(v1, v2, eval_error_type);
    if let Ok(ValueRecordWithType::Bool { b: res, .. }) = equal_check {
        Ok(ValueRecordWithType::Bool {
            b: !res,
            typ: bool_type_record(),
        })
    } else {
        equal_check
    }
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_less(
    v1: ValueRecordWithType,
    v2: ValueRecordWithType,
    eval_error_type: &Type,
) -> Result<ValueRecordWithType, Value> {
    let res = match (v1, v2) {
        (ValueRecordWithType::Int { i: i1, .. }, ValueRecordWithType::Int { i: i2, .. }) => i1 < i2,

        (ValueRecordWithType::Float { f: f1, .. }, ValueRecordWithType::Float { f: f2, .. }) => f1 < f2,

        (ValueRecordWithType::Int { i, .. }, ValueRecordWithType::Float { f, .. }) => (i as f64) < f,

        (ValueRecordWithType::Float { f, .. }, ValueRecordWithType::Int { i, .. }) => f < i as f64,

        (
            ValueRecordWithType::BigInt {
                b: b1,
                negative: n1,
                ..
            },
            ValueRecordWithType::BigInt {
                b: b2,
                negative: n2,
                ..
            },
        ) => bigint_from_parts(&b1, n1) < bigint_from_parts(&b2, n2),

        (ValueRecordWithType::BigInt { b, negative, .. }, ValueRecordWithType::Int { i, .. }) => {
            bigint_from_parts(&b, negative) < BigInt::from(i)
        }

        (ValueRecordWithType::Int { i, .. }, ValueRecordWithType::BigInt { b, negative, .. }) => {
            BigInt::from(i) < bigint_from_parts(&b, negative)
        }

        (ValueRecordWithType::BigInt { b, negative, .. }, ValueRecordWithType::Float { f, .. }) => {
            if let Some(b) = bigint_from_parts(&b, negative).to_f64() {
                b < f
            } else {
                false
            }
        }

        (ValueRecordWithType::Float { f, .. }, ValueRecordWithType::BigInt { b, negative, .. }) => {
            if let Some(b) = bigint_from_parts(&b, negative).to_f64() {
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

    Ok(ValueRecordWithType::Bool {
        b: res,
        typ: bool_type_record(),
    })
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_less_equal(
    v1: ValueRecordWithType,
    v2: ValueRecordWithType,
    eval_error_type: &Type,
) -> Result<ValueRecordWithType, Value> {
    let res = match (v1, v2) {
        (ValueRecordWithType::Int { i: i1, .. }, ValueRecordWithType::Int { i: i2, .. }) => i1 <= i2,

        (ValueRecordWithType::Float { f: f1, .. }, ValueRecordWithType::Float { f: f2, .. }) => f1 <= f2,

        (ValueRecordWithType::Int { i, .. }, ValueRecordWithType::Float { f, .. }) => (i as f64) <= f,

        (ValueRecordWithType::Float { f, .. }, ValueRecordWithType::Int { i, .. }) => f <= i as f64,

        (
            ValueRecordWithType::BigInt {
                b: b1,
                negative: n1,
                ..
            },
            ValueRecordWithType::BigInt {
                b: b2,
                negative: n2,
                ..
            },
        ) => bigint_from_parts(&b1, n1) <= bigint_from_parts(&b2, n2),

        (ValueRecordWithType::BigInt { b, negative, .. }, ValueRecordWithType::Int { i, .. }) => {
            bigint_from_parts(&b, negative) <= BigInt::from(i)
        }

        (ValueRecordWithType::Int { i, .. }, ValueRecordWithType::BigInt { b, negative, .. }) => {
            BigInt::from(i) <= bigint_from_parts(&b, negative)
        }

        (ValueRecordWithType::BigInt { b, negative, .. }, ValueRecordWithType::Float { f, .. }) => {
            if let Some(b) = bigint_from_parts(&b, negative).to_f64() {
                b <= f
            } else {
                false
            }
        }

        (ValueRecordWithType::Float { f, .. }, ValueRecordWithType::BigInt { b, negative, .. }) => {
            if let Some(b) = bigint_from_parts(&b, negative).to_f64() {
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

    Ok(ValueRecordWithType::Bool {
        b: res,
        typ: bool_type_record(),
    })
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_greater(
    v1: ValueRecordWithType,
    v2: ValueRecordWithType,
    eval_error_type: &Type,
) -> Result<ValueRecordWithType, Value> {
    let res = match (v1, v2) {
        (ValueRecordWithType::Int { i: i1, .. }, ValueRecordWithType::Int { i: i2, .. }) => i1 > i2,

        (ValueRecordWithType::Float { f: f1, .. }, ValueRecordWithType::Float { f: f2, .. }) => f1 > f2,

        (ValueRecordWithType::Int { i, .. }, ValueRecordWithType::Float { f, .. }) => (i as f64) > f,

        (ValueRecordWithType::Float { f, .. }, ValueRecordWithType::Int { i, .. }) => f > i as f64,

        (
            ValueRecordWithType::BigInt {
                b: b1,
                negative: n1,
                ..
            },
            ValueRecordWithType::BigInt {
                b: b2,
                negative: n2,
                ..
            },
        ) => bigint_from_parts(&b1, n1) > bigint_from_parts(&b2, n2),

        (ValueRecordWithType::BigInt { b, negative, .. }, ValueRecordWithType::Int { i, .. }) => {
            bigint_from_parts(&b, negative) > BigInt::from(i)
        }

        (ValueRecordWithType::Int { i, .. }, ValueRecordWithType::BigInt { b, negative, .. }) => {
            BigInt::from(i) > bigint_from_parts(&b, negative)
        }

        (ValueRecordWithType::BigInt { b, negative, .. }, ValueRecordWithType::Float { f, .. }) => {
            if let Some(b) = bigint_from_parts(&b, negative).to_f64() {
                b > f
            } else {
                false
            }
        }

        (ValueRecordWithType::Float { f, .. }, ValueRecordWithType::BigInt { b, negative, .. }) => {
            if let Some(b) = bigint_from_parts(&b, negative).to_f64() {
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

    Ok(ValueRecordWithType::Bool {
        b: res,
        typ: bool_type_record(),
    })
}

// TODO: eventually reuse Error case in ValueRecord
#[allow(clippy::result_large_err)]
pub fn operator_greater_equal(
    v1: ValueRecordWithType,
    v2: ValueRecordWithType,
    eval_error_type: &Type,
) -> Result<ValueRecordWithType, Value> {
    let res = match (v1, v2) {
        (ValueRecordWithType::Int { i: i1, .. }, ValueRecordWithType::Int { i: i2, .. }) => i1 >= i2,

        (ValueRecordWithType::Float { f: f1, .. }, ValueRecordWithType::Float { f: f2, .. }) => f1 >= f2,

        (ValueRecordWithType::Int { i, .. }, ValueRecordWithType::Float { f, .. }) => (i as f64) >= f,

        (ValueRecordWithType::Float { f, .. }, ValueRecordWithType::Int { i, .. }) => f >= i as f64,

        (
            ValueRecordWithType::BigInt {
                b: b1,
                negative: n1,
                ..
            },
            ValueRecordWithType::BigInt {
                b: b2,
                negative: n2,
                ..
            },
        ) => bigint_from_parts(&b1, n1) >= bigint_from_parts(&b2, n2),

        (ValueRecordWithType::BigInt { b, negative, .. }, ValueRecordWithType::Int { i, .. }) => {
            bigint_from_parts(&b, negative) >= BigInt::from(i)
        }

        (ValueRecordWithType::Int { i, .. }, ValueRecordWithType::BigInt { b, negative, .. }) => {
            BigInt::from(i) >= bigint_from_parts(&b, negative)
        }

        (ValueRecordWithType::BigInt { b, negative, .. }, ValueRecordWithType::Float { f, .. }) => {
            if let Some(b) = bigint_from_parts(&b, negative).to_f64() {
                b >= f
            } else {
                false
            }
        }

        (ValueRecordWithType::Float { f, .. }, ValueRecordWithType::BigInt { b, negative, .. }) => {
            if let Some(b) = bigint_from_parts(&b, negative).to_f64() {
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

    Ok(ValueRecordWithType::Bool {
        b: res,
        typ: bool_type_record(),
    })
}
