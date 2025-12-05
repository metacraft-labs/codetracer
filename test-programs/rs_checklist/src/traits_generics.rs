use crate::ChecklistResult;
use std::future::Future;
use std::marker::PhantomData;

pub fn run() -> ChecklistResult {
    trait_basics();
    associated_items_and_gats();
    impl_trait_samples();
    async_trait_example();
    const_generics_demo();
    trait_objects();
    Ok(())
}

trait Describable {
    const KIND: &'static str;
    fn describe(&self) -> String {
        format!("default description for {}", Self::KIND)
    }
}

trait Debuggable: Describable {
    fn debug_line(&self) -> String;
}

struct Admin {
    name: String,
}

impl Describable for Admin {
    const KIND: &'static str = "admin";
    fn describe(&self) -> String {
        format!("Admin named {}", self.name)
    }
}

impl Debuggable for Admin {
    fn debug_line(&self) -> String {
        format!("Debuggable {} ({})", self.name, Self::KIND)
    }
}

struct Guest;

impl Describable for Guest {
    const KIND: &'static str = "guest";
}

fn trait_basics() {
    let admin = Admin { name: "Ada".into() };
    let guest = Guest;
    println!("[tg-01] {}", admin.describe());
    println!("[tg-02] {}", guest.describe());
    println!("[tg-03] {:?}", admin.debug_line());
}

trait Inventory {
    type Item;
    type Iter<'a>: Iterator<Item = &'a Self::Item>
    where
        Self: 'a;

    const CAPACITY: usize;

    fn iter(&self) -> Self::Iter<'_>;
}

struct Shelf<T> {
    slots: Vec<T>,
}

impl<T> Inventory for Shelf<T> {
    type Item = T;
    type Iter<'a>
        = std::slice::Iter<'a, T>
    where
        T: 'a;

    const CAPACITY: usize = 16;

    fn iter(&self) -> Self::Iter<'_> {
        self.slots.iter()
    }
}

fn associated_items_and_gats() {
    let shelf = Shelf {
        slots: vec!["a", "b", "c"],
    };
    let collected: Vec<_> = shelf.iter().collect();
    println!(
        "[tg-04] Shelf capacity={} collected {:?}",
        Shelf::<&str>::CAPACITY,
        collected
    );
}

fn make_iter() -> impl Iterator<Item = i32> {
    0..3
}

fn takes_impl(iter: impl Iterator<Item = i32>) -> i32 {
    iter.sum()
}

fn impl_trait_samples() {
    let iter = make_iter();
    let total = takes_impl(iter);
    println!("[tg-05] impl Trait sum {total}");
}

trait AsyncFetcher {
    type Output;
    fn fetch(&self) -> impl Future<Output = Self::Output> + Send;
}

struct HttpFetcher;

impl AsyncFetcher for HttpFetcher {
    type Output = Result<String, String>;

    async fn fetch(&self) -> Self::Output {
        Ok("pretend network response".into())
    }
}

fn async_trait_example() {
    let fetcher = HttpFetcher;
    let result = futures::executor::block_on(fetcher.fetch());
    println!("[tg-06] async trait result {:?}", result);
}

#[derive(Debug)]
struct ArrayBox<T, const N: usize> {
    inner: [T; N],
}

impl<T: Default + Copy, const N: usize> ArrayBox<T, N> {
    fn filled(value: T) -> Self {
        Self { inner: [value; N] }
    }
}

impl<T: Default + Copy, const N: usize> Default for ArrayBox<T, N> {
    fn default() -> Self {
        Self::filled(Default::default())
    }
}

#[derive(Debug)]
struct PhantomHolder<T> {
    marker: PhantomData<T>,
}

fn const_generics_demo() {
    let arr3 = ArrayBox::<i32, 3>::filled(1);
    let arr5 = ArrayBox::<i32, 5>::filled(2);
    println!(
        "[tg-07] const generics len3={} len5={}",
        arr3.inner.len(),
        arr5.inner.len()
    );

    let _phantom: PhantomHolder<&'static str> = PhantomHolder {
        marker: PhantomData,
    };
    println!(
        "[tg-08] PhantomData keeps type info {:?}",
        std::any::type_name::<PhantomHolder<&str>>()
    );
}

trait Shape: Send + Sync {
    fn area(&self) -> f64;
}

struct Circle {
    radius: f64,
}

struct Rectangle {
    width: f64,
    height: f64,
}

impl Shape for Circle {
    fn area(&self) -> f64 {
        std::f64::consts::PI * self.radius * self.radius
    }
}

impl Shape for Rectangle {
    fn area(&self) -> f64 {
        self.width * self.height
    }
}

fn trait_objects() {
    let shapes: Vec<Box<dyn Shape>> = vec![
        Box::new(Circle { radius: 2.0 }),
        Box::new(Rectangle {
            width: 3.0,
            height: 4.0,
        }),
    ];
    let areas: Vec<_> = shapes.iter().map(|s| s.area()).collect();
    println!("[tg-09] dyn Shape areas {:?}", areas);
}
