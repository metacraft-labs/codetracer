//! The recorded terminal output as LINES, for `ct/load-terminal-lines`.
//!
//! The Terminal Output pane's line view asks for the window of lines it shows
//! (Viewport-Driven-Loading, Decided Q3): the engine splits the recorded
//! writes into lines once, and answers any window of them with the total.
//! Only the screen view, whose scrubber spans every write, loads every write
//! (`ct/load-terminal`), and only while it is shown.
//!
//! A line is kept as the raw pieces of the writes it is made of, escape
//! sequences included: the client's line builder
//! (`terminal_output_model.TerminalLineBuilder`) decodes the colours, exactly
//! as it decodes a whole stream, so the two views cannot disagree. Because a
//! colour set on an earlier line still applies, each line also carries the
//! SGR sequences in effect at its start (`prefix`), which the client feeds
//! before the line's pieces.
//!
//! Lines end at `\n`, as the client's line builder ends them. Escape
//! sequences follow ECMA-48 (CSI: `ESC [` parameters, intermediates, a final
//! byte in 0x40..=0x7E; OSC: `ESC ]` up to BEL or `ESC \`):
//! <https://ecma-international.org/publications-and-standards/standards/ecma-48/>.

use std::ops::Range;

use base64::Engine;
use serde::Serialize;

use crate::task::ProgramEvent;

/// The SGR sequences kept for a line's prefix. A program that never resets
/// its colours would otherwise grow the prefix without bound; past this many
/// the oldest are dropped, which can only lose an attribute a later sequence
/// has most likely overridden.
const MAX_PREFIX_SEQUENCES: usize = 256;

/// One piece of one write, inside one line (no `\n`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LineSegment {
    /// The write's index among the recorded writes.
    pub write: usize,
    /// The piece's byte range in that write's text.
    pub range: Range<usize>,
}

/// One line of the output.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TerminalLine {
    /// The SGR sequences in effect where the line starts.
    pub prefix: String,
    /// The pieces of writes the line is made of, in order. A line ended by a
    /// write that put nothing on it holds one empty piece of that write, so
    /// the line still belongs to a write (the client draws it clickable).
    pub segments: Vec<LineSegment>,
}

/// The output split into lines.
#[derive(Debug, Clone, Default)]
pub struct TerminalLines {
    pub lines: Vec<TerminalLine>,
    /// The output contains screen control — the alternate screen, absolute
    /// cursor addressing, erase in display or a full reset — so the pane
    /// offers the screen view. The same rule as the client's screen model
    /// (`TermScreen.sawScreenControl`).
    pub screen_offered: bool,
    /// For each write, the line holding its last visible piece, or `None` when
    /// the write put nothing on a line (escape sequences only).
    pub last_line_of_write: Vec<Option<usize>>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ScanState {
    Ground,
    Escape,
    Csi,
    Osc,
    OscEscape,
}

/// The splitter, fed write by write.
struct Splitter {
    out: TerminalLines,
    current: TerminalLine,
    current_has_text: bool,
    state: ScanState,
    /// The CSI sequence being read (from its `ESC`), and whether it is
    /// private (`?` / `<` / `=` / `>`) or has intermediates.
    sequence: String,
    /// The SGR sequences in effect, in order.
    sgr: Vec<String>,
}

impl Splitter {
    fn new() -> Self {
        Splitter {
            out: TerminalLines::default(),
            current: TerminalLine::default(),
            current_has_text: false,
            state: ScanState::Ground,
            sequence: String::new(),
            sgr: Vec::new(),
        }
    }

    fn prefix(&self) -> String {
        self.sgr.concat()
    }

    /// Extend the current line with `range` of write `write`.
    fn push(&mut self, write: usize, range: Range<usize>) {
        if range.is_empty() {
            return;
        }
        match self.current.segments.last_mut() {
            Some(last) if last.write == write && last.range.end == range.start => last.range.end = range.end,
            _ => self.current.segments.push(LineSegment { write, range }),
        }
    }

    fn end_line(&mut self, write: usize, at: usize) {
        if self.current.segments.is_empty() {
            self.current.segments.push(LineSegment { write, range: at..at });
        }
        let index = self.out.lines.len();
        if !self.current_has_text {
            // The write that ended the line is its last piece's write.
            self.out.last_line_of_write[write] = Some(index);
        }
        let next = TerminalLine {
            prefix: self.prefix(),
            segments: Vec::new(),
        };
        self.out.lines.push(std::mem::replace(&mut self.current, next));
        self.current_has_text = false;
    }

    /// A complete CSI sequence, `ESC [ … final`.
    fn csi(&mut self, final_byte: char) {
        let body = &self.sequence[2..self.sequence.len() - final_byte.len_utf8()];
        let private = body.chars().next().is_some_and(|c| matches!(c, '?' | '<' | '=' | '>'));
        let has_intermediates = body.chars().any(|c| ('\u{20}'..='\u{2f}').contains(&c));
        let params = if private { &body[1..] } else { body };
        match final_byte {
            'm' if !private && !has_intermediates => {
                if params.is_empty() || params.split([';', ':']).all(|p| p.is_empty() || p == "0") {
                    self.sgr.clear();
                } else {
                    self.sgr.push(self.sequence.clone());
                    if self.sgr.len() > MAX_PREFIX_SEQUENCES {
                        self.sgr.remove(0);
                    }
                }
            }
            'h' | 'l' if private => {
                if params.split(';').any(|p| matches!(p, "47" | "1047" | "1049")) {
                    self.out.screen_offered = true;
                }
            }
            'G' | '`' | 'd' | 'H' | 'f' if !private => self.out.screen_offered = true,
            'J' => self.out.screen_offered = true,
            _ => {}
        }
    }

    fn feed(&mut self, write: usize, text: &str) {
        let mut text_start: Option<usize> = None;
        for (at, c) in text.char_indices() {
            match self.state {
                ScanState::Ground => match c {
                    '\u{1b}' => {
                        if let Some(start) = text_start.take() {
                            self.push(write, start..at);
                        }
                        self.state = ScanState::Escape;
                        self.sequence.clear();
                        self.sequence.push(c);
                        // The escape belongs to the line it is written on.
                        text_start = Some(at);
                    }
                    '\n' => {
                        if let Some(start) = text_start.take() {
                            self.push(write, start..at);
                        }
                        self.end_line(write, at);
                    }
                    _ => {
                        if text_start.is_none() {
                            text_start = Some(at);
                        }
                        if !c.is_control() || c == '\t' {
                            self.current_has_text = true;
                            self.out.last_line_of_write[write] = Some(self.out.lines.len());
                        }
                    }
                },
                ScanState::Escape => {
                    self.sequence.push(c);
                    match c {
                        '[' => self.state = ScanState::Csi,
                        ']' => self.state = ScanState::Osc,
                        'c' => {
                            // RIS, a full reset: the colours and the screen.
                            self.sgr.clear();
                            self.out.screen_offered = true;
                            self.state = ScanState::Ground;
                        }
                        '\u{20}'..='\u{2f}' => {}
                        _ => self.state = ScanState::Ground,
                    }
                }
                ScanState::Csi => {
                    self.sequence.push(c);
                    if ('\u{40}'..='\u{7e}').contains(&c) {
                        self.csi(c);
                        self.state = ScanState::Ground;
                    }
                }
                ScanState::Osc => {
                    self.sequence.push(c);
                    match c {
                        '\u{7}' => self.state = ScanState::Ground,
                        '\u{1b}' => self.state = ScanState::OscEscape,
                        _ => {}
                    }
                }
                ScanState::OscEscape => {
                    self.sequence.push(c);
                    self.state = if c == '\\' { ScanState::Ground } else { ScanState::Osc };
                }
            }
        }
        if let Some(start) = text_start {
            self.push(write, start..text.len());
        }
    }

    fn finish(mut self) -> TerminalLines {
        if !self.current.segments.is_empty() {
            self.out.lines.push(self.current);
        }
        self.out
    }
}

/// Split the recorded writes into lines.
pub fn split_lines<S: AsRef<str>>(writes: &[S]) -> TerminalLines {
    let mut splitter = Splitter::new();
    splitter.out.last_line_of_write = vec![None; writes.len()];
    for (write, text) in writes.iter().enumerate() {
        splitter.feed(write, text.as_ref());
    }
    splitter.finish()
}

impl TerminalLines {
    /// The line holding the last piece written at or before `ticks` — the
    /// line view's current-position mark — or `None` before the first.
    /// `write_ticks` are the writes' ticks, in recording order.
    pub fn line_at_ticks(&self, write_ticks: &[i64], ticks: i64) -> Option<usize> {
        let after = write_ticks.partition_point(|t| *t <= ticks);
        (0..after.min(self.last_line_of_write.len()))
            .rev()
            .find_map(|w| self.last_line_of_write[w])
    }
}

/// The recorded writes and their lines, kept by the handler for the session.
#[derive(Debug, Clone, Default)]
pub struct CachedTerminalLines {
    /// Each write's text (base64 decoded), tick, place in the event log,
    /// source location and stream.
    writes: Vec<WriteInfo>,
    lines: TerminalLines,
}

#[derive(Debug, Clone, Default)]
struct WriteInfo {
    text: String,
    rr_ticks: i64,
    event_index: usize,
    path: String,
    line: i64,
    stdout: bool,
}

/// One piece of a line in an answer.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LineSegmentAnswer {
    /// The write's index among the recorded writes — what the screen view's
    /// scrubber and `ct/load-terminal` count.
    pub write: usize,
    /// The piece's raw text, escape sequences included.
    pub content: String,
    #[serde(rename = "directLocationRRTicks")]
    pub rr_ticks: i64,
    /// The write's place in the whole event log (`ct/event-jump`'s index).
    pub event_index: usize,
    pub high_level_path: String,
    pub high_level_line: i64,
    pub stdout: bool,
}

/// One line in an answer.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LineAnswer {
    pub index: usize,
    pub prefix: String,
    pub segments: Vec<LineSegmentAnswer>,
}

/// The answer to `ct/load-terminal-lines`.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TerminalLinesAnswer {
    pub start: usize,
    pub total: usize,
    /// How many writes the output has (the screen view's scrubber range).
    pub writes: usize,
    pub screen_offered: bool,
    /// The line of `atRRTicks`, -1 before the first write or when not asked.
    pub current_line: i64,
    pub lines: Vec<LineAnswer>,
}

impl CachedTerminalLines {
    pub fn of(events: &[ProgramEvent]) -> Self {
        let writes: Vec<WriteInfo> = events
            .iter()
            .map(|e| WriteInfo {
                text: if e.base64_encoded {
                    base64::engine::general_purpose::STANDARD
                        .decode(&e.content)
                        .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
                        .unwrap_or_default()
                } else {
                    e.content.clone()
                },
                rr_ticks: e.direct_location_rr_ticks,
                event_index: e.event_index,
                path: e.high_level_path.clone(),
                line: e.high_level_line,
                stdout: e.stdout,
            })
            .collect();
        let texts: Vec<&str> = writes.iter().map(|w| w.text.as_str()).collect();
        let lines = split_lines(&texts);
        CachedTerminalLines { writes, lines }
    }

    /// Lines `start .. start + count` (clamped), the totals, and the line of
    /// `at_ticks`.
    pub fn window(&self, start: usize, count: usize, at_ticks: Option<i64>) -> TerminalLinesAnswer {
        let total = self.lines.lines.len();
        let begin = start.min(total);
        let end = begin.saturating_add(count).min(total);
        let current_line = at_ticks
            .and_then(|ticks| {
                let ticks_of: Vec<i64> = self.writes.iter().map(|w| w.rr_ticks).collect();
                self.lines.line_at_ticks(&ticks_of, ticks)
            })
            .map_or(-1, |line| line as i64);
        let lines = self.lines.lines[begin..end]
            .iter()
            .enumerate()
            .map(|(i, line)| LineAnswer {
                index: begin + i,
                prefix: line.prefix.clone(),
                segments: line
                    .segments
                    .iter()
                    .filter_map(|seg| {
                        let w = self.writes.get(seg.write)?;
                        Some(LineSegmentAnswer {
                            write: seg.write,
                            content: w.text.get(seg.range.clone())?.to_string(),
                            rr_ticks: w.rr_ticks,
                            event_index: w.event_index,
                            high_level_path: w.path.clone(),
                            high_level_line: w.line,
                            stdout: w.stdout,
                        })
                    })
                    .collect(),
            })
            .collect();
        TerminalLinesAnswer {
            start: begin,
            total,
            writes: self.writes.len(),
            screen_offered: self.lines.screen_offered,
            current_line,
            lines,
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    fn texts(lines: &TerminalLines, writes: &[&str]) -> Vec<String> {
        lines
            .lines
            .iter()
            .map(|l| l.segments.iter().map(|s| &writes[s.write][s.range.clone()]).collect())
            .collect()
    }

    #[test]
    fn lines_end_at_newlines_across_writes() {
        let writes = ["ab", "c\nde\n", "f"];
        let lines = split_lines(&writes);
        assert_eq!(texts(&lines, &writes), vec!["abc", "de", "f"]);
        assert_eq!(lines.lines[0].segments.len(), 2);
        assert_eq!(lines.last_line_of_write, vec![Some(0), Some(1), Some(2)]);
        assert!(!lines.screen_offered);
    }

    #[test]
    fn an_empty_line_belongs_to_the_write_that_ended_it() {
        let writes = ["a\n", "\n"];
        let lines = split_lines(&writes);
        assert_eq!(texts(&lines, &writes), vec!["a", ""]);
        assert_eq!(lines.lines[1].segments, vec![LineSegment { write: 1, range: 0..0 }]);
        assert_eq!(lines.last_line_of_write, vec![Some(0), Some(1)]);
    }

    #[test]
    fn a_colour_set_earlier_is_the_next_lines_prefix() {
        let writes = ["\u{1b}[31mred\nstill red\u{1b}[0m\nplain"];
        let lines = split_lines(&writes);
        assert_eq!(lines.lines[0].prefix, "");
        assert_eq!(lines.lines[1].prefix, "\u{1b}[31m");
        assert_eq!(lines.lines[2].prefix, "");
        assert_eq!(
            texts(&lines, &writes),
            vec!["\u{1b}[31mred", "still red\u{1b}[0m", "plain"]
        );
    }

    #[test]
    fn a_write_of_escapes_only_marks_no_line() {
        let writes = ["a", "\u{1b}[1m"];
        let lines = split_lines(&writes);
        assert_eq!(lines.last_line_of_write, vec![Some(0), None]);
        assert_eq!(lines.line_at_ticks(&[5, 9], 9), Some(0));
        assert_eq!(lines.line_at_ticks(&[5, 9], 4), None);
    }

    #[test]
    fn screen_control_offers_the_screen_view() {
        for writes in [["\u{1b}[?1049h"], ["\u{1b}[2J"], ["\u{1b}[3;4H"], ["\u{1b}c"]] {
            assert!(split_lines(&writes).screen_offered, "{writes:?}");
        }
        assert!(!split_lines(&["\u{1b}[1;31mx\u{1b}[?25l"]).screen_offered);
    }

    #[test]
    fn an_osc_title_is_skipped_whole() {
        let writes = ["\u{1b}]0;title\nwith newline\u{7}x\n"];
        let lines = split_lines(&writes);
        // The OSC is kept with the text; its `\n` does not end a line.
        assert_eq!(lines.lines.len(), 1);
    }

    #[test]
    fn the_current_line_follows_ticks() {
        let writes = ["a\n", "b\n", "c"];
        let lines = split_lines(&writes);
        let ticks = [10, 20, 30];
        assert_eq!(lines.line_at_ticks(&ticks, 15), Some(0));
        assert_eq!(lines.line_at_ticks(&ticks, 20), Some(1));
        assert_eq!(lines.line_at_ticks(&ticks, 99), Some(2));
    }

    #[test]
    fn a_window_answers_its_lines_and_the_totals() {
        let events: Vec<ProgramEvent> = ["a\nb\n", "c\nd"]
            .iter()
            .enumerate()
            .map(|(i, text)| ProgramEvent {
                content: text.to_string(),
                direct_location_rr_ticks: 10 * (i as i64 + 1),
                event_index: 7 + i,
                ..ProgramEvent::default()
            })
            .collect();
        let cached = CachedTerminalLines::of(&events);
        let answer = cached.window(1, 2, Some(15));
        assert_eq!(answer.total, 4);
        assert_eq!(answer.writes, 2);
        assert_eq!(answer.start, 1);
        assert_eq!(answer.current_line, 1);
        assert_eq!(answer.lines.len(), 2);
        assert_eq!(answer.lines[0].index, 1);
        assert_eq!(answer.lines[0].segments[0].content, "b");
        assert_eq!(answer.lines[1].segments[0].content, "c");
        assert_eq!(answer.lines[1].segments[0].event_index, 8);
        let past_the_end = cached.window(9, 5, None);
        assert_eq!(past_the_end.start, 4);
        assert!(past_the_end.lines.is_empty());
        assert_eq!(past_the_end.current_line, -1);
    }
}
