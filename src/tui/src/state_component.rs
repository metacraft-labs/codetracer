use crate::component::Component;
use crate::panel::Panel;
use crate::value::Value;
use std::error::Error;

#[derive(Default, Debug)]
pub struct StateComponent {
    _panel: Panel,
    variables: Vec<(String, Value)>,
}

impl StateComponent {
    pub fn new(panel: Panel) -> StateComponent {
        StateComponent {
            _panel: panel,
            variables: vec![],
        }
    }
}

impl Component for StateComponent {
    fn panel(&self) -> Panel {
        self._panel
    }

    fn name(&self) -> String {
        "state".to_string()
    }

    fn render(&mut self) -> Result<(), Box<dyn Error>> {
        self.draw_box()?;
        Ok(())
    }
}
