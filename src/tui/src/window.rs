use crate::panel::{HorizontalCoord, PanelCalculationError, VerticalCoord};
use crossterm::{
    cursor, queue,
    style::{self, StyledContent, Stylize},
};
use std::error::Error;

// based on and characters copied from
// https://en.wikipedia.org/wiki/Box-drawing_character
pub fn draw_top_left_corner(x: HorizontalCoord, y: VerticalCoord) -> Result<(), Box<dyn Error>> {
    draw_text(x, y, "┏")
}

pub fn draw_top_right_corner(x: HorizontalCoord, y: VerticalCoord) -> Result<(), Box<dyn Error>> {
    draw_text(x, y, "┓")
}

pub fn draw_bottom_left_corner(x: HorizontalCoord, y: VerticalCoord) -> Result<(), Box<dyn Error>> {
    draw_text(x, y, "┗ ")
}

pub fn draw_bottom_right_corner(
    x: HorizontalCoord,
    y: VerticalCoord,
) -> Result<(), Box<dyn Error>> {
    draw_text(x, y, "┛")
}

pub fn draw_text(x: HorizontalCoord, y: VerticalCoord, text: &str) -> Result<(), Box<dyn Error>> {
    draw_styled_text(x, y, text.white())
}

pub fn draw_styled_text(
    x: HorizontalCoord,
    y: VerticalCoord,
    text: StyledContent<&str>,
) -> Result<(), Box<dyn Error>> {
    let mut stdout = std::io::stdout();
    queue!(
        stdout,
        cursor::MoveTo(x.as_u16(), y.as_u16()),
        style::PrintStyledContent(text)
    )?;
    Ok(())
}

pub fn draw_horizontal_border(
    start_y: VerticalCoord,
    left_x: HorizontalCoord,
    right_x: HorizontalCoord,
    symbol: char,
) -> Result<(), Box<dyn Error>> {
    let mut stdout = std::io::stdout();
    let symbol_text = format!("{symbol}");
    let (length, overflows) = right_x.overflowing_sub(left_x);
    if overflows {
        return Err(Box::new(PanelCalculationError {}));
    }

    queue!(
        stdout,
        cursor::MoveTo(left_x.as_u16(), start_y.as_u16()),
        style::PrintStyledContent(str::repeat(&symbol_text, length.as_u16() as usize).white())
    )?;

    Ok(())
}

pub fn draw_vertical_border(
    start_x: HorizontalCoord,
    top_y: VerticalCoord,
    bottom_y: VerticalCoord,
    symbol: char,
) -> Result<(), Box<dyn Error>> {
    let mut stdout = std::io::stdout();
    let symbol_text = format!("{}", symbol);
    let content = style::PrintStyledContent(symbol_text.white());
    for y in top_y.as_u16()..bottom_y.as_u16() {
        queue!(stdout, cursor::MoveTo(start_x.as_u16(), y), content.clone())?;
    }

    Ok(())
}
