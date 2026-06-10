use ct_test_rust_fixture::add;

const FAKE: &str = "fn fake_without_attr() {}";

#[test]
fn integration_smoke() {
    assert_eq!(add(5, 6), 11);
}

#[test]
fn failing_integration() {
    assert_eq!(add(1, 1), 3);
}

mod api {
    #[test]
    fn nested_integration() {
        assert_eq!(1 + 2, 3);
    }
}
