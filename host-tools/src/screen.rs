//! Checks of a guest's screen, from QEMU's screendump (a binary PPM).
//!
//! `screen text <shot.ppm> <font.rs> <row> <text>`: the cells of text row
//! `<row>` (16 pixels high, 8 wide) are, pixel for pixel, the font's glyphs
//! of `<text>` in white on black. The font is the kernel's
//! (`formats/src/font.rs`: one row of 16 bytes per glyph, its character in
//! the comment after it).
//!
//! `screen rows <shot.ppm> <lines>`: the screen holds `<lines>` lines of text
//! from the top (maybe one more), the first of them the banner ending in its
//! 35th cell, or it scrolled and every row holds text. A row holds text if
//! any pixel in it differs from the top-right corner's (the background).
//!
//! Exit status 0: the screen is right. 1: it is not, and the one line on
//! standard output says how. 2: the check could not be made (the line
//! says why), which a test must count as a failure too.

use std::process::exit;

struct Picture {
    width: usize,
    height: usize,
    pixels: Vec<u8>,
}

impl Picture {
    fn read(path: &str) -> Result<Picture, String> {
        let data = std::fs::read(path).map_err(|e| format!("no picture of the screen: {path}: {e}"))?;
        // "P6", width, height, maximum value, each after white space, then
        // one white-space byte and the pixels, three bytes each.
        let mut fields = Vec::new();
        let mut at = 0;
        while fields.len() < 4 {
            while data.get(at).is_some_and(u8::is_ascii_whitespace) {
                at += 1;
            }
            let from = at;
            while data.get(at).is_some_and(|b| !b.is_ascii_whitespace()) {
                at += 1;
            }
            if from == at {
                return Err(format!("{path}: not a PPM picture (its header ends early)"));
            }
            fields.push(String::from_utf8_lossy(&data[from..at]).into_owned());
        }
        let num = |i: usize| {
            fields[i]
                .parse::<usize>()
                .map_err(|_| format!("{path}: not a PPM picture ({:?})", fields[i]))
        };
        let (width, height, max) = (num(1)?, num(2)?, num(3)?);
        if fields[0] != "P6" || max != 255 {
            return Err(format!("{path}: not an 8-bit binary PPM picture ({} {max})", fields[0]));
        }
        let pixels = data.get(at + 1..).unwrap_or_default().to_vec();
        if pixels.len() < width * height * 3 {
            return Err(format!("{path}: {} bytes of pixels for {width}x{height}", pixels.len()));
        }
        Ok(Picture { width, height, pixels })
    }

    fn pixel(&self, x: usize, y: usize) -> [u8; 3] {
        let i = (y * self.width + x) * 3;
        [self.pixels[i], self.pixels[i + 1], self.pixels[i + 2]]
    }
}

/// The font's glyphs: each character and its 16 rows (high bit leftmost).
fn font(path: &str) -> Result<Vec<(char, [u8; 16])>, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
    let mut glyphs = Vec::new();
    for line in text.lines() {
        let Some((rows, comment)) = line.trim().strip_prefix('[').and_then(|l| l.split_once("], // ")) else {
            continue;
        };
        // The comment is the character quoted: 'c', or "'" for the quote.
        let quoted = comment.trim_end();
        let inner = quoted.get(1..quoted.len().saturating_sub(1)).unwrap_or_default();
        let c = match inner {
            "\\\\" => '\\',
            s if s.chars().count() == 1 => s.chars().next().unwrap_or_default(),
            _ => continue,
        };
        let mut g = [0u8; 16];
        let mut n = 0;
        for (i, v) in rows.split(',').enumerate() {
            let v = v.trim();
            let byte = v.strip_prefix("0x").and_then(|h| u8::from_str_radix(h, 16).ok());
            match (g.get_mut(i), byte) {
                (Some(slot), Some(b)) => *slot = b,
                _ => return Err(format!("{path}: a glyph row that is not 16 bytes: {line}")),
            }
            n += 1;
        }
        if n != 16 {
            return Err(format!("{path}: a glyph of {n} rows: {line}"));
        }
        glyphs.push((c, g));
    }
    Ok(glyphs)
}

/// Text row `row` holds `text` in the font, white on black.
fn text(shot: &Picture, glyphs: &[(char, [u8; 16])], row: usize, text: &str) -> Result<(), String> {
    for (n, c) in text.chars().enumerate() {
        let Some((_, g)) = glyphs.iter().find(|(k, _)| *k == c) else {
            return Err(format!("the font has no glyph for {c:?}"));
        };
        for (dy, bits) in g.iter().enumerate() {
            for dx in 0..8 {
                let want = if bits & (0x80 >> dx) != 0 { [255; 3] } else { [0; 3] };
                let (x, y) = (n * 8 + dx, row * 16 + dy);
                if x >= shot.width || y >= shot.height {
                    return Err(format!(
                        "character {n} ({c:?}) is off a {}x{} screen",
                        shot.width, shot.height
                    ));
                }
                let got = shot.pixel(x, y);
                if got != want {
                    return Err(format!(
                        "character {n} ({c:?}) of row {row}: pixel ({dx},{dy}) is {got:?}, not {want:?}"
                    ));
                }
            }
        }
    }
    Ok(())
}

/// The screen's text rows are the first `lines` (maybe one more), the
/// first ending in the 35th cell; or it scrolled and all hold text.
fn rows(shot: &Picture, lines: usize) -> Result<(), String> {
    let bg = shot.pixel(shot.width - 1, 0);
    // How far right each row of 16 pixels has something not background.
    let ends: Vec<usize> = (0..shot.height / 16)
        .map(|r| {
            (r * 16..r * 16 + 16)
                .flat_map(|y| (0..shot.width).map(move |x| (x, y)))
                .filter(|&(x, y)| shot.pixel(x, y) != bg)
                .map(|(x, _)| x + 1)
                .max()
                .unwrap_or(0)
        })
        .collect();
    let text: Vec<usize> = ends
        .iter()
        .enumerate()
        .filter(|(_, n)| **n > 0)
        .map(|(i, _)| i)
        .collect();
    if lines >= ends.len() {
        if text != (0..ends.len()).collect::<Vec<_>>() {
            return Err(format!(
                "the screen scrolled, but its rows of text are {text:?}, not all {}",
                ends.len()
            ));
        }
        return Ok(());
    }
    let from_top = text.iter().enumerate().all(|(i, r)| i == *r);
    if text.len() < lines || text.len() > lines + 1 || !from_top {
        return Err(format!(
            "the screen's rows of text are {text:?}, not the first {lines} or {}",
            lines + 1
        ));
    }
    if !(34 * 8 < ends[0] && ends[0] <= 35 * 8) {
        return Err(format!(
            "the first row of text ends at pixel {}, not in the banner's 35th cell",
            ends[0]
        ));
    }
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let arg = |i: usize| args.get(i).map(String::as_str);
    let result = match (arg(1), args.len()) {
        (Some("text"), 6) => match (Picture::read(&args[2]), font(&args[3]), args[4].parse::<usize>()) {
            (Ok(shot), Ok(glyphs), Ok(row)) => text(&shot, &glyphs, row, &args[5]),
            (Err(e), ..) | (_, Err(e), _) => {
                println!("{e}");
                exit(2);
            }
            (.., Err(_)) => {
                println!("row {:?} is not a number", args[4]);
                exit(2);
            }
        },
        (Some("rows"), 4) => match (Picture::read(&args[2]), args[3].parse::<usize>()) {
            (Ok(shot), Ok(lines)) => rows(&shot, lines),
            (Err(e), _) => {
                println!("{e}");
                exit(2);
            }
            (_, Err(_)) => {
                println!("{:?} is not a number of lines", args[3]);
                exit(2);
            }
        },
        _ => {
            println!("usage: screen text <shot.ppm> <font.rs> <row> <text> | screen rows <shot.ppm> <lines>");
            exit(2);
        }
    };
    if let Err(e) = result {
        println!("{e}");
        exit(1);
    }
}
