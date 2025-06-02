use crate::panel::{height, width, Panel};
use crate::task::{EventId, FlowUpdate, MoveState};
use crate::window;
use std::error::Error;

pub trait Component: std::fmt::Debug + Send + Sync {
    fn panel(&self) -> Panel;
    fn render(&mut self) -> Result<(), Box<dyn Error>>;
    fn name(&self) -> String;
    fn on_complete_move(
        &mut self,
        move_state: MoveState,
        event_id: EventId,
    ) -> Result<(), Box<dyn Error>> {
        unimplemented!();
    }
    fn on_updated_flow(
        &mut self,
        flow_update: FlowUpdate,
        event_id: EventId,
    ) -> Result<(), Box<dyn Error>> {
        unimplemented!();
    }

    fn draw_box(&self) -> Result<(), Box<dyn Error>> {
        let left_x = self.panel().x();
        let right_x = left_x + self.panel().width();
        let top_y = self.panel().y();
        let bottom_y = top_y + self.panel().height();

        let before_center_x = left_x + self.panel().width() / 3;

        // let (last_vertical_y, overflows) = bottom_y.overflowing_sub_height(height(0));
        // if overflows {
        //   return Err(Box::new(PanelCalculationError {}));
        // }

        window::draw_top_left_corner(left_x, top_y)?;
        window::draw_top_right_corner(right_x, top_y)?;
        window::draw_bottom_left_corner(left_x, bottom_y)?;
        window::draw_bottom_right_corner(right_x, bottom_y)?;

        window::draw_horizontal_border(top_y, left_x + width(1), right_x, '━')?;
        window::draw_horizontal_border(bottom_y, left_x + width(1), right_x, '━')?;

        window::draw_vertical_border(left_x, top_y + height(1), bottom_y, '┃')?;
        window::draw_vertical_border(right_x, top_y + height(1), bottom_y, '┃')?;

        window::draw_text(before_center_x, top_y, &format!(" {} ", self.name()))?;

        Ok(())
    }
}
