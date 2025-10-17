use clap::ValueEnum;

#[derive(ValueEnum, Clone, Debug)]
pub enum Lang {
    Python,
    Ruby,
    Noir,
    Wasm,
    Small,
}

impl ToString for Lang {
    fn to_string(&self) -> String {
        match self {
            Lang::Python => String::from("python"),
            Lang::Ruby => String::from("ruby"),
            Lang::Noir => String::from("noir"),
            Lang::Wasm => String::from("wasm"),
            Lang::Small => String::from("small"),
        }
    }
}
