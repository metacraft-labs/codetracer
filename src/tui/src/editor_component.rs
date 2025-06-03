use std::cmp::{max, min};
use std::error::Error;
use std::io;
use std::io::Write;
use std::path::PathBuf;
use std::str;

use crossterm::style::Stylize;

use crate::component::Component;
use crate::panel::{height, width, Panel};
use crate::task::{
    EventId, FlowUpdate, FlowUpdateStateKind, Iteration, Location, LoopId, MoveState, Position,
    NOT_IN_A_LOOP, NO_LOOP_ID,
};
use crate::value::text_repr;
use crate::window;

#[derive(Default, Debug)]
enum LineKind {
    #[default]
    Normal,
    On,
    Visited,
    VisitedInADifferentIteration,
    NonVisited,
}

#[derive(Default, Debug)]
enum EditorStatus {
    #[default]
    Loading,
    Problem(String),
    Ready,
}

#[derive(Default, Debug)]
pub struct EditorComponent {
    _panel: Panel,
    status: EditorStatus,
    source_lines: Vec<String>,
    line: usize,
    filename: String,
    current_line_iteration: Iteration,
    current_loop: LoopId,
    location: Location,
    flow_update: FlowUpdate,
}

impl EditorComponent {
    pub fn new(panel: Panel, filename: &str) -> EditorComponent {
        EditorComponent {
            _panel: panel,
            status: EditorStatus::Loading,
            filename: filename.to_string(),
            source_lines: vec![],
            line: 0,
            current_line_iteration: NOT_IN_A_LOOP,
            current_loop: NO_LOOP_ID,
            location: Location::default(),
            flow_update: FlowUpdate::default(),
        }
    }
}

impl Component for EditorComponent {
    fn panel(&self) -> Panel {
        self._panel
    }

    fn name(&self) -> String {
        "code viewer".to_string()
    }

    fn on_complete_move(
        &mut self,
        move_state: MoveState,
        event_id: EventId,
    ) -> Result<(), Box<dyn Error>> {
        let raw_bytes = std::fs::read(PathBuf::from(&move_state.location.path))?;
        let source = str::from_utf8(&raw_bytes)?.to_string();
        self.source_lines = source.split('\n').map(|line| line.to_string()).collect();
        self.filename = move_state.location.clone().path;
        self.line = move_state.location.line as usize;
        self.location = move_state.location;
        self.status = EditorStatus::Ready;
        (self.current_line_iteration, self.current_loop) =
            self.current_iteration_and_loop_for(self.line);
        self.render()?;
        let mut stdout = io::stdout();
        stdout.flush()?;
        Ok(())
    }

    fn on_updated_flow(
        &mut self,
        flow_update: FlowUpdate,
        event_id: EventId,
    ) -> Result<(), Box<dyn Error>> {
        self.flow_update = flow_update;
        self.render()?;
        let mut stdout = io::stdout();
        stdout.flush()?;
        Ok(())
    }

    fn render(&mut self) -> Result<(), Box<dyn Error>> {
        self.draw_box()?;

        let left_x = self.panel().x() + width(2);
        let y = self.panel().y() + height(17);

        eprintln!("{:?}", self.status);

        match &self.status {
            EditorStatus::Loading => {
                window::draw_styled_text(left_x, y, "Loading".blue())?;
            }
            EditorStatus::Problem(problem) => {
                let t: &str = &format!("problem: {problem}");
                window::draw_styled_text(left_x, y, t.red())?;
            }
            EditorStatus::Ready => {
                self.render_source()?;
            }
        }
        Ok(())
    }
}

impl EditorComponent {
    fn in_current_function(&self, line_number: usize) -> bool {
        // only if sure: might have false negatives if no valid
        // function first/last
        if self.location.function_first <= 0 || self.location.function_last <= 0 {
            false
        } else {
            line_number as i64 >= self.location.function_first
                && line_number as i64 <= self.location.function_last
        }
    }

    //   fn current_loop_and_iteration_and_step(&self) -> (Loop, Iteration, S)
    fn current_iteration_and_loop_for(&self, line_number: usize) -> (Iteration, LoopId) {
        if self.flow_update.view_updates.len() > 0 {
            let view_update = &self.flow_update.view_updates[0];
            let position = Position::new(line_number as i64);
            if view_update.position_step_counts.contains_key(&position) {
                let step_counts = view_update.position_step_counts.get(&position).unwrap();
                let mut step = view_update.steps[step_counts[0].as_usize()].clone();

                for (i, step_count) in step_counts.iter().enumerate() {
                    let step_i = view_update.steps[step_count.as_usize()].clone();
                    if self.location.rr_ticks >= step_i.rr_ticks
                        && (i >= step_counts.len() - 1
                            || self.location.rr_ticks
                                < view_update.steps[step_counts[i + 1].as_usize()].rr_ticks)
                    {
                        step = step_i;
                        break;
                    }
                }
                // eprintln!("{:?}", step.r#loop);
                (step.iteration, step.r#loop)
            } else {
                // we expect this to be called only for lines with step counts or visited
                // unreachable!()
                (NOT_IN_A_LOOP, NO_LOOP_ID)
            }
        } else {
            (NOT_IN_A_LOOP, NO_LOOP_ID)
        }
        // let loop_info = if step.r#loop.is_none() {
        //         ITERATION_NOT_IN_A_LOOP
        //     } else if step.r#loop.as_usize() < view_update.loops.len() {
        //         step.iteration
        //         let loop_object = &view_update.loops[step.r#loop.as_usize()];
        //         format!("{}({}): ", step.iteration.as_usize(), loop_object.iteration.as_usize() + 1)
        //     } else {
        //         "<missing loop>:".to_string()
        //     };
    }

    fn line_kind(&self, line_number: usize) -> LineKind {
        // eprintln!("line_kind {} current: {}", line_number, self.line);
        if line_number == self.line {
            LineKind::On
        } else {
            if self.flow_update.status.kind != FlowUpdateStateKind::FlowNotLoading {
                let view_update = &self.flow_update.view_updates[0];
                // eprintln!("view_update positions {:?} and status {:?}", view_update.position_step_counts.clone(), self.flow_update.status.kind);
                if view_update
                    .position_step_counts
                    .contains_key(&Position::new(line_number as i64))
                {
                    let (iteration, loop_id) = self.current_iteration_and_loop_for(line_number);
                    if iteration.not_in_a_loop()
                        || self.current_loop == loop_id && self.current_line_iteration == iteration
                    {
                        LineKind::Visited
                    } else {
                        LineKind::VisitedInADifferentIteration
                    }
                } else {
                    if self.flow_update.status.kind != FlowUpdateStateKind::FlowFinished
                        || !self.in_current_function(line_number)
                    {
                        LineKind::Normal
                    } else {
                        LineKind::NonVisited
                    }
                }
            } else {
                LineKind::Normal
            }
        }
    }

    fn load_flow_info(&self, line_number: usize) -> Result<String, Box<dyn Error>> {
        if self.flow_update.view_updates.len() > 0 {
            let view_update = &self.flow_update.view_updates[0];
            let position = Position::new(line_number as i64);
            if view_update.position_step_counts.contains_key(&position) {
                let step_counts = view_update.position_step_counts.get(&position).unwrap();
                let mut step = view_update.steps[step_counts[0].as_usize()].clone();

                for (i, step_count) in step_counts.iter().enumerate() {
                    let step_i = view_update.steps[step_count.as_usize()].clone();
                    if self.location.rr_ticks >= step_i.rr_ticks
                        && (i >= step_counts.len() - 1
                            || self.location.rr_ticks
                                < view_update.steps[step_counts[i + 1].as_usize()].rr_ticks)
                    {
                        step = step_i;
                        break;
                    }
                }
                // eprintln!("{:?}", step.r#loop);
                let loop_info = if step.r#loop.is_none() {
                    "".to_string()
                } else if step.r#loop.as_usize() < view_update.loops.len() {
                    let loop_object = &view_update.loops[step.r#loop.as_usize()];
                    let loop_iteration_info = format!(
                        "{}({}): ",
                        step.iteration.as_usize(),
                        loop_object.iteration.as_usize() + 1
                    );
                    let loop_header_info = if loop_object.first == position {
                        let loop_id = step.r#loop.as_usize();
                        let iterations = loop_object.iteration.as_usize() + 1;
                        format!("loop #{loop_id}: {iterations} iterations: ")
                    } else if loop_object.last == position {
                        let loop_id = step.r#loop.as_usize();
                        format!("end of loop #{loop_id}")
                    } else {
                        "".to_string()
                    };
                    format!("{loop_header_info}{loop_iteration_info}")
                } else {
                    "<missing loop>:".to_string()
                };

                let value_info = step
                    .before_values
                    .iter()
                    .map(|(name, v)| format!("{}={}", name, text_repr(v)))
                    .collect::<Vec<String>>()
                    .join(" ");

                Ok(format!("{}{}", loop_info, value_info))
            } else {
                Ok("_".to_string())
            }
        } else {
            Ok("".to_string())
        }
    }

    fn render_source(&mut self) -> Result<(), Box<dyn Error>> {
        // TODO: flow visited style
        // maybe flow status too

        // TODO: show the current visible region, not just first n lines

        // left_x:1 <line> <source>
        // left_x:2
        // ..

        let start_line = max(self.line as i64 - 17, 1) as usize;
        let end_line = min(self.line + 17, self.source_lines.len());

        // eprintln!("{:?} {:?}", start_line, end_line);

        let empty_text = " ".repeat(self.panel().width().as_u16() as usize - 2);
        let empty: &str = &empty_text;

        for i in 0..38 {
            let left_x = self.panel().x() + width(2);
            let y = self.panel().y() + height(2 + i);

            window::draw_text(left_x, y, empty)?;
        }

        for line_number in start_line..end_line + 1 {
            let i = line_number - 1;
            let source_line = &self.source_lines[i];

            let text = format!("{:>4} | {:<80}", line_number, source_line);
            let flow_info = self.load_flow_info(line_number)?;
            let flow_info_text: &str = &flow_info;

            let left_x = self.panel().x() + width(2);
            let y = self.panel().y() + height((2 + line_number - start_line) as u16);
            let t: &str = &text;
            let line_kind = self.line_kind(line_number);
            eprintln!("line_kind result {line_number}: {line_kind:?}");

            match line_kind {
                LineKind::Normal => {
                    window::draw_text(left_x, y, &text)?;
                }
                LineKind::On => {
                    window::draw_styled_text(left_x, y, t.yellow())?;
                }
                LineKind::Visited => {
                    window::draw_styled_text(left_x, y, t.bold())?;
                }
                LineKind::VisitedInADifferentIteration => {
                    window::draw_styled_text(left_x, y, t.italic())?;
                }
                LineKind::NonVisited => {
                    window::draw_styled_text(left_x, y, t.dim())?;
                }
            }

            window::draw_styled_text(left_x + width(87), y, flow_info_text.blue())?;
        }

        Ok(())
    }
}
