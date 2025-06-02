use crate::component::Component;
use crate::panel::Panel;
use std::error::Error;

#[derive(Default, Debug)]
pub struct StatusComponent {
    _panel: Panel,
    message: String,
}

impl StatusComponent {
    pub fn new(panel: Panel, message: &str) -> StatusComponent {
        StatusComponent {
            _panel: panel,
            message: message.to_string(),
        }
    }
}

impl Component for StatusComponent {
    fn panel(&self) -> Panel {
        self._panel
    }

    fn name(&self) -> String {
        "status".to_string()
    }

    fn render(&mut self) -> Result<(), Box<dyn Error>> {
        self.draw_box()?;
        Ok(())
    }
}
