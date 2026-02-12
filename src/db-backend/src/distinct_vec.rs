use std::fmt;
use std::marker::PhantomData;
use std::ops::{Index, IndexMut};

#[derive(Clone, Default)]
pub struct DistinctVec<IndexType: Into<usize>, ValueType: fmt::Debug> {
    pub items: Vec<ValueType>,
    index_type: PhantomData<IndexType>,
}

impl<IndexType: Into<usize>, ValueType: fmt::Debug> DistinctVec<IndexType, ValueType> {
    pub fn new() -> Self {
        DistinctVec {
            items: vec![],
            index_type: PhantomData,
        }
    }

    pub fn get(&self, index: IndexType) -> Option<&ValueType> {
        self.items.get(index.into())
    }

    /// Try to access a mutable element by index, returning `None` for
    /// out-of-bounds or negative indices (which wrap to very large usize values
    /// when the inner id type is a signed integer like `i64`).
    pub fn get_mut(&mut self, index: IndexType) -> Option<&mut ValueType> {
        self.items.get_mut(index.into())
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    pub fn push(&mut self, value: ValueType) {
        self.items.push(value);
    }

    pub fn pop(&mut self) -> Option<ValueType> {
        self.items.pop()
    }

    pub fn iter(&self) -> impl Iterator<Item = &ValueType> {
        self.items.iter()
    }

    pub fn iter_mut(&mut self) -> impl Iterator<Item = &mut ValueType> {
        self.items.iter_mut()
    }

    pub fn first(&self) -> Option<&ValueType> {
        self.items.first()
    }

    pub fn last(&self) -> Option<&ValueType> {
        self.items.last()
    }

    pub fn clear(&mut self) {
        self.items.clear();
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }
}

impl<IndexType: Into<usize>, ValueType: fmt::Debug> Index<IndexType> for DistinctVec<IndexType, ValueType> {
    type Output = ValueType;

    fn index(&self, index: IndexType) -> &Self::Output {
        &self.items[index.into()]
    }
}

impl<IndexType: Into<usize>, ValueType: fmt::Debug> IndexMut<IndexType> for DistinctVec<IndexType, ValueType> {
    // type Output = ValueType;

    fn index_mut(&mut self, index: IndexType) -> &mut ValueType {
        &mut self.items[index.into()]
    }
}

impl<IndexType: Into<usize>, ValueType: fmt::Debug> fmt::Debug for DistinctVec<IndexType, ValueType> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_list().entries(self.items.iter()).finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, Copy, Clone)]
    struct Width(u64);

    impl From<Width> for usize {
        fn from(val: Width) -> Self {
            val.0 as usize
        }
    }

    #[test]
    fn test_distinct_vec() {
        let mut distinct_vec = DistinctVec::<Width, String>::new();

        // println!("{:?}", distinct_vec);
        // assert_eq!(distinct_vec.(), "")

        assert_eq!(distinct_vec.len(), 0);

        distinct_vec.push("1".to_string());
        distinct_vec.push("2".to_string());

        assert_eq!(distinct_vec.len(), 2);
        assert_eq!(distinct_vec[Width(0)], "1".to_string());
        assert_eq!(distinct_vec[Width(1)], "2".to_string());

        assert_eq!(distinct_vec.pop(), Some("2".to_string()));

        assert_eq!(distinct_vec.len(), 1);

        assert_eq!(format!("{:?}", distinct_vec), "[\"1\"]".to_string());

        for text in distinct_vec.iter_mut() {
            text.push('1');
        }
        assert_eq!(distinct_vec[Width(0)], "11".to_string());

        distinct_vec.clear();

        assert_eq!(distinct_vec.len(), 0);
    }

    #[test]
    fn test_get_returns_none_for_out_of_bounds() {
        let mut distinct_vec = DistinctVec::<Width, String>::new();
        distinct_vec.push("a".to_string());

        // Valid index returns Some.
        assert_eq!(distinct_vec.get(Width(0)), Some(&"a".to_string()));
        // Out-of-bounds index returns None instead of panicking.
        assert_eq!(distinct_vec.get(Width(999)), None);
        // Very large index (simulating a wrapped negative i64) returns None.
        assert_eq!(distinct_vec.get(Width(u64::MAX)), None);
    }

    #[test]
    fn test_get_mut_returns_none_for_out_of_bounds() {
        let mut distinct_vec = DistinctVec::<Width, String>::new();
        distinct_vec.push("a".to_string());

        // Valid index returns Some and allows mutation.
        if let Some(val) = distinct_vec.get_mut(Width(0)) {
            *val = "b".to_string();
        }
        assert_eq!(distinct_vec[Width(0)], "b".to_string());
        // Out-of-bounds index returns None instead of panicking.
        assert!(distinct_vec.get_mut(Width(999)).is_none());
        // Very large index (simulating a wrapped negative i64) returns None.
        assert!(distinct_vec.get_mut(Width(u64::MAX)).is_none());
    }

    #[test]
    fn test_get_on_empty_vec() {
        let distinct_vec = DistinctVec::<Width, String>::new();
        assert!(distinct_vec.get(Width(0)).is_none());
    }
}
