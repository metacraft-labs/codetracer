pub fn add(left: i32, right: i32) -> i32 {
    left + right
}

mod nested;

#[cfg(test)]
mod tests {
    use super::*;

    const FAKE: &str = r#"
        #[test]
        fn fake_from_raw_string() {}
    "#;

    // #[test]
    // fn fake_from_line_comment() {}

    /*
    #[test]
    fn fake_from_block_comment() {}
    */

    #[test]
    fn unit_adds() {
        assert_eq!(add(2, 3), 5);
    }

    #[ignore]
    #[test]
    fn ignored_unit() {
        assert_eq!(add(1, 1), 2);
    }

    #[tokio::test]
    async fn tokio_async_unit() {
        assert_eq!(add(1, 2), 3);
    }

    mod inner {
        #[test]
        fn nested_unit() {
            assert_eq!(2 + 2, 4);
        }

        #[async_std::test]
        async fn async_std_nested() {
            assert_eq!(3 + 3, 6);
        }
    }
}
