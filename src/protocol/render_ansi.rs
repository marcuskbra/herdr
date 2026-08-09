//! Frame blitting — renders FrameData to the terminal using diff-based updates.
//!
//! The blitting strategy:
//! 1. On the first frame, write the entire buffer (full redraw).
//! 2. On subsequent frames, diff against the last frame and only write
//!    the cells that changed.
//! 3. Wrap each frame in synchronized output so terminals that support it do
//!    not expose intermediate cursor positions while the frame is painted.
//! 4. Before writing any cells, hide the cursor to avoid stray cursor
//!    artifacts on terminals that render the hardware cursor at intermediate
//!    `CUP` positions during the frame stream.
//! 5. After writing all changed cells, restore the final cursor visibility
//!    and position from `frame.cursor`.
//! 6. On platforms that need it, repeat the final cursor anchor after ending
//!    synchronized output so external IMEs can place candidate windows at the
//!    real input position. Windows Terminal exposes that repeat as visible
//!    cursor movement during active TUI repaints, so Windows skips it.
//!
//! Escape sequences used:
//! - `CSI H` (CUP) — move cursor to (row, col)
//! - `CSI m` (SGR) — set graphic rendition (colors, bold, etc.)
//! - `CSI ? 2026 h/l` — begin/end synchronized output
//! - `CSI Ps SP q` — DECSCUSR cursor shape
//! - `ESC ] 52 ; c ; <base64> BEL` — OSC 52 clipboard write
//!
//! The goal is minimal output: skip unchanged cells, batch adjacent changes,
//! and minimize cursor movement.

use std::cmp;
use std::io::Write;

use unicode_width::UnicodeWidthStr;

use crate::protocol::{underline_style_from_modifier, CellData, FrameData};

const REVERSED_MODIFIER: u16 = ratatui::style::Modifier::REVERSED.bits();
const SYNC_OUTPUT_END: &[u8] = b"\x1b[?2026l";

pub(crate) fn final_sync_output_end(bytes: &[u8]) -> Option<usize> {
    bytes
        .windows(SYNC_OUTPUT_END.len())
        .rposition(|window| window == SYNC_OUTPUT_END)
}

/// Bytes produced by a [`BlitEncoder`] for one terminal frame.
pub(crate) struct EncodedBlit {
    /// Terminal escape bytes ready to write to the host terminal.
    pub(crate) bytes: Vec<u8>,
    /// Whether this frame was encoded as a full redraw.
    pub(crate) full: bool,
    next_last_visible_cursor: Option<(u16, u16)>,
    next_last_cursor_shape: u8,
}

/// Stateful encoder that diffs semantic frames into terminal ANSI bytes.
#[derive(Default)]
pub(crate) struct BlitEncoder {
    last_frame: Option<FrameData>,
    last_visible_cursor: Option<(u16, u16)>,
    last_cursor_shape: u8,
}

impl BlitEncoder {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    pub(crate) fn encode(&self, frame: &FrameData, repaint: bool) -> EncodedBlit {
        self.encode_inner(frame, repaint, false)
    }

    pub(crate) fn encode_with_suppressed_visible_cursor(
        &self,
        frame: &FrameData,
        repaint: bool,
    ) -> EncodedBlit {
        self.encode_inner(frame, repaint, true)
    }

    fn encode_inner(
        &self,
        frame: &FrameData,
        repaint: bool,
        suppress_visible_cursor: bool,
    ) -> EncodedBlit {
        let previous_frame = self.last_frame.as_ref();
        let prev = if repaint { None } else { previous_frame };
        let full = repaint
            || prev.is_none()
            || prev.is_some_and(|p| p.width != frame.width || p.height != frame.height);
        let clear_before_full_redraw = previous_frame.is_none();
        let prof_stats =
            crate::render_prof::enabled().then(|| compute_prof_blit_stats(frame, prev, full));
        let prof_started = crate::render_prof::timer();
        let mut bytes = Vec::new();
        let mut next_last_visible_cursor = self.last_visible_cursor;
        let mut next_last_cursor_shape = self.last_cursor_shape;
        blit_frame_to_with_cursor_memory_and_clear_policy(
            &mut bytes,
            frame,
            prev,
            &mut next_last_visible_cursor,
            &mut next_last_cursor_shape,
            repeat_ime_anchor_after_sync(),
            clear_before_full_redraw,
            suppress_visible_cursor,
        );
        if let Some(stats) = prof_stats {
            crate::render_prof::duration_since("ansi_encode.total", prof_started);
            crate::render_prof::counter("ansi_encode.bytes", bytes.len() as u64);
            crate::render_prof::counter("ansi_encode.scanned_cells", stats.scanned_cells);
            crate::render_prof::counter("ansi_encode.changed_cells", stats.changed_cells);
            crate::render_prof::counter("ansi_encode.changed_runs", stats.changed_runs);
            if full {
                crate::render_prof::event("ansi_encode.full");
            } else {
                crate::render_prof::event("ansi_encode.partial");
            }
        }
        EncodedBlit {
            bytes,
            full,
            next_last_visible_cursor,
            next_last_cursor_shape,
        }
    }

    pub(crate) fn commit(&mut self, frame: FrameData, encoded: EncodedBlit) {
        self.last_visible_cursor = encoded.next_last_visible_cursor;
        self.last_cursor_shape = encoded.next_last_cursor_shape;
        self.last_frame = Some(frame);
    }

    pub(crate) fn is_current(&self, frame: &FrameData) -> bool {
        self.last_frame.as_ref() == Some(frame)
    }

    pub(crate) fn last_frame(&self) -> Option<&FrameData> {
        self.last_frame.as_ref()
    }
}

pub(crate) fn frame_with_drawn_cursor(mut frame: FrameData) -> FrameData {
    if let Some(cursor) = frame.cursor.as_ref().filter(|cursor| cursor.visible) {
        let (x, y) = clamp_cursor_position(&frame, cursor.x, cursor.y);
        let idx = (y as usize)
            .saturating_mul(frame.width as usize)
            .saturating_add(x as usize);
        if let Some(cell) = frame.cells.get_mut(idx) {
            cell.modifier ^= REVERSED_MODIFIER;
        }
    }
    frame
}

#[derive(Clone, Copy, Default)]
struct ProfBlitStats {
    scanned_cells: u64,
    changed_cells: u64,
    changed_runs: u64,
}

fn compute_prof_blit_stats(
    frame: &FrameData,
    prev: Option<&FrameData>,
    full: bool,
) -> ProfBlitStats {
    let Some(prev) = prev.filter(|_| !full) else {
        let changed_cells = frame.cells.iter().filter(|cell| !cell.skip).count() as u64;
        return ProfBlitStats {
            scanned_cells: frame.cells.len() as u64,
            changed_cells,
            changed_runs: changed_cells,
        };
    };
    if prev.width != frame.width || prev.height != frame.height {
        let changed_cells = frame.cells.iter().filter(|cell| !cell.skip).count() as u64;
        return ProfBlitStats {
            scanned_cells: frame.cells.len() as u64,
            changed_cells,
            changed_runs: changed_cells,
        };
    }

    let sanitized_hyperlinks = sanitized_frame_hyperlinks(frame);
    let prev_sanitized_hyperlinks = sanitized_frame_hyperlinks(prev);
    let mut stats = ProfBlitStats {
        scanned_cells: frame.cells.len() as u64,
        changed_cells: 0,
        changed_runs: 0,
    };
    for row in 0..frame.height {
        let mut in_run = false;
        let mut invalidated = 0usize;
        let mut to_skip = 0usize;
        for col in 0..frame.width {
            let idx = (row as usize) * (frame.width as usize) + (col as usize);
            let cell = &frame.cells[idx];
            let prev_cell = &prev.cells[idx];
            let changed = !cell.skip
                && (!cells_visually_equal(
                    &sanitized_hyperlinks,
                    cell,
                    &prev_sanitized_hyperlinks,
                    prev_cell,
                ) || invalidated > 0)
                && to_skip == 0;
            if changed {
                stats.changed_cells += 1;
                if !in_run {
                    stats.changed_runs += 1;
                    in_run = true;
                }
            } else {
                in_run = false;
            }
            to_skip = cell_width(cell).saturating_sub(1);
            let affected_width = cmp::max(cell_width(cell), cell_width(prev_cell));
            invalidated = cmp::max(affected_width, invalidated).saturating_sub(1);
        }
    }
    stats
}

// ---------------------------------------------------------------------------
// Cell style → SGR
// ---------------------------------------------------------------------------

const BOLD_MODIFIER: u16 = ratatui::style::Modifier::BOLD.bits();
const DIM_MODIFIER: u16 = ratatui::style::Modifier::DIM.bits();
const ITALIC_MODIFIER: u16 = ratatui::style::Modifier::ITALIC.bits();
const UNDERLINED_MODIFIER: u16 = ratatui::style::Modifier::UNDERLINED.bits();
const SLOW_BLINK_MODIFIER: u16 = ratatui::style::Modifier::SLOW_BLINK.bits();
const RAPID_BLINK_MODIFIER: u16 = ratatui::style::Modifier::RAPID_BLINK.bits();
const HIDDEN_MODIFIER: u16 = ratatui::style::Modifier::HIDDEN.bits();
const CROSSED_OUT_MODIFIER: u16 = ratatui::style::Modifier::CROSSED_OUT.bits();
const SGR_MODIFIER_MASK: u16 = BOLD_MODIFIER
    | DIM_MODIFIER
    | ITALIC_MODIFIER
    | UNDERLINED_MODIFIER
    | SLOW_BLINK_MODIFIER
    | RAPID_BLINK_MODIFIER
    | REVERSED_MODIFIER
    | HIDDEN_MODIFIER
    | CROSSED_OUT_MODIFIER;
const UNDERLINE_STYLE_SHIFT: u16 = 12;

// Keep this Reset-excluding order aligned with protocol::wire::color_to_u32.
const FOREGROUND_NAMED_CODES: [&[u8]; 16] = [
    b";30", b";31", b";32", b";33", b";34", b";35", b";36", b";37", b";90", b";91", b";92", b";93",
    b";94", b";95", b";96", b";97",
];
const BACKGROUND_NAMED_CODES: [&[u8]; 16] = [
    b";40", b";41", b";42", b";43", b";44", b";45", b";46", b";47", b";100", b";101", b";102",
    b";103", b";104", b";105", b";106", b";107",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SgrColour {
    Reset,
    Named(u8),
    Indexed(u8),
    Rgb(u8, u8, u8),
}

impl SgrColour {
    fn from_packed(value: u32) -> Self {
        match value >> 24 {
            0x00 => match value & 0xFF {
                0 => Self::Reset,
                named @ 1..=16 => Self::Named((named - 1) as u8),
                _ => Self::Reset,
            },
            0x01 => Self::Indexed(value as u8),
            0x02 => Self::Rgb((value >> 16) as u8, (value >> 8) as u8, value as u8),
            _ => Self::Reset,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct SgrModifier(u16);

impl SgrModifier {
    fn canonical(value: u16) -> Self {
        let mut canonical = value & SGR_MODIFIER_MASK;
        if canonical & UNDERLINED_MODIFIER != 0 {
            let underline_style = underline_style_from_modifier(value);
            if matches!(underline_style, 2..=5) {
                canonical |= u16::from(underline_style) << UNDERLINE_STYLE_SHIFT;
            }
        }
        Self(canonical)
    }

    fn contains(self, modifier: u16) -> bool {
        self.0 & modifier != 0
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct SgrStyleKey {
    foreground: SgrColour,
    background: SgrColour,
    modifier: SgrModifier,
}

impl SgrStyleKey {
    fn from_cell(cell: &CellData) -> Self {
        Self {
            foreground: SgrColour::from_packed(cell.fg),
            background: SgrColour::from_packed(cell.bg),
            modifier: SgrModifier::canonical(cell.modifier),
        }
    }
}

fn write_sgr(writer: &mut impl Write, style: SgrStyleKey) {
    let _ = writer.write_all(b"\x1b[0");
    write_sgr_modifiers(writer, style.modifier);
    write_sgr_colour(writer, style.foreground, SgrChannel::Foreground);
    write_sgr_colour(writer, style.background, SgrChannel::Background);
    let _ = writer.write_all(b"m");
}

fn write_sgr_modifiers(writer: &mut impl Write, modifier: SgrModifier) {
    // Preserve legacy emission order: intensity, italic, underline, blink,
    // reverse, hidden, then crossed-out.

    for (flag, code) in [
        (BOLD_MODIFIER, b";1".as_slice()),
        (DIM_MODIFIER, b";2".as_slice()),
        (ITALIC_MODIFIER, b";3".as_slice()),
    ] {
        if modifier.contains(flag) {
            let _ = writer.write_all(code);
        }
    }
    if modifier.contains(UNDERLINED_MODIFIER) {
        let code = match underline_style_from_modifier(modifier.0) {
            2 => b";4:2".as_slice(),
            3 => b";4:3".as_slice(),
            4 => b";4:4".as_slice(),
            5 => b";4:5".as_slice(),
            _ => b";4".as_slice(),
        };
        let _ = writer.write_all(code);
    }
    for (flag, code) in [
        (SLOW_BLINK_MODIFIER, b";5".as_slice()),
        (RAPID_BLINK_MODIFIER, b";6".as_slice()),
        (REVERSED_MODIFIER, b";7".as_slice()),
        (HIDDEN_MODIFIER, b";8".as_slice()),
        (CROSSED_OUT_MODIFIER, b";9".as_slice()),
    ] {
        if modifier.contains(flag) {
            let _ = writer.write_all(code);
        }
    }
}

#[derive(Clone, Copy)]
enum SgrChannel {
    Foreground,
    Background,
}

fn write_sgr_colour(writer: &mut impl Write, colour: SgrColour, channel: SgrChannel) {
    match colour {
        SgrColour::Reset => {
            let _ = writer.write_all(match channel {
                SgrChannel::Foreground => b";39",
                SgrChannel::Background => b";49",
            });
        }
        SgrColour::Named(index) => {
            let codes = match channel {
                SgrChannel::Foreground => &FOREGROUND_NAMED_CODES,
                SgrChannel::Background => &BACKGROUND_NAMED_CODES,
            };
            let _ = writer.write_all(codes[usize::from(index)]);
        }
        SgrColour::Indexed(index) => {
            let prefix = match channel {
                SgrChannel::Foreground => b";38;5;",
                SgrChannel::Background => b";48;5;",
            };
            let _ = writer.write_all(prefix);
            write_u8_decimal(writer, index);
        }
        SgrColour::Rgb(red, green, blue) => {
            let prefix = match channel {
                SgrChannel::Foreground => b";38;2;",
                SgrChannel::Background => b";48;2;",
            };
            let _ = writer.write_all(prefix);
            write_u8_decimal(writer, red);
            let _ = writer.write_all(b";");
            write_u8_decimal(writer, green);
            let _ = writer.write_all(b";");
            write_u8_decimal(writer, blue);
        }
    }
}

const DECIMAL_PAIRS: [[u8; 2]; 100] = decimal_pairs();

const fn decimal_pairs() -> [[u8; 2]; 100] {
    let mut pairs = [[0; 2]; 100];
    let mut value = 0;
    while value < pairs.len() {
        pairs[value] = [b'0' + (value / 10) as u8, b'0' + (value % 10) as u8];
        value += 1;
    }
    pairs
}

fn write_u8_decimal(writer: &mut impl Write, value: u8) {
    if value >= 100 {
        let pair = DECIMAL_PAIRS[usize::from(value % 100)];
        let digits = [b'0' + value / 100, pair[0], pair[1]];
        let _ = writer.write_all(&digits);
    } else if value >= 10 {
        let _ = writer.write_all(&DECIMAL_PAIRS[usize::from(value)]);
    } else {
        let _ = writer.write_all(&[b'0' + value]);
    }
}

// ---------------------------------------------------------------------------
// Cell comparison
// ---------------------------------------------------------------------------

/// Checks if two cells are visually identical.
#[cfg(test)]
fn cells_equal(a: &CellData, b: &CellData) -> bool {
    a.symbol == b.symbol
        && a.fg == b.fg
        && a.bg == b.bg
        && a.modifier == b.modifier
        && a.hyperlink == b.hyperlink
    // Skip flag is only for ratatui internal use, not visual.
}

// ---------------------------------------------------------------------------
// Blitting
// ---------------------------------------------------------------------------

/// Blits a frame to a writer, diffing against the previous frame.
#[cfg(test)]
fn blit_frame_to(writer: impl Write, frame: &FrameData, prev: Option<&FrameData>) {
    let mut last_visible_cursor = None;
    let mut last_cursor_shape = 0;
    blit_frame_to_with_cursor_memory(
        writer,
        frame,
        prev,
        &mut last_visible_cursor,
        &mut last_cursor_shape,
        false,
    );
}

#[cfg(test)]
fn blit_frame_to_with_cursor_memory(
    writer: impl Write,
    frame: &FrameData,
    prev: Option<&FrameData>,
    last_visible_cursor: &mut Option<(u16, u16)>,
    last_cursor_shape: &mut u8,
    suppress_visible_cursor: bool,
) {
    blit_frame_to_with_cursor_memory_and_policy(
        writer,
        frame,
        prev,
        last_visible_cursor,
        last_cursor_shape,
        repeat_ime_anchor_after_sync(),
        suppress_visible_cursor,
    );
}

#[cfg(test)]
fn blit_frame_to_with_cursor_memory_and_policy(
    writer: impl Write,
    frame: &FrameData,
    prev: Option<&FrameData>,
    last_visible_cursor: &mut Option<(u16, u16)>,
    last_cursor_shape: &mut u8,
    repeat_ime_anchor: bool,
    suppress_visible_cursor: bool,
) {
    blit_frame_to_with_cursor_memory_and_clear_policy(
        writer,
        frame,
        prev,
        last_visible_cursor,
        last_cursor_shape,
        repeat_ime_anchor,
        true,
        suppress_visible_cursor,
    );
}

fn blit_frame_to_with_cursor_memory_and_clear_policy(
    mut writer: impl Write,
    frame: &FrameData,
    prev: Option<&FrameData>,
    last_visible_cursor: &mut Option<(u16, u16)>,
    last_cursor_shape: &mut u8,
    repeat_ime_anchor: bool,
    clear_before_full_redraw: bool,
    suppress_visible_cursor: bool,
) {
    // On first frame or size change, do a full redraw.
    let full_redraw =
        prev.is_none() || prev.is_some_and(|p| p.width != frame.width || p.height != frame.height);

    // Ask terminals that support synchronized output to apply the whole frame
    // atomically. This keeps IMEs and cursor trackers from observing the
    // intermediate CUP positions used while painting changed cells.
    let _ = writer.write_all(b"\x1b[?2026h");

    // Hide cursor before any cell writes to avoid stray cursor artifacts
    // on terminals that render the hardware cursor at intermediate CUP positions.
    let _ = writer.write_all(b"\x1b[?25l");

    // Start each frame from a known OSC 8 state. If a previous write was
    // interrupted or the outer terminal had an active hyperlink, unlinked cells
    // must not inherit it.
    let _ = writer.write_all(b"\x1b]8;;\x1b\\");

    if full_redraw {
        if clear_before_full_redraw {
            let _ = writer.write_all(b"\x1b[2J");
        }
        write_all_cells(&mut writer, frame);
    } else {
        // Diff-based update: only write changed cells.
        let prev = prev.unwrap();
        write_changed_cells(&mut writer, frame, prev);
    }

    // Position the cursor while it is still hidden, then restore visibility.
    // Showing before moving makes slow terminals and IMEs briefly observe the
    // cursor at the last painted cell, which can be an animated sidebar/status
    // cell rather than the focused pane's input position. When the focused pane
    // hides its cursor, still park the host cursor intentionally so IMEs do not
    // anchor to whichever cell happened to be painted last.
    let mut host_cursor = resolve_host_cursor_state(frame, last_visible_cursor);
    if suppress_visible_cursor && host_cursor.visible {
        host_cursor.visible = false;
    }
    write_host_cursor_state(&mut writer, host_cursor, last_cursor_shape);

    // End the synchronized output block immediately after the final cursor
    // state is emitted so supporting terminals can present the frame atomically.
    let _ = writer.write_all(b"\x1b[?2026l");

    // Some native IMEs track candidate-window placement from normal terminal
    // cursor updates and may not observe cursor moves emitted inside synchronized
    // output. Re-emit only the resolved final cursor anchor after the sync block
    // on targets that need it; Windows Terminal exposes that repeat as cursor
    // movement during active TUI repaints.
    if repeat_ime_anchor {
        write_ime_anchor_cursor_state(&mut writer, host_cursor);
    }
    let _ = writer.flush();
}

#[cfg(windows)]
fn repeat_ime_anchor_after_sync() -> bool {
    false
}

#[cfg(not(windows))]
fn repeat_ime_anchor_after_sync() -> bool {
    true
}

/// Writes all cells in the frame (full redraw).
fn cell_width(cell: &CellData) -> usize {
    if cell.symbol.len() == 1 && !cell.symbol.as_bytes()[0].is_ascii_control() {
        return 1;
    }
    if is_halfwidth_katakana_voiced_grapheme(&cell.symbol) {
        return 2;
    }
    cell.symbol.width()
}

fn is_halfwidth_katakana_voiced_grapheme(symbol: &str) -> bool {
    let mut chars = symbol.chars();
    let Some(base) = chars.next() else {
        return false;
    };
    let Some(mark) = chars.next() else {
        return false;
    };
    chars.next().is_none()
        && ('\u{ff66}'..='\u{ff9d}').contains(&base)
        && matches!(mark, '\u{ff9e}' | '\u{ff9f}')
}

#[derive(Clone, Copy)]
struct HostCursorState {
    position: (u16, u16),
    visible: bool,
    /// DECSCUSR parameter (0–6). 0 means terminal default.
    shape: u8,
}

fn resolve_host_cursor_state(
    frame: &FrameData,
    last_visible_cursor: &mut Option<(u16, u16)>,
) -> HostCursorState {
    if let Some(cursor) = &frame.cursor {
        if cursor.visible {
            let position = clamp_cursor_position(frame, cursor.x, cursor.y);
            *last_visible_cursor = Some(position);
            return HostCursorState {
                position,
                visible: true,
                shape: normalize_cursor_shape(cursor.shape),
            };
        }

        let position = clamp_cursor_position(frame, cursor.x, cursor.y);
        return HostCursorState {
            position,
            visible: false,
            shape: normalize_cursor_shape(cursor.shape),
        };
    }

    let position = (*last_visible_cursor)
        .map(|(x, y)| clamp_cursor_position(frame, x, y))
        .unwrap_or_else(|| default_hidden_cursor_position(frame));
    HostCursorState {
        position,
        visible: false,
        shape: 0,
    }
}

fn normalize_cursor_shape(shape: u8) -> u8 {
    if shape <= 6 {
        shape
    } else {
        0
    }
}

fn default_hidden_cursor_position(frame: &FrameData) -> (u16, u16) {
    (
        frame.width.saturating_sub(1),
        frame.height.saturating_sub(1),
    )
}

fn clamp_cursor_position(frame: &FrameData, x: u16, y: u16) -> (u16, u16) {
    (
        x.min(frame.width.saturating_sub(1)),
        y.min(frame.height.saturating_sub(1)),
    )
}

fn write_cursor_position(writer: &mut impl Write, (x, y): (u16, u16)) {
    // CUP: move cursor to (row+1, col+1) — 1-based.
    let _ = write!(writer, "\x1b[{};{}H", y + 1, x + 1);
}

fn write_host_cursor_state(writer: &mut impl Write, cursor: HostCursorState, last_shape: &mut u8) {
    write_cursor_position(writer, cursor.position);
    if cursor.shape != *last_shape {
        let _ = write!(writer, "\x1b[{} q", cursor.shape);
        *last_shape = cursor.shape;
    }
    if cursor.visible {
        // Show cursor only after it is already at the final position.
        let _ = writer.write_all(b"\x1b[?25h");
    } else {
        let _ = writer.write_all(b"\x1b[?25l");
    }
}

fn write_ime_anchor_cursor_state(writer: &mut impl Write, cursor: HostCursorState) {
    write_cursor_position(writer, cursor.position);
    if cursor.visible {
        let _ = writer.write_all(b"\x1b[?25h");
    } else {
        let _ = writer.write_all(b"\x1b[?25l");
    }
}

fn write_all_cells(writer: &mut impl Write, frame: &FrameData) {
    let mut last_style = None;
    let mut active_hyperlink = None;
    for row in 0..frame.height {
        let mut to_skip = 0usize;
        let mut next_inline_col = None;
        for col in 0..frame.width {
            if to_skip > 0 {
                to_skip -= 1;
                continue;
            }

            let idx = (row as usize) * (frame.width as usize) + (col as usize);
            let cell = &frame.cells[idx];

            if cell.skip {
                next_inline_col = None;
                continue;
            }

            let cursor_position = (next_inline_col != Some(col)).then_some((col, row));
            write_cell(
                writer,
                cursor_position,
                cell,
                &mut last_style,
                &mut active_hyperlink,
                frame,
            );
            let width = cell_width(cell);
            next_inline_col =
                (cell.symbol.is_ascii() && width == 1).then_some(col.saturating_add(1));
            to_skip = width.saturating_sub(1);
        }
    }

    close_hyperlink(writer, &mut active_hyperlink);

    // Reset style at the end.
    let _ = writer.write_all(b"\x1b[0m");
}

fn cell_hyperlink_uri<'a>(frame: &'a FrameData, cell: &CellData) -> Option<&'a str> {
    let index = cell.hyperlink? as usize;
    frame.hyperlinks.get(index).map(String::as_str)
}

fn sanitized_hyperlink_uri(uri: &str) -> Option<String> {
    let sanitized: String = uri
        .chars()
        .filter(|ch| *ch != '\x1b' && *ch != '\x07' && !ch.is_control())
        .collect();
    (!sanitized.is_empty()).then_some(sanitized)
}

fn sanitized_frame_hyperlinks(frame: &FrameData) -> Vec<Option<String>> {
    frame
        .hyperlinks
        .iter()
        .map(|uri| sanitized_hyperlink_uri(uri))
        .collect()
}

fn sanitized_cell_hyperlink_uri<'a>(
    sanitized_hyperlinks: &'a [Option<String>],
    cell: &CellData,
) -> Option<&'a str> {
    let index = cell.hyperlink? as usize;
    sanitized_hyperlinks.get(index)?.as_deref()
}

fn write_hyperlink_if_changed(
    writer: &mut impl Write,
    active: &mut Option<String>,
    requested: Option<&str>,
) {
    let requested = requested.and_then(sanitized_hyperlink_uri);
    if active.as_deref() == requested.as_deref() {
        return;
    }

    if active.is_some() {
        let _ = writer.write_all(b"\x1b]8;;\x1b\\");
    }
    *active = requested;
    if let Some(uri) = active.as_deref() {
        let _ = write!(writer, "\x1b]8;;{uri}\x1b\\");
    }
}

fn close_hyperlink(writer: &mut impl Write, active: &mut Option<String>) {
    if active.take().is_some() {
        let _ = writer.write_all(b"\x1b]8;;\x1b\\");
    }
}

fn write_cell(
    writer: &mut impl Write,
    cursor_position: Option<(u16, u16)>,
    cell: &CellData,
    last_style: &mut Option<SgrStyleKey>,
    active_hyperlink: &mut Option<String>,
    frame: &FrameData,
) {
    if cell.skip {
        return;
    }

    if let Some(position) = cursor_position {
        write_cursor_position(writer, position);
    }

    let style = SgrStyleKey::from_cell(cell);
    if Some(style) != *last_style {
        write_sgr(writer, style);
        *last_style = Some(style);
    }

    write_hyperlink_if_changed(writer, active_hyperlink, cell_hyperlink_uri(frame, cell));
    let _ = writer.write_all(cell.symbol.as_bytes());
}

/// Writes only the cells that changed between the previous and current frame.
fn cells_visually_equal(
    sanitized_hyperlinks: &[Option<String>],
    cell: &CellData,
    prev_sanitized_hyperlinks: &[Option<String>],
    prev_cell: &CellData,
) -> bool {
    cell.symbol == prev_cell.symbol
        && cell.fg == prev_cell.fg
        && cell.bg == prev_cell.bg
        && cell.modifier == prev_cell.modifier
        && sanitized_cell_hyperlink_uri(sanitized_hyperlinks, cell)
            == sanitized_cell_hyperlink_uri(prev_sanitized_hyperlinks, prev_cell)
    // Skip flag is only for ratatui internal use, not visual.
}

fn write_changed_cells(writer: &mut impl Write, frame: &FrameData, prev: &FrameData) {
    let mut last_style = None; // Track the canonical style to avoid redundant SGR changes.
    let mut active_hyperlink = None;
    let sanitized_hyperlinks = sanitized_frame_hyperlinks(frame);
    let prev_sanitized_hyperlinks = sanitized_frame_hyperlinks(prev);

    for row in 0..frame.height {
        let mut invalidated = 0usize;
        let mut to_skip = 0usize;
        // Herdr clients disable host autowrap, so safe cells can advance inline
        // without spilling into adjacent rows during a resize race.
        let mut next_inline_col = None;

        for col in 0..frame.width {
            let idx = (row as usize) * (frame.width as usize) + (col as usize);
            let cell = &frame.cells[idx];
            let prev_cell = &prev.cells[idx];
            let width = cell_width(cell);

            if !cell.skip
                && (!cells_visually_equal(
                    &sanitized_hyperlinks,
                    cell,
                    &prev_sanitized_hyperlinks,
                    prev_cell,
                ) || invalidated > 0)
                && to_skip == 0
            {
                let cursor_position =
                    (next_inline_col != Some(col) || invalidated > 0).then_some((col, row));
                write_cell(
                    writer,
                    cursor_position,
                    cell,
                    &mut last_style,
                    &mut active_hyperlink,
                    frame,
                );
                next_inline_col =
                    (cell.symbol.is_ascii() && width == 1).then_some(col.saturating_add(1));
            }

            to_skip = width.saturating_sub(1);
            let affected_width = cmp::max(width, cell_width(prev_cell));
            invalidated = cmp::max(affected_width, invalidated).saturating_sub(1);
        }
    }

    close_hyperlink(writer, &mut active_hyperlink);

    // Reset style if we wrote anything.
    if last_style.is_some() {
        let _ = writer.write_all(b"\x1b[0m");
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{CellData, CursorState};

    const WIDE_GRAPHEME: &str = "💡";
    const HALFWIDTH_VOICED_KANA: &str = "ｶ\u{ff9e}";

    fn make_cell(symbol: &str, fg: u32, bg: u32, modifier: u16) -> CellData {
        CellData {
            symbol: symbol.to_owned(),
            fg,
            bg,
            modifier,
            skip: false,
            hyperlink: None,
        }
    }

    fn make_skip_cell(symbol: &str, fg: u32, bg: u32, modifier: u16) -> CellData {
        let mut cell = make_cell(symbol, fg, bg, modifier);
        cell.skip = true;
        cell
    }

    fn make_frame(width: u16, height: u16, cells: Vec<CellData>) -> FrameData {
        FrameData {
            cells,
            width,
            height,
            cursor: None,
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        }
    }

    fn linked_cell(symbol: &str, index: u32) -> CellData {
        let mut cell = make_cell(symbol, 0, 0, 0);
        cell.hyperlink = Some(index);
        cell
    }

    const PERFORMANCE_WIDTH: u16 = 200;
    const PERFORMANCE_HEIGHT: u16 = 50;
    const PERFORMANCE_CELLS: usize = PERFORMANCE_WIDTH as usize * PERFORMANCE_HEIGHT as usize;

    struct EncoderWorkload {
        name: &'static str,
        previous: Option<FrameData>,
        current: FrameData,
        repaint: bool,
        expected_full: bool,
    }

    fn performance_workloads() -> [EncoderWorkload; 4] {
        let dense_previous = dense_coloured_frame(0);
        let dense_current = dense_coloured_frame(1);
        assert!(
            dense_previous
                .cells
                .iter()
                .zip(&dense_current.cells)
                .all(|(previous, current)| previous != current),
            "dense fixture must change every cell"
        );
        for frame in [&dense_previous, &dense_current] {
            assert!(frame.hyperlinks.is_empty());
            assert!(frame.cells.iter().all(|cell| {
                cell.hyperlink.is_none() && cell.symbol.len() == 1 && cell.symbol.is_ascii()
            }));
        }

        let plain_previous = plain_scroll_frame(0);
        let plain_current = plain_scroll_frame(1);
        let plain_changed = changed_cell_count(&plain_previous, &plain_current);
        assert_eq!(
            plain_changed, PERFORMANCE_CELLS,
            "plain-scroll fixture must change every cell"
        );

        let sparse_previous = sparse_frame();
        let mut sparse_current = sparse_previous.clone();
        for edit in 0..16 {
            let index = (edit * 613 + 97) % PERFORMANCE_CELLS;
            sparse_current.cells[index] = make_cell("#", 0, 0, 0);
        }
        let sparse_changed = changed_cell_count(&sparse_previous, &sparse_current);
        assert_eq!(sparse_changed, 16, "sparse fixture changed-cell count");
        assert!(sparse_changed > 0, "sparse fixture must not be a no-op");

        [
            EncoderWorkload {
                name: "dense_colour",
                previous: Some(dense_previous),
                current: dense_current,
                repaint: false,
                expected_full: false,
            },
            EncoderWorkload {
                name: "plain_scroll",
                previous: Some(plain_previous),
                current: plain_current,
                repaint: false,
                expected_full: false,
            },
            EncoderWorkload {
                name: "sparse_edit",
                previous: Some(sparse_previous),
                current: sparse_current,
                repaint: false,
                expected_full: false,
            },
            EncoderWorkload {
                name: "full_redraw",
                previous: None,
                current: plain_scroll_frame(3),
                repaint: false,
                expected_full: true,
            },
        ]
    }

    fn changed_cell_count(previous: &FrameData, current: &FrameData) -> usize {
        previous
            .cells
            .iter()
            .zip(&current.cells)
            .filter(|(previous, current)| previous != current)
            .count()
    }

    fn dense_coloured_frame(generation: usize) -> FrameData {
        let cells = (0..PERFORMANCE_CELLS)
            .map(|index| {
                let symbol = char::from(b'!' + ((index + generation) % 94) as u8).to_string();
                make_cell(
                    &symbol,
                    performance_colour(index + generation),
                    performance_colour(index * 5 + generation + 1),
                    performance_modifier(index + generation),
                )
            })
            .collect();
        make_frame(PERFORMANCE_WIDTH, PERFORMANCE_HEIGHT, cells)
    }

    fn performance_colour(index: usize) -> u32 {
        match index % 3 {
            0 => 1 + ((index / 3) % 16) as u32,
            1 => 0x01_00_00_00 | ((index * 37) % 256) as u32,
            _ => {
                let red = ((index * 17) % 256) as u32;
                let green = ((index * 43) % 256) as u32;
                let blue = ((index * 97) % 256) as u32;
                0x02_00_00_00 | (red << 16) | (green << 8) | blue
            }
        }
    }

    fn performance_modifier(index: usize) -> u16 {
        use ratatui::style::Modifier;

        let (modifier, underline_style) = match index % 8 {
            0 => (Modifier::empty(), 0),
            1 => (Modifier::BOLD, 0),
            2 => (Modifier::DIM | Modifier::ITALIC, 0),
            3 => (Modifier::UNDERLINED, 1),
            4 => (Modifier::BOLD | Modifier::UNDERLINED, 2),
            5 => (Modifier::ITALIC | Modifier::UNDERLINED, 3),
            6 => (Modifier::DIM | Modifier::UNDERLINED, 4),
            _ => (Modifier::BOLD | Modifier::ITALIC | Modifier::UNDERLINED, 5),
        };
        crate::protocol::modifier_to_u16(crate::protocol::modifier_with_underline_style(
            modifier,
            underline_style,
        ))
    }

    fn plain_scroll_frame(row_offset: usize) -> FrameData {
        let cells = (0..PERFORMANCE_CELLS)
            .map(|index| {
                let row = index / PERFORMANCE_WIDTH as usize;
                let col = index % PERFORMANCE_WIDTH as usize;
                let symbol =
                    char::from(b'A' + ((row + row_offset + col * 7) % 26) as u8).to_string();
                make_cell(&symbol, 0, 0, 0)
            })
            .collect();
        make_frame(PERFORMANCE_WIDTH, PERFORMANCE_HEIGHT, cells)
    }

    fn sparse_frame() -> FrameData {
        let cells = (0..PERFORMANCE_CELLS)
            .map(|index| {
                let symbol = char::from(b'a' + (index % 26) as u8).to_string();
                make_cell(&symbol, 0, 0, 0)
            })
            .collect();
        make_frame(PERFORMANCE_WIDTH, PERFORMANCE_HEIGHT, cells)
    }

    fn encoder_for_workload(workload: &EncoderWorkload) -> BlitEncoder {
        let mut encoder = BlitEncoder::new();
        if let Some(previous) = workload.previous.as_ref() {
            let encoded = encoder.encode(previous, false);
            encoder.commit(previous.clone(), encoded);
        }
        encoder
    }

    fn assert_platform_ime_anchor_contract(bytes: &[u8], workload_name: &str) {
        let sync_end = final_sync_output_end(bytes)
            .unwrap_or_else(|| panic!("{workload_name} should end synchronized output"));
        let trailing = &bytes[sync_end + SYNC_OUTPUT_END.len()..];
        assert_eq!(
            trailing.is_empty(),
            !repeat_ime_anchor_after_sync(),
            "{workload_name} should follow the platform IME-anchor policy"
        );
    }

    #[test]
    fn encoder_performance_fixture_corpus_is_deterministic() {
        let workloads = performance_workloads();

        for workload in &workloads {
            assert_eq!(
                workload.current.width, PERFORMANCE_WIDTH,
                "{} width",
                workload.name
            );
            assert_eq!(
                workload.current.height, PERFORMANCE_HEIGHT,
                "{} height",
                workload.name
            );
            assert_eq!(
                workload.current.cells.len(),
                PERFORMANCE_CELLS,
                "{} cells",
                workload.name
            );
            if let Some(previous) = workload.previous.as_ref() {
                assert_eq!(
                    (previous.width, previous.height, previous.cells.len()),
                    (PERFORMANCE_WIDTH, PERFORMANCE_HEIGHT, PERFORMANCE_CELLS),
                    "{} previous frame dimensions",
                    workload.name
                );
            }

            let encoder = encoder_for_workload(workload);
            let first = encoder.encode(&workload.current, workload.repaint);
            let second = encoder.encode(&workload.current, workload.repaint);

            assert_eq!(
                first.full, workload.expected_full,
                "{} classification",
                workload.name
            );
            assert_eq!(
                second.full, first.full,
                "{} repeated classification",
                workload.name
            );
            assert!(!first.bytes.is_empty(), "{} output", workload.name);
            assert_eq!(
                second.bytes, first.bytes,
                "{} repeated bytes",
                workload.name
            );
            assert_eq!(
                second.bytes.len(),
                first.bytes.len(),
                "{} repeated length",
                workload.name
            );
            assert_platform_ime_anchor_contract(&first.bytes, workload.name);
        }
    }

    fn with_platform_ime_anchor(mut expected: Vec<u8>, anchor: &[u8]) -> Vec<u8> {
        if repeat_ime_anchor_after_sync() {
            expected.extend_from_slice(anchor);
        }
        expected
    }

    #[test]
    fn ansi_encoder_matches_current_master_byte_oracle() {
        let full =
            BlitEncoder::new().encode(&make_frame(1, 1, vec![make_cell("A", 0, 0, 0)]), false);
        let expected_full = with_platform_ime_anchor(
            concat!(
                "\x1b[?2026h",
                "\x1b[?25l",
                "\x1b]8;;\x1b\\",
                "\x1b[2J",
                "\x1b[1;1H\x1b[0;39;49mA",
                "\x1b[0m",
                "\x1b[1;1H\x1b[?25l",
                "\x1b[?2026l",
            )
            .as_bytes()
            .to_vec(),
            b"\x1b[1;1H\x1b[?25l",
        );
        assert_eq!(full.bytes, expected_full, "full redraw oracle");

        let previous = make_frame(1, 1, vec![make_cell("A", 0, 0, 0)]);
        let current = make_frame(1, 1, vec![make_cell("B", 0, 0, 0)]);
        let mut encoder = BlitEncoder::new();
        let initial = encoder.encode(&previous, false);
        encoder.commit(previous, initial);
        let diff = encoder.encode(&current, false);
        let expected_diff = with_platform_ime_anchor(
            concat!(
                "\x1b[?2026h",
                "\x1b[?25l",
                "\x1b]8;;\x1b\\",
                "\x1b[1;1H\x1b[0;39;49mB",
                "\x1b[0m",
                "\x1b[1;1H\x1b[?25l",
                "\x1b[?2026l",
            )
            .as_bytes()
            .to_vec(),
            b"\x1b[1;1H\x1b[?25l",
        );
        assert_eq!(diff.bytes, expected_diff, "diff redraw oracle");
        encoder.commit(current.clone(), diff);

        let mut cursor_frame = current.clone();
        cursor_frame.cursor = Some(CursorState {
            x: 0,
            y: 0,
            visible: true,
            shape: 6,
        });
        let cursor = encoder.encode(&cursor_frame, false);
        let expected_cursor = with_platform_ime_anchor(
            concat!(
                "\x1b[?2026h",
                "\x1b[?25l",
                "\x1b]8;;\x1b\\",
                "\x1b[1;1H\x1b[6 q\x1b[?25h",
                "\x1b[?2026l",
            )
            .as_bytes()
            .to_vec(),
            b"\x1b[1;1H\x1b[?25h",
        );
        assert_eq!(cursor.bytes, expected_cursor, "cursor-only oracle");

        let mut hyperlink_frame = make_frame(1, 1, vec![linked_cell("L", 0)]);
        hyperlink_frame
            .hyperlinks
            .push("https://example.test".to_owned());
        let hyperlink = BlitEncoder::new().encode(&hyperlink_frame, false);
        let expected_hyperlink = with_platform_ime_anchor(
            concat!(
                "\x1b[?2026h",
                "\x1b[?25l",
                "\x1b]8;;\x1b\\",
                "\x1b[2J",
                "\x1b[1;1H\x1b[0;39;49m",
                "\x1b]8;;https://example.test\x1b\\L",
                "\x1b]8;;\x1b\\",
                "\x1b[0m",
                "\x1b[1;1H\x1b[?25l",
                "\x1b[?2026l",
            )
            .as_bytes()
            .to_vec(),
            b"\x1b[1;1H\x1b[?25l",
        );
        assert_eq!(
            hyperlink.bytes, expected_hyperlink,
            "hyperlink redraw oracle"
        );
    }

    #[test]
    fn diff_reuses_sgr_for_unknown_colour_encodings_that_render_as_reset() {
        let previous = make_frame(2, 1, vec![make_cell("A", 0, 0, 0), make_cell("B", 0, 0, 0)]);
        let current = make_frame(
            2,
            1,
            vec![
                make_cell("C", 0x7F_12_34_56, 0x00_12_34_FF, 0),
                make_cell("D", 0x00_AB_CD_00, 0x03_00_00_00, 0),
            ],
        );
        let mut output = Vec::new();

        blit_frame_to(&mut output, &current, Some(&previous));

        assert_eq!(
            output
                .windows(b"\x1b[0;39;49m".len())
                .filter(|window| *window == b"\x1b[0;39;49m")
                .count(),
            1,
            "equivalent unknown colour encodings should reuse the emitted SGR"
        );
    }

    #[test]
    fn diff_reuses_sgr_when_modifiers_differ_only_in_ignored_bits() {
        let previous = make_frame(2, 1, vec![make_cell("A", 0, 0, 0), make_cell("B", 0, 0, 0)]);
        let current = make_frame(
            2,
            1,
            vec![
                make_cell("C", 0, 0, (0x0F << 12) | (1 << 9)),
                make_cell("D", 0, 0, 1 << 10),
            ],
        );
        let mut output = Vec::new();

        blit_frame_to(&mut output, &current, Some(&previous));

        assert_eq!(
            output
                .windows(b"\x1b[0;39;49m".len())
                .filter(|window| *window == b"\x1b[0;39;49m")
                .count(),
            1,
            "ignored modifier bits should not trigger a duplicate SGR"
        );
    }

    #[cfg(feature = "test-allocation-counting")]
    #[test]
    fn direct_sgr_style_encoding_does_not_allocate_per_cell() {
        const CELLS: usize = 128;
        let styles: Vec<_> = (0..CELLS)
            .map(|index| {
                SgrStyleKey::from_cell(&make_cell(
                    "",
                    performance_colour(index),
                    performance_colour(index * 5 + 1),
                    performance_modifier(index),
                ))
            })
            .collect();
        let mut output = Vec::with_capacity(CELLS * 40);

        let (_, allocations) = crate::test_alloc::measure(|| {
            for style in styles.iter().copied() {
                write_sgr(&mut output, style);
            }
        });

        assert_eq!(allocations.allocations, 0, "style encoding allocations");
        assert!(
            styles.windows(2).all(|pair| pair[0] != pair[1]),
            "the regression corpus must vary style for every adjacent cell"
        );
        assert!(!output.is_empty());
    }

    fn correctness_matrix_frames() -> [FrameData; 3] {
        use ratatui::style::Modifier;

        let mut cells = vec![
            make_cell("N", 0x00_00_00_02, 0x00_00_00_05, 0),
            make_cell("I", 0x01_00_00_AB, 0x01_00_00_16, 0),
            make_cell("R", 0x02_12_34_56, 0x02_65_43_21, 0),
        ];
        for (symbol, modifier) in [
            ("b", Modifier::BOLD),
            ("d", Modifier::DIM),
            ("i", Modifier::ITALIC),
            ("s", Modifier::SLOW_BLINK),
            ("r", Modifier::RAPID_BLINK),
            ("v", Modifier::REVERSED),
            ("h", Modifier::HIDDEN),
            ("x", Modifier::CROSSED_OUT),
        ] {
            cells.push(make_cell(
                symbol,
                0,
                0,
                crate::protocol::modifier_to_u16(modifier),
            ));
        }
        for (symbol, underline_style) in [("1", 1), ("2", 2), ("3", 3), ("4", 4), ("5", 5)] {
            let modifier = crate::protocol::modifier_with_underline_style(
                Modifier::UNDERLINED,
                underline_style,
            );
            cells.push(make_cell(
                symbol,
                0,
                0,
                crate::protocol::modifier_to_u16(modifier),
            ));
        }
        cells.extend([
            make_cell(WIDE_GRAPHEME, 0, 0, 0),
            make_skip_cell("~", 0, 0, 0),
            make_cell(HALFWIDTH_VOICED_KANA, 0, 0, 0),
            make_skip_cell("^", 0, 0, 0),
            linked_cell("V", 0),
            linked_cell("S", 1),
            linked_cell("E", 2),
            linked_cell("M", 99),
        ]);

        let mut visible = make_frame(cells.len() as u16, 1, cells);
        visible.hyperlinks = vec![
            "https://valid.test".to_owned(),
            "https://san\x1b\x07itized.test".to_owned(),
            "\x1b\x07".to_owned(),
        ];
        visible.cursor = Some(CursorState {
            x: 1,
            y: 0,
            visible: true,
            shape: 6,
        });
        let mut hidden = visible.clone();
        hidden.cursor = Some(CursorState {
            x: 2,
            y: 0,
            visible: false,
            shape: 2,
        });
        let mut absent = hidden.clone();
        absent.cursor = None;
        [visible, hidden, absent]
    }

    #[test]
    fn ansi_encoder_correctness_matrix_covers_supported_semantics() {
        let [visible, hidden, absent] = correctness_matrix_frames();
        let mut encoder = BlitEncoder::new();

        let visible_encoded = encoder.encode(&visible, false);
        let visible_output = String::from_utf8(visible_encoded.bytes.clone()).unwrap();
        for sgr in [
            "\x1b[0;31;44m",
            "\x1b[0;38;5;171;48;5;22m",
            "\x1b[0;38;2;18;52;86;48;2;101;67;33m",
            "\x1b[0;1;39;49m",
            "\x1b[0;2;39;49m",
            "\x1b[0;3;39;49m",
            "\x1b[0;5;39;49m",
            "\x1b[0;6;39;49m",
            "\x1b[0;7;39;49m",
            "\x1b[0;8;39;49m",
            "\x1b[0;9;39;49m",
            "\x1b[0;4;39;49m",
            "\x1b[0;4:2;39;49m",
            "\x1b[0;4:3;39;49m",
            "\x1b[0;4:4;39;49m",
            "\x1b[0;4:5;39;49m",
        ] {
            assert!(visible_output.contains(sgr), "missing matrix SGR {sgr:?}");
        }
        assert!(visible_output.contains(WIDE_GRAPHEME));
        assert!(visible_output.contains(HALFWIDTH_VOICED_KANA));
        assert!(
            !visible_output.contains('~'),
            "wide skip cell must not render"
        );
        assert!(
            !visible_output.contains('^'),
            "kana skip cell must not render"
        );
        assert!(visible_output.contains("\x1b]8;;https://valid.test\x1b\\V"));
        assert!(visible_output.contains("\x1b]8;;https://sanitized.test\x1b\\S"));
        assert_eq!(
            visible_output.matches("\x1b]8;;https://").count(),
            2,
            "empty sanitized and out-of-range hyperlinks must remain unlinked"
        );
        assert!(visible_output.contains("\x1b[1;2H\x1b[6 q\x1b[?25h"));
        encoder.commit(visible, visible_encoded);

        let hidden_encoded = encoder.encode(&hidden, false);
        let hidden_output = String::from_utf8(hidden_encoded.bytes.clone()).unwrap();
        assert!(hidden_output.contains("\x1b[1;3H\x1b[2 q\x1b[?25l"));
        encoder.commit(hidden, hidden_encoded);

        let absent_output = String::from_utf8(encoder.encode(&absent, false).bytes).unwrap();
        assert!(
            absent_output.contains("\x1b[1;2H\x1b[0 q\x1b[?25l"),
            "absent cursor should return to the last visible anchor and default shape"
        );
    }

    #[derive(Debug, PartialEq, Eq)]
    struct BenchmarkTiming {
        median_ns_per_frame: u128,
        p95_ns_per_frame: u128,
        max_ns_per_frame: u128,
    }

    fn summarize_timing_samples(mut samples: Vec<u128>) -> BenchmarkTiming {
        assert!(!samples.is_empty(), "timing summary requires samples");
        samples.sort_unstable();
        let p95_index = (samples.len() * 95).div_ceil(100) - 1;
        BenchmarkTiming {
            median_ns_per_frame: samples[samples.len() / 2],
            p95_ns_per_frame: samples[p95_index],
            max_ns_per_frame: *samples.last().expect("samples are non-empty"),
        }
    }

    #[test]
    fn timing_summary_handles_a_single_sample() {
        assert_eq!(
            summarize_timing_samples(vec![17]),
            BenchmarkTiming {
                median_ns_per_frame: 17,
                p95_ns_per_frame: 17,
                max_ns_per_frame: 17,
            }
        );
    }

    #[test]
    fn timing_summary_reports_percentiles_for_a_fixed_sequence() {
        assert_eq!(
            summarize_timing_samples(vec![9, 1, 4, 7, 3]),
            BenchmarkTiming {
                median_ns_per_frame: 4,
                p95_ns_per_frame: 9,
                max_ns_per_frame: 9,
            }
        );
    }

    fn warm_up_encoder(workload: &EncoderWorkload, encoder: &BlitEncoder, frames: usize) -> usize {
        let mut output_bytes = None;
        for _ in 0..frames {
            let encoded = std::hint::black_box(
                encoder.encode(std::hint::black_box(&workload.current), workload.repaint),
            );
            assert_eq!(encoded.full, workload.expected_full);
            assert!(!encoded.bytes.is_empty());
            if let Some(expected) = output_bytes {
                assert_eq!(encoded.bytes.len(), expected);
            } else {
                output_bytes = Some(encoded.bytes.len());
            }
            drop(encoded);
        }
        output_bytes.expect("warm-up should encode at least one frame")
    }

    fn time_encoder_batches(
        workload: &EncoderWorkload,
        encoder: &BlitEncoder,
        output_bytes: usize,
        frames_per_batch: usize,
        batches: usize,
    ) -> BenchmarkTiming {
        assert!(batches >= 100, "p95 requires at least 100 timing samples");
        let mut samples = Vec::with_capacity(batches);
        for _ in 0..batches {
            // Each sample includes sequential encode, invariant checks, and
            // output destruction/deallocation. One Instant pair is amortized
            // across the batch rather than subtracted through calibration.
            let started = std::time::Instant::now();
            for _ in 0..frames_per_batch {
                let encoded = std::hint::black_box(
                    encoder.encode(std::hint::black_box(&workload.current), workload.repaint),
                );
                assert_eq!(encoded.full, workload.expected_full);
                assert_eq!(encoded.bytes.len(), output_bytes);
                std::hint::black_box(&encoded.bytes);
                drop(encoded);
            }
            samples.push(started.elapsed().as_nanos() / frames_per_batch as u128);
        }

        summarize_timing_samples(samples)
    }

    #[cfg(feature = "test-allocation-counting")]
    fn measure_encoder_allocations(
        workload: &EncoderWorkload,
        encoder: &BlitEncoder,
        output_bytes: usize,
        frames: usize,
    ) -> crate::test_alloc::AllocationStats {
        let mut expected_stats = None;
        for _ in 0..frames {
            let (encoded, stats) = crate::test_alloc::measure(|| {
                std::hint::black_box(
                    encoder.encode(std::hint::black_box(&workload.current), workload.repaint),
                )
            });

            assert_eq!(encoded.full, workload.expected_full);
            assert_eq!(encoded.bytes.len(), output_bytes);
            assert!(stats.allocations > 0);
            assert!(stats.requested_bytes >= output_bytes);
            if let Some(expected) = expected_stats {
                assert_eq!(stats, expected, "{} allocation stability", workload.name);
            } else {
                expected_stats = Some(stats);
            }
            drop(encoded);
        }
        expected_stats.expect("allocation measurement should encode at least one frame")
    }

    // Production-allocator timing command (do not add `--features`):
    // env -u HERDR_RENDER_PROF cargo test --release protocol::render_ansi::tests::ansi_encoder_release_timing_benchmark -- --ignored --exact --nocapture --test-threads=1
    #[test]
    #[ignore = "manual release timing benchmark; use the documented production-allocator command"]
    fn ansi_encoder_release_timing_benchmark() {
        const WARM_UP_FRAMES: usize = 20;
        const FRAMES_PER_BATCH: usize = 10;
        const BATCHES: usize = 100;

        assert_release_benchmark_environment();
        println!();
        for workload in &performance_workloads() {
            let encoder = encoder_for_workload(workload);
            let output_bytes = warm_up_encoder(workload, &encoder, WARM_UP_FRAMES);
            let timing =
                time_encoder_batches(workload, &encoder, output_bytes, FRAMES_PER_BATCH, BATCHES);

            println!(
                "METRIC {}_median_ns_per_frame={}",
                workload.name, timing.median_ns_per_frame
            );
            println!(
                "METRIC {}_p95_ns_per_frame={}",
                workload.name, timing.p95_ns_per_frame
            );
            println!(
                "METRIC {}_max_ns_per_frame={}",
                workload.name, timing.max_ns_per_frame
            );
            println!("METRIC {}_output_bytes={}", workload.name, output_bytes);
        }
    }

    // Allocation command:
    // env -u HERDR_RENDER_PROF cargo test --release --features test-allocation-counting protocol::render_ansi::tests::ansi_encoder_release_allocation_benchmark -- --ignored --exact --nocapture --test-threads=1
    // Autoresearch may chain that command after the production-allocator timing
    // command with `&&`; keeping them separate prevents instrumentation skew.
    #[cfg(feature = "test-allocation-counting")]
    #[test]
    #[ignore = "manual release allocation benchmark; use the documented feature command"]
    fn ansi_encoder_release_allocation_benchmark() {
        const WARM_UP_FRAMES: usize = 20;
        const ALLOCATION_FRAMES: usize = 10;

        assert_release_benchmark_environment();
        println!();
        for workload in &performance_workloads() {
            let encoder = encoder_for_workload(workload);
            let output_bytes = warm_up_encoder(workload, &encoder, WARM_UP_FRAMES);
            let allocations =
                measure_encoder_allocations(workload, &encoder, output_bytes, ALLOCATION_FRAMES);

            println!(
                "METRIC {}_allocations_per_frame={}",
                workload.name, allocations.allocations
            );
            println!(
                "METRIC {}_requested_bytes_per_frame={}",
                workload.name, allocations.requested_bytes
            );
            println!("METRIC {}_output_bytes={}", workload.name, output_bytes);
        }
    }

    fn assert_release_benchmark_environment() {
        if cfg!(debug_assertions) {
            panic!("run this benchmark with `cargo test --release`");
        }
        assert!(
            !crate::render_prof::enabled(),
            "HERDR_RENDER_PROF must be disabled for the ANSI encoder benchmark"
        );
    }

    fn render_sgr(fg: u32, bg: u32, modifier: u16) -> Vec<u8> {
        let mut output = Vec::new();
        write_sgr(
            &mut output,
            SgrStyleKey::from_cell(&make_cell("", fg, bg, modifier)),
        );
        output
    }

    // Frozen reference for the String/Vec implementation immediately before
    // the direct-byte writer. Keep this test-only: production has one encoder.
    fn legacy_sgr_colour(value: u32, channel: SgrChannel) -> String {
        let base = match channel {
            SgrChannel::Foreground => 30,
            SgrChannel::Background => 40,
        };
        let bright_base = match channel {
            SgrChannel::Foreground => 90,
            SgrChannel::Background => 100,
        };
        let extended = match channel {
            SgrChannel::Foreground => 38,
            SgrChannel::Background => 48,
        };
        let reset = match channel {
            SgrChannel::Foreground => 39,
            SgrChannel::Background => 49,
        };
        match value >> 24 {
            0x00 => match value & 0xff {
                0 => reset.to_string(),
                named @ 1..=8 => (base + named - 1).to_string(),
                named @ 9..=16 => (bright_base + named - 9).to_string(),
                _ => reset.to_string(),
            },
            0x01 => format!("{extended};5;{}", value & 0xff),
            0x02 => format!(
                "{extended};2;{};{};{}",
                (value >> 16) & 0xff,
                (value >> 8) & 0xff,
                value & 0xff
            ),
            _ => reset.to_string(),
        }
    }

    fn legacy_sgr_modifier_parts(value: u16) -> Vec<&'static str> {
        let mut parts = Vec::new();
        for (flag, code) in [
            (BOLD_MODIFIER, "1"),
            (DIM_MODIFIER, "2"),
            (ITALIC_MODIFIER, "3"),
        ] {
            if value & flag != 0 {
                parts.push(code);
            }
        }
        if value & UNDERLINED_MODIFIER != 0 {
            parts.push(match underline_style_from_modifier(value) {
                2 => "4:2",
                3 => "4:3",
                4 => "4:4",
                5 => "4:5",
                _ => "4",
            });
        }
        for (flag, code) in [
            (SLOW_BLINK_MODIFIER, "5"),
            (RAPID_BLINK_MODIFIER, "6"),
            (REVERSED_MODIFIER, "7"),
            (HIDDEN_MODIFIER, "8"),
            (CROSSED_OUT_MODIFIER, "9"),
        ] {
            if value & flag != 0 {
                parts.push(code);
            }
        }
        parts
    }

    fn legacy_build_sgr(fg: u32, bg: u32, modifier: u16) -> Vec<u8> {
        let mut parts = vec!["0".to_owned()];
        parts.extend(
            legacy_sgr_modifier_parts(modifier)
                .into_iter()
                .map(str::to_owned),
        );
        parts.push(legacy_sgr_colour(fg, SgrChannel::Foreground));
        parts.push(legacy_sgr_colour(bg, SgrChannel::Background));
        format!("\x1b[{}m", parts.join(";")).into_bytes()
    }

    fn packed_colour_corpus() -> Vec<u32> {
        let mut colours = Vec::new();
        colours.extend(0..=16);
        colours.extend([0x0000_0011, 0x0000_00ff, 0x00ab_cd00, 0x00ab_cd10]);
        for index in 0..=255 {
            colours.push(0x0100_0000 | index);
            colours.push(0x01ab_cd00 | index);
        }
        colours.extend([
            0x0200_0000,
            0x02ff_ffff,
            0x02ff_0000,
            0x0200_ff00,
            0x0200_00ff,
            0x0201_0203,
            0x027f_80fe,
            0x03_00_00_00,
            0x7f_12_34_56,
            0xff_ff_ff_ff,
        ]);
        colours
    }

    #[test]
    fn direct_sgr_writer_matches_frozen_legacy_for_every_modifier_value() {
        for modifier in 0..=u16::MAX {
            assert_eq!(
                render_sgr(0x02_12_34_56, 0x01_ab_cd_ef, modifier),
                legacy_build_sgr(0x02_12_34_56, 0x01_ab_cd_ef, modifier),
                "modifier {modifier:#06x}"
            );
        }
    }

    #[test]
    fn direct_sgr_writer_matches_frozen_legacy_for_packed_colour_corpus() {
        for colour in packed_colour_corpus() {
            for modifier in [0, u16::MAX, UNDERLINED_MODIFIER | (3 << 12)] {
                assert_eq!(
                    render_sgr(colour, 0, modifier),
                    legacy_build_sgr(colour, 0, modifier),
                    "foreground {colour:#010x}, modifier {modifier:#06x}"
                );
                assert_eq!(
                    render_sgr(0, colour, modifier),
                    legacy_build_sgr(0, colour, modifier),
                    "background {colour:#010x}, modifier {modifier:#06x}"
                );
            }
        }
    }

    #[test]
    fn canonical_style_key_equality_matches_legacy_rendered_byte_equality() {
        let pairs = [
            ((0, 0, 0), (0x7f12_3456, 0x00ab_cdff, 1 << 10)),
            ((0x0100_002a, 0x0100_0007, 0), (0x01ab_cd2a, 0x0112_3407, 0)),
            (
                (0, 0, UNDERLINED_MODIFIER),
                (0, 0, UNDERLINED_MODIFIER | (15 << 12)),
            ),
            (
                (0, 0, UNDERLINED_MODIFIER),
                (0, 0, UNDERLINED_MODIFIER | (3 << 12)),
            ),
            ((1, 0, BOLD_MODIFIER), (2, 0, BOLD_MODIFIER)),
            ((0x0201_0203, 0, 0), (0x0201_0203, 0, 1 << 11)),
        ];
        for (left, right) in pairs {
            let left_key = SgrStyleKey::from_cell(&make_cell("", left.0, left.1, left.2));
            let right_key = SgrStyleKey::from_cell(&make_cell("", right.0, right.1, right.2));
            assert_eq!(
                left_key == right_key,
                legacy_build_sgr(left.0, left.1, left.2)
                    == legacy_build_sgr(right.0, right.1, right.2),
                "left={left:?}, right={right:?}"
            );
        }
    }

    #[test]
    fn sgr_writer_supports_all_named_colours() {
        let expected_foreground = [
            30, 31, 32, 33, 34, 35, 36, 37, 90, 91, 92, 93, 94, 95, 96, 97,
        ];
        let expected_background = [
            40, 41, 42, 43, 44, 45, 46, 47, 100, 101, 102, 103, 104, 105, 106, 107,
        ];
        for named in 1..=16 {
            assert_eq!(
                render_sgr(named, 0, 0),
                format!("\x1b[0;{};49m", expected_foreground[(named - 1) as usize]).as_bytes()
            );
            assert_eq!(
                render_sgr(0, named, 0),
                format!("\x1b[0;39;{}m", expected_background[(named - 1) as usize]).as_bytes()
            );
        }
    }

    #[test]
    fn sgr_writer_supports_indexed_colours() {
        assert_eq!(
            render_sgr(0x01_00_00_AB, 0x01_00_00_16, 0),
            b"\x1b[0;38;5;171;48;5;22m"
        );
    }

    #[test]
    fn sgr_writer_supports_rgb_colours() {
        assert_eq!(
            render_sgr(0x02_FF_80_40, 0x02_01_02_03, 0),
            b"\x1b[0;38;2;255;128;64;48;2;1;2;3m"
        );
    }

    #[test]
    fn sgr_writer_preserves_modifier_order() {
        assert_eq!(
            render_sgr(2, 1, BOLD_MODIFIER | ITALIC_MODIFIER),
            b"\x1b[0;1;3;31;40m"
        );
    }

    #[test]
    fn sgr_writer_resets_previous_modifiers_when_cell_is_plain() {
        assert_eq!(render_sgr(0, 0, 0), b"\x1b[0;39;49m");
    }

    #[test]
    fn sgr_writer_preserves_curly_underline_style() {
        let modifier = crate::protocol::modifier_to_u16(
            crate::protocol::modifier_with_underline_style(ratatui::style::Modifier::UNDERLINED, 3),
        );

        assert_eq!(render_sgr(0, 0, modifier), b"\x1b[0;4:3;39;49m");
    }

    #[test]
    fn cells_equal_identical() {
        let a = make_cell("A", 2, 1, 0);
        let b = make_cell("A", 2, 1, 0);
        assert!(cells_equal(&a, &b));
    }

    #[test]
    fn cells_equal_different_symbol() {
        let a = make_cell("A", 2, 1, 0);
        let b = make_cell("B", 2, 1, 0);
        assert!(!cells_equal(&a, &b));
    }

    #[test]
    fn cells_equal_different_color() {
        let a = make_cell("A", 2, 1, 0);
        let b = make_cell("A", 3, 1, 0);
        assert!(!cells_equal(&a, &b));
    }

    #[test]
    fn blit_frame_hides_cursor_before_full_redraw_writes() {
        let frame = make_frame(
            2,
            2,
            vec![
                make_cell("H", 0, 0, 0),
                make_cell("i", 0, 0, 0),
                make_cell("!", 0, 0, 0),
                make_cell(" ", 0, 0, 0),
            ],
        );

        let mut output = Vec::new();
        blit_frame_to(&mut output, &frame, None);

        let output_str = String::from_utf8(output).unwrap();
        assert!(
            output_str.starts_with("\x1b[?2026h\x1b[?25l"),
            "should hide cursor inside synchronized frame painting during full redraw"
        );
    }

    #[test]
    fn blit_frame_hides_cursor_before_diff_writes() {
        let prev = make_frame(
            2,
            2,
            vec![
                make_cell("H", 0, 0, 0),
                make_cell("i", 0, 0, 0),
                make_cell("!", 0, 0, 0),
                make_cell(" ", 0, 0, 0),
            ],
        );

        let curr = make_frame(
            2,
            2,
            vec![
                make_cell("X", 0, 0, 0), // Changed
                make_cell("i", 0, 0, 0), // Same
                make_cell("!", 0, 0, 0), // Same
                make_cell(" ", 0, 0, 0), // Same
            ],
        );

        let mut output = Vec::new();
        blit_frame_to(&mut output, &curr, Some(&prev));

        let output_str = String::from_utf8(output).unwrap();
        assert!(
            output_str.starts_with("\x1b[?2026h\x1b[?25l"),
            "should hide cursor inside synchronized frame painting during diff"
        );
    }

    #[test]
    fn blit_frame_wraps_frame_in_synchronized_output() {
        let frame = make_frame(1, 1, vec![make_cell("A", 0, 0, 0)]);

        let mut output = Vec::new();
        blit_frame_to(&mut output, &frame, None);

        let output_str = String::from_utf8(output).unwrap();
        assert!(
            output_str.starts_with("\x1b[?2026h\x1b[?25l"),
            "should begin synchronized output before frame writes"
        );
        let sync_end = output_str
            .find("\x1b[?2026l")
            .expect("should end synchronized output after frame writes");
        assert!(
            sync_end > 0,
            "should end synchronized output after frame writes"
        );
    }

    #[test]
    fn blit_frame_begins_sync_before_hiding_cursor_after_visible_cursor_repeat() {
        let visible = FrameData {
            cells: vec![make_cell("A", 0, 0, 0); 9],
            width: 3,
            height: 3,
            cursor: Some(CursorState {
                x: 2,
                y: 1,
                visible: true,
                shape: 0,
            }),
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };
        let mut changed = visible.clone();
        changed.cells[0] = make_cell("B", 0, 0, 0);

        let mut last_visible_cursor = None;
        let mut last_cursor_shape = 0;
        let mut first_output = Vec::new();
        blit_frame_to_with_cursor_memory_and_policy(
            &mut first_output,
            &visible,
            None,
            &mut last_visible_cursor,
            &mut last_cursor_shape,
            true,
            false,
        );

        let mut second_output = Vec::new();
        blit_frame_to_with_cursor_memory_and_policy(
            &mut second_output,
            &changed,
            Some(&visible),
            &mut last_visible_cursor,
            &mut last_cursor_shape,
            true,
            false,
        );

        let second_output_str = std::str::from_utf8(&second_output).unwrap();
        assert!(
            second_output_str.starts_with("\x1b[?2026h\x1b[?25l"),
            "next frame should enter synchronized output before hiding the cursor"
        );

        let hide = second_output_str
            .find("\x1b[?25l")
            .expect("second frame should hide cursor before painting");
        let first_paint = second_output_str
            .find("\x1b[1;1H")
            .expect("second frame should paint changed cell");
        assert!(
            hide < first_paint,
            "cursor should still hide before painting"
        );

        first_output.extend_from_slice(&second_output);
        let combined = String::from_utf8(first_output).unwrap();
        assert!(
            combined.contains("\x1b[?2026l\x1b[2;3H\x1b[?25h\x1b[?2026h\x1b[?25l"),
            "post-sync cursor repeat should be followed by a synchronized cursor hide"
        );
    }

    #[test]
    fn blit_frame_can_repeat_final_cursor_state_after_synchronized_output() {
        let frame = FrameData {
            cells: vec![make_cell("A", 0, 0, 0); 9],
            width: 3,
            height: 3,
            cursor: Some(CursorState {
                x: 2,
                y: 1,
                visible: true,
                shape: 0,
            }),
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };

        let mut last_visible_cursor = None;
        let mut last_cursor_shape = 0;
        let mut output = Vec::new();
        blit_frame_to_with_cursor_memory_and_policy(
            &mut output,
            &frame,
            None,
            &mut last_visible_cursor,
            &mut last_cursor_shape,
            true,
            false,
        );

        let output_str = String::from_utf8(output).unwrap();
        let sync_end = output_str
            .find("\x1b[?2026l")
            .expect("should end synchronized output");
        let trailing_cursor = &output_str[sync_end + "\x1b[?2026l".len()..];
        assert_eq!(
            trailing_cursor, "\x1b[2;3H\x1b[?25h",
            "should expose only the final cursor state after synchronized output"
        );
    }

    #[test]
    fn blit_frame_can_skip_final_cursor_state_after_synchronized_output() {
        let frame = FrameData {
            cells: vec![make_cell("A", 0, 0, 0); 9],
            width: 3,
            height: 3,
            cursor: Some(CursorState {
                x: 2,
                y: 1,
                visible: true,
                shape: 0,
            }),
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };

        let mut last_visible_cursor = None;
        let mut last_cursor_shape = 0;
        let mut output = Vec::new();
        blit_frame_to_with_cursor_memory_and_policy(
            &mut output,
            &frame,
            None,
            &mut last_visible_cursor,
            &mut last_cursor_shape,
            false,
            false,
        );

        let output_str = String::from_utf8(output).unwrap();
        let sync_end = output_str
            .find("\x1b[?2026l")
            .expect("should end synchronized output");
        let trailing_cursor = &output_str[sync_end + "\x1b[?2026l".len()..];
        assert_eq!(
            trailing_cursor, "",
            "should not expose a post-sync cursor repeat when the target terminal flickers on it"
        );
    }

    #[test]
    fn drawn_cursor_reverses_visible_cursor_cell() {
        let frame = FrameData {
            cells: vec![make_cell("A", 0, 0, 0); 9],
            width: 3,
            height: 3,
            cursor: Some(CursorState {
                x: 2,
                y: 1,
                visible: true,
                shape: 6,
            }),
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };
        let drawn = frame_with_drawn_cursor(frame.clone());

        assert_eq!(drawn.cells[5].modifier, REVERSED_MODIFIER);
        assert_eq!(frame.cells[5].modifier, 0);

        let encoded = BlitEncoder::new().encode_with_suppressed_visible_cursor(&drawn, false);
        let output_str = String::from_utf8(encoded.bytes).unwrap();

        assert!(
            output_str.contains("\x1b[2;3H\x1b[6 q\x1b[?25l"),
            "drawn cursor mode should park the host cursor hidden at the focused cursor position"
        );
        assert!(
            !output_str.contains("\x1b[?25h"),
            "drawn cursor mode should not show the host cursor"
        );
        assert!(
            output_str.contains("\x1b[0;7;39;49mA"),
            "drawn cursor should be emitted as reverse-video cell content"
        );
    }

    #[test]
    fn drawn_cursor_ignores_hidden_cursor() {
        let frame = FrameData {
            cells: vec![make_cell("A", 0, 0, 0)],
            width: 1,
            height: 1,
            cursor: Some(CursorState {
                x: 0,
                y: 0,
                visible: false,
                shape: 0,
            }),
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };

        assert_eq!(frame_with_drawn_cursor(frame.clone()), frame);
    }

    #[test]
    fn blit_frame_emits_cursor_shape_before_visibility_without_touching_ime_anchor() {
        let frame = FrameData {
            cells: vec![make_cell("A", 0, 0, 0)],
            width: 1,
            height: 1,
            cursor: Some(CursorState {
                x: 0,
                y: 0,
                visible: true,
                shape: 6,
            }),
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };

        let mut last_visible_cursor = None;
        let mut last_cursor_shape = 0;
        let mut output = Vec::new();
        blit_frame_to_with_cursor_memory_and_policy(
            &mut output,
            &frame,
            None,
            &mut last_visible_cursor,
            &mut last_cursor_shape,
            true,
            false,
        );

        let output_str = String::from_utf8(output).unwrap();
        let final_cursor = output_str
            .find("\x1b[1;1H\x1b[6 q\x1b[?25h")
            .expect("should set cursor shape before showing cursor");
        let sync_end = output_str
            .find("\x1b[?2026l")
            .expect("should end synchronized output");
        assert!(
            final_cursor < sync_end,
            "shape should be part of the synchronized final cursor state"
        );
        let trailing_cursor = &output_str[sync_end + "\x1b[?2026l".len()..];
        assert_eq!(
            trailing_cursor, "\x1b[1;1H\x1b[?25h",
            "IME anchor update should preserve the existing position/visibility-only contract"
        );
    }

    #[test]
    fn blit_frame_repeats_explicit_hidden_cursor_anchor_after_synchronized_output() {
        let visible = FrameData {
            cells: vec![make_cell("A", 0, 0, 0); 9],
            width: 3,
            height: 3,
            cursor: Some(CursorState {
                x: 0,
                y: 0,
                visible: true,
                shape: 0,
            }),
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };
        let hidden = FrameData {
            cells: vec![make_cell("B", 0, 0, 0); 9],
            width: 3,
            height: 3,
            cursor: Some(CursorState {
                x: 2,
                y: 1,
                visible: false,
                shape: 0,
            }),
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };
        let mut last_visible_cursor = None;
        let mut last_cursor_shape = 0;
        let mut output = Vec::new();

        blit_frame_to_with_cursor_memory_and_policy(
            &mut output,
            &visible,
            None,
            &mut last_visible_cursor,
            &mut last_cursor_shape,
            true,
            false,
        );
        output.clear();
        blit_frame_to_with_cursor_memory_and_policy(
            &mut output,
            &hidden,
            Some(&visible),
            &mut last_visible_cursor,
            &mut last_cursor_shape,
            true,
            false,
        );

        let output_str = String::from_utf8(output).unwrap();
        let sync_end = output_str
            .find("\x1b[?2026l")
            .expect("should end synchronized output");
        let trailing_cursor = &output_str[sync_end + "\x1b[?2026l".len()..];
        assert_eq!(
            trailing_cursor, "\x1b[2;3H\x1b[?25l",
            "should repeat the explicit hidden cursor position while preserving visibility"
        );
    }

    #[test]
    fn blit_frame_emits_osc8_for_linked_cells() {
        let mut frame = make_frame(
            3,
            1,
            vec![
                linked_cell("L", 0),
                linked_cell("i", 0),
                make_cell("!", 0, 0, 0),
            ],
        );
        frame.hyperlinks.push("https://example.com".to_owned());

        let mut output = Vec::new();
        blit_frame_to(&mut output, &frame, None);

        let output_str = String::from_utf8(output).unwrap();
        assert!(output_str.contains("\x1b]8;;https://example.com\x1b\\L"));
        assert!(output_str.contains('i'));
        assert!(output_str.contains("\x1b]8;;\x1b\\"));
    }

    #[test]
    fn blit_frame_sanitizes_hyperlink_uris() {
        let mut frame = make_frame(1, 1, vec![linked_cell("L", 0)]);
        frame
            .hyperlinks
            .push("https://exa\x1b\x07mple.com".to_owned());

        let mut output = Vec::new();
        blit_frame_to(&mut output, &frame, None);

        let output_str = String::from_utf8(output).unwrap();
        assert!(output_str.contains("\x1b]8;;https://example.com\x1b\\L"));
    }

    #[test]
    fn blit_frame_first_frame_produces_output() {
        let frame = make_frame(
            2,
            2,
            vec![
                make_cell("H", 0, 0, 0),
                make_cell("i", 0, 0, 0),
                make_cell("!", 0, 0, 0),
                make_cell(" ", 0, 0, 0),
            ],
        );

        let mut output = Vec::new();
        blit_frame_to(&mut output, &frame, None);

        let output_str = String::from_utf8(output).unwrap();
        // Full redraw should start with clear screen.
        assert!(
            output_str.contains("\x1b[2J"),
            "full redraw should clear screen"
        );
        assert!(
            output_str.contains('H') || output_str.contains('i'),
            "should contain cell content"
        );
    }

    #[test]
    fn blit_frame_diff_only_writes_changed_cells() {
        let prev = make_frame(
            2,
            2,
            vec![
                make_cell("H", 0, 0, 0),
                make_cell("i", 0, 0, 0),
                make_cell("!", 0, 0, 0),
                make_cell(" ", 0, 0, 0),
            ],
        );

        // Only the first cell changed.
        let curr = make_frame(
            2,
            2,
            vec![
                make_cell("X", 0, 0, 0), // Changed
                make_cell("i", 0, 0, 0), // Same
                make_cell("!", 0, 0, 0), // Same
                make_cell(" ", 0, 0, 0), // Same
            ],
        );

        let mut output = Vec::new();
        blit_frame_to(&mut output, &curr, Some(&prev));

        let output_str = String::from_utf8(output).unwrap();
        // Diff should NOT clear the screen.
        assert!(
            !output_str.contains("\x1b[2J"),
            "diff should not clear screen"
        );
        // Should contain the changed cell content.
        assert!(output_str.contains('X'), "should contain changed cell 'X'");
    }

    #[test]
    fn scroll_sized_ascii_shift_batches_changed_cells_by_row() {
        const WIDTH: u16 = 140;
        const HEIGHT: u16 = 50;
        let prev = make_frame(
            WIDTH,
            HEIGHT,
            vec![make_cell("A", 0, 0, 0); usize::from(WIDTH) * usize::from(HEIGHT)],
        );
        let curr = make_frame(
            WIDTH,
            HEIGHT,
            vec![make_cell("B", 0, 0, 0); usize::from(WIDTH) * usize::from(HEIGHT)],
        );

        let mut output = Vec::new();
        blit_frame_to(&mut output, &curr, Some(&prev));

        let cup_count = output.iter().filter(|&&byte| byte == b'H').count();
        assert!(
            cup_count <= usize::from(HEIGHT) + 2,
            "one dense scroll frame should need at most one CUP per row plus cursor anchors, got {cup_count}"
        );
        assert!(
            output.len() <= 16_290,
            "one dense scroll frame should stay below 25% of the 65,161-byte live baseline, got {} bytes",
            output.len()
        );
    }

    #[test]
    fn batched_ascii_diff_replays_to_current_frame() {
        let prev = make_frame(4, 3, vec![make_cell("A", 0, 0, 0); 12]);
        let curr = make_frame(4, 3, vec![make_cell("B", 0, 0, 0); 12]);
        let mut terminal = crate::ghostty::Terminal::new(4, 3, 0).unwrap();

        let mut initial = Vec::new();
        blit_frame_to(&mut initial, &prev, None);
        terminal.write(&initial);

        let mut diff = Vec::new();
        blit_frame_to(&mut diff, &curr, Some(&prev));
        terminal.write(&diff);

        for row in 0..3 {
            for col in 0..4 {
                let (_, graphemes) = terminal.screen_cell(col, row).unwrap();
                assert_eq!(graphemes, vec![u32::from('B')]);
            }
        }
    }

    #[test]
    fn encoder_size_change_repaints_without_clearing() {
        let prev = make_frame(2, 2, vec![make_cell("A", 0, 0, 0); 4]);
        let curr = make_frame(3, 2, vec![make_cell("B", 0, 0, 0); 6]);
        let mut encoder = BlitEncoder::new();
        let initial = encoder.encode(&prev, false);
        encoder.commit(prev, initial);

        let encoded = encoder.encode(&curr, false);
        assert!(encoded.full);
        let output = String::from_utf8(encoded.bytes).unwrap();

        assert!(!output.contains("\x1b[2J"));
        assert!(output.bytes().filter(|byte| *byte == b'B').count() >= 6);
    }

    #[test]
    fn encoder_forced_repaint_writes_all_cells_without_clearing() {
        let frame = make_frame(3, 2, vec![make_cell("A", 0, 0, 0); 6]);
        let mut encoder = BlitEncoder::new();
        let initial = encoder.encode(&frame, false);
        encoder.commit(frame.clone(), initial);

        let encoded = encoder.encode(&frame, true);
        assert!(encoded.full);
        let output = String::from_utf8(encoded.bytes).unwrap();

        assert!(!output.contains("\x1b[2J"));
        assert!(output.bytes().filter(|byte| *byte == b'A').count() >= 6);
    }

    #[test]
    fn blit_frame_positions_cursor() {
        let frame = FrameData {
            cells: vec![make_cell("A", 0, 0, 0)],
            width: 1,
            height: 1,
            cursor: Some(CursorState {
                x: 0,
                y: 0,
                visible: true,
                shape: 0,
            }),
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };

        let mut output = Vec::new();
        blit_frame_to(&mut output, &frame, None);

        let output_str = String::from_utf8(output).unwrap();
        assert!(
            output_str.contains("\x1b[1;1H"),
            "should position cursor at (1,1)"
        );
    }

    #[test]
    fn blit_frame_hides_cursor_when_invisible() {
        let frame = FrameData {
            cells: vec![make_cell("A", 0, 0, 0)],
            width: 1,
            height: 1,
            cursor: Some(CursorState {
                x: 0,
                y: 0,
                visible: false,
                shape: 0,
            }),
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };

        let mut output = Vec::new();
        blit_frame_to(&mut output, &frame, None);

        let output_str = String::from_utf8(output).unwrap();
        assert!(
            output_str.contains("\x1b[?25l"),
            "should hide cursor when invisible"
        );
    }

    #[test]
    fn blit_frame_no_cursor_hides_cursor() {
        let frame = FrameData {
            cells: vec![make_cell("A", 0, 0, 0)],
            width: 1,
            height: 1,
            cursor: None,
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };

        let mut output = Vec::new();
        blit_frame_to(&mut output, &frame, None);

        let output_str = String::from_utf8(output).unwrap();
        assert!(
            output_str.contains("\x1b[?25l"),
            "should hide cursor when no cursor state"
        );
    }

    #[test]
    fn blit_frame_restores_cursor_visibility() {
        // First frame: cursor hidden.
        let prev = FrameData {
            cells: vec![make_cell("A", 0, 0, 0)],
            width: 1,
            height: 1,
            cursor: Some(CursorState {
                x: 0,
                y: 0,
                visible: false,
                shape: 0,
            }),
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };

        let mut output = Vec::new();
        blit_frame_to(&mut output, &prev, None);
        assert!(
            String::from_utf8(output).unwrap().contains("\x1b[?25l"),
            "first frame should hide cursor"
        );

        // Second frame: cursor visible — should restore visibility.
        let curr = FrameData {
            cells: vec![make_cell("B", 0, 0, 0)],
            width: 1,
            height: 1,
            cursor: Some(CursorState {
                x: 0,
                y: 0,
                visible: true,
                shape: 0,
            }),
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };

        let mut output = Vec::new();
        blit_frame_to(&mut output, &curr, Some(&prev));
        let output_str = String::from_utf8(output).unwrap();
        assert!(
            output_str.contains("\x1b[?25h"),
            "second frame should restore cursor visibility with ?25h"
        );
        assert!(
            output_str.contains("\x1b[1;1H"),
            "should position cursor before showing it"
        );
    }

    #[test]
    fn blit_frame_positions_cursor_before_showing_it() {
        let prev = FrameData {
            cells: vec![make_cell("A", 0, 0, 0); 9],
            width: 3,
            height: 3,
            cursor: Some(CursorState {
                x: 0,
                y: 0,
                visible: true,
                shape: 0,
            }),
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };
        let mut curr = prev.clone();
        curr.cells[0] = make_cell("B", 0, 0, 0);
        curr.cursor = Some(CursorState {
            x: 2,
            y: 2,
            visible: true,
            shape: 0,
        });

        let mut output = Vec::new();
        blit_frame_to(&mut output, &curr, Some(&prev));
        let output_str = String::from_utf8(output).unwrap();
        let final_move = output_str
            .rfind("\x1b[3;3H")
            .expect("should move cursor to final position");
        let show = output_str
            .rfind("\x1b[?25h")
            .expect("should show cursor after positioning it");

        assert!(
            final_move < show,
            "should move cursor to final position before showing it"
        );
    }

    #[test]
    fn blit_frame_parks_hidden_cursor_at_last_visible_position() {
        let visible = FrameData {
            cells: vec![make_cell("A", 0, 0, 0); 9],
            width: 3,
            height: 3,
            cursor: Some(CursorState {
                x: 1,
                y: 1,
                visible: true,
                shape: 0,
            }),
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };
        let hidden = FrameData {
            cells: vec![make_cell("B", 0, 0, 0); 9],
            width: 3,
            height: 3,
            cursor: None,
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };
        let mut last_visible_cursor = None;
        let mut last_cursor_shape = 0;
        let mut output = Vec::new();

        blit_frame_to_with_cursor_memory(
            &mut output,
            &visible,
            None,
            &mut last_visible_cursor,
            &mut last_cursor_shape,
            false,
        );
        output.clear();
        blit_frame_to_with_cursor_memory(
            &mut output,
            &hidden,
            Some(&visible),
            &mut last_visible_cursor,
            &mut last_cursor_shape,
            false,
        );

        let output_str = String::from_utf8(output).unwrap();
        let park = output_str
            .rfind("\x1b[2;2H")
            .expect("should park hidden cursor at last visible position");
        let hide = output_str
            .rfind("\x1b[?25l")
            .expect("should keep hidden cursor hidden");
        assert!(park < hide, "should park cursor before hiding it");
    }

    #[test]
    fn blit_frame_parks_hidden_cursor_at_bottom_right_without_history() {
        let frame = FrameData {
            cells: vec![make_cell("A", 0, 0, 0); 6],
            width: 3,
            height: 2,
            cursor: None,
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };
        let mut last_visible_cursor = None;
        let mut last_cursor_shape = 0;
        let mut output = Vec::new();

        blit_frame_to_with_cursor_memory(
            &mut output,
            &frame,
            None,
            &mut last_visible_cursor,
            &mut last_cursor_shape,
            false,
        );

        let output_str = String::from_utf8(output).unwrap();
        assert!(
            output_str.contains("\x1b[2;3H\x1b[?25l"),
            "should park hidden cursor at bottom-right before ending the frame"
        );
    }

    #[test]
    fn blit_frame_hides_previous_visible_cursor_when_next_frame_has_none() {
        let prev = FrameData {
            cells: vec![make_cell("A", 0, 0, 0)],
            width: 1,
            height: 1,
            cursor: Some(CursorState {
                x: 0,
                y: 0,
                visible: true,
                shape: 0,
            }),
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };
        let curr = FrameData {
            cells: vec![make_cell("B", 0, 0, 0)],
            width: 1,
            height: 1,
            cursor: None,
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };

        let mut output = Vec::new();
        blit_frame_to(&mut output, &curr, Some(&prev));

        assert!(
            String::from_utf8(output).unwrap().contains("\x1b[?25l"),
            "diff redraw should hide a previously visible cursor when the next frame has none"
        );
    }

    #[test]
    fn full_redraw_skips_trailing_cells_covered_by_wide_graphemes() {
        let frame = FrameData {
            cells: vec![
                make_cell(WIDE_GRAPHEME, 0, 0, 0),
                make_cell(" ", 0, 0, 0),
                make_cell("Z", 0, 0, 0),
            ],
            width: 3,
            height: 1,
            cursor: None,
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };

        let mut output = Vec::new();
        blit_frame_to(&mut output, &frame, None);
        let output_str = String::from_utf8(output).unwrap();

        assert!(output_str.contains("\x1b[1;1H"));
        assert!(!output_str.contains("\x1b[1;2H"));
        assert!(output_str.contains("\x1b[1;3H"));
    }

    #[test]
    fn full_redraw_skips_trailing_cells_covered_by_halfwidth_voiced_kana() {
        let frame = FrameData {
            cells: vec![
                make_cell(HALFWIDTH_VOICED_KANA, 0, 0, 0),
                make_skip_cell(" ", 0, 0, 0),
                make_cell("Z", 0, 0, 0),
            ],
            width: 3,
            height: 1,
            cursor: None,
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };

        let mut output = Vec::new();
        blit_frame_to(&mut output, &frame, None);
        let output_str = String::from_utf8(output).unwrap();

        assert!(output_str.contains("\x1b[1;1H"));
        assert!(!output_str.contains("\x1b[1;2H"));
        assert!(output_str.contains("\x1b[1;3H"));
    }

    #[test]
    fn diff_redraw_reveals_cells_hidden_by_previous_wide_graphemes() {
        let prev = FrameData {
            cells: vec![
                make_cell(WIDE_GRAPHEME, 0, 0, 0),
                make_cell(" ", 0, 0, 0),
                make_cell("Z", 0, 0, 0),
            ],
            width: 3,
            height: 1,
            cursor: None,
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };
        let curr = FrameData {
            cells: vec![
                make_cell("A", 0, 0, 0),
                make_cell(" ", 0, 0, 0),
                make_cell("Z", 0, 0, 0),
            ],
            width: 3,
            height: 1,
            cursor: None,
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };

        let mut output = Vec::new();
        blit_frame_to(&mut output, &curr, Some(&prev));
        let output_str = String::from_utf8(output).unwrap();

        assert!(output_str.contains("\x1b[1;1H"));
        assert!(
            output_str.contains("\x1b[1;2H"),
            "cells hidden by a previous wide grapheme must be redrawn when they become visible"
        );
    }

    #[test]
    fn diff_redraw_skips_new_trailing_cells_covered_by_wide_graphemes() {
        let prev = FrameData {
            cells: vec![
                make_cell("A", 0, 0, 0),
                make_cell("B", 0, 0, 0),
                make_cell("Z", 0, 0, 0),
            ],
            width: 3,
            height: 1,
            cursor: None,
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };
        let curr = FrameData {
            cells: vec![
                make_cell(WIDE_GRAPHEME, 0, 0, 0),
                make_cell(" ", 0, 0, 0),
                make_cell("Z", 0, 0, 0),
            ],
            width: 3,
            height: 1,
            cursor: None,
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };

        let mut output = Vec::new();
        blit_frame_to(&mut output, &curr, Some(&prev));
        let output_str = String::from_utf8(output).unwrap();

        assert!(output_str.contains("\x1b[1;1H"));
        assert!(!output_str.contains("\x1b[1;2H"));
    }

    #[test]
    fn diff_redraw_reveals_cells_hidden_by_previous_halfwidth_voiced_kana() {
        let prev = FrameData {
            cells: vec![
                make_cell(HALFWIDTH_VOICED_KANA, 0, 0, 0),
                make_skip_cell(" ", 0, 0, 0),
                make_cell("Z", 0, 0, 0),
            ],
            width: 3,
            height: 1,
            cursor: None,
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };
        let curr = FrameData {
            cells: vec![
                make_cell("A", 0, 0, 0),
                make_cell(" ", 0, 0, 0),
                make_cell("Z", 0, 0, 0),
            ],
            width: 3,
            height: 1,
            cursor: None,
            hyperlinks: Vec::new(),
            graphics: Vec::new(),
        };

        let mut output = Vec::new();
        blit_frame_to(&mut output, &curr, Some(&prev));
        let output_str = String::from_utf8(output).unwrap();

        assert!(output_str.contains("\x1b[1;1H"));
        assert!(
            output_str.contains("\x1b[1;2H"),
            "cells hidden by a previous halfwidth voiced kana must be redrawn when visible"
        );
    }
}
