pub fn add(left: u64, right: u64) -> u64 {
    left + right
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_works() {
        let result = add(2, 2);
        let a = 2;
        assert_eq!(result, 2);
    }

    #[test]
    fn it_works_2() {
        let result = add(2, 5);
        println!("test 2");
        assert_eq!(result, 7);
    }
}
