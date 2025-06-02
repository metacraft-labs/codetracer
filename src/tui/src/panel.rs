use std::error::Error;
use std::fmt;
use std::ops;

#[derive(Copy, Clone, Default, Debug)]
pub struct Width(u16);

#[derive(Copy, Clone, Default, Debug)]
pub struct Height(u16);

#[derive(Copy, Clone, Default, Debug)]
pub struct Size {
    width: Width,
    height: Height,
}

#[derive(Copy, Clone, Default, Debug)]
pub struct HorizontalCoord(u16);

#[derive(Copy, Clone, Default, Debug)]
pub struct VerticalCoord(u16);

pub fn y_coord(coord: u16) -> VerticalCoord {
    VerticalCoord(coord)
}

pub fn x_coord(coord: u16) -> HorizontalCoord {
    HorizontalCoord(coord)
}

pub fn height(value: u16) -> Height {
    Height(value)
}

pub fn width(value: u16) -> Width {
    Width(value)
}

#[derive(Copy, Clone, Default, Debug)]
pub struct Coord {
    x: HorizontalCoord,
    y: VerticalCoord,
}

#[derive(Copy, Clone, Default, Debug)]
pub struct Panel {
    start: Coord,
    size: Size,
}

impl Panel {
    pub fn width(&self) -> Width {
        self.size.width
    }

    pub fn height(&self) -> Height {
        self.size.height
    }

    pub fn x(&self) -> HorizontalCoord {
        self.start.x
    }

    pub fn y(&self) -> VerticalCoord {
        self.start.y
    }
}

pub fn coord(x: u16, y: u16) -> Coord {
    Coord {
        x: HorizontalCoord(x),
        y: VerticalCoord(y),
    }
}

pub fn size(width: u16, height: u16) -> Size {
    Size {
        width: Width(width),
        height: Height(height),
    }
}

pub fn panel(coord: Coord, size: Size) -> Panel {
    Panel {
        start: coord,
        size: size,
    }
}

impl ops::Add<Width> for HorizontalCoord {
    type Output = HorizontalCoord;

    fn add(self, right: Width) -> HorizontalCoord {
        HorizontalCoord(self.0 + right.0)
    }
}

impl ops::Add<Height> for VerticalCoord {
    type Output = VerticalCoord;

    fn add(self, right: Height) -> VerticalCoord {
        VerticalCoord(self.0 + right.0)
    }
}

impl ops::Div<usize> for Width {
    type Output = Width;

    fn div(self, right: usize) -> Width {
        Width((self.0 as usize / right) as u16)
    }
}

impl HorizontalCoord {
    // underflow panics with -

    pub fn overflowing_sub(self, right: HorizontalCoord) -> (Width, bool) {
        let (diff, overflows) = self.0.overflowing_sub(right.0);
        (Width(diff), overflows)
    }

    pub fn as_u16(&self) -> u16 {
        self.0
    }
}

impl VerticalCoord {
    pub fn as_u16(&self) -> u16 {
        self.0
    }

    pub fn overflowing_sub_height(self, right: Height) -> (VerticalCoord, bool) {
        let (diff, overflows) = self.0.overflowing_sub(right.0);
        (VerticalCoord(diff), overflows)
    }
}

impl Width {
    pub fn as_u16(&self) -> u16 {
        self.0
    }
}

impl Height {
    pub fn as_u16(&self) -> u16 {
        self.0
    }
}

#[derive(Debug)]
pub struct PanelCalculationError {}

impl fmt::Display for PanelCalculationError {
    fn fmt(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
        write!(formatter, "panel calculation error")
    }
}

impl Error for PanelCalculationError {
    fn description(&self) -> &str {
        "panel calculation error"
    }
}
