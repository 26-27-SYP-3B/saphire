use std::collections::HashMap;

use crate::{music, sanitize};

/// What an uploaded file says about itself: the title and the artist its tags name, and how
/// long it plays. A file that does not say something stays empty or zero, so the library shows
/// a dash instead of a guess.
///
/// Only MP3 is read here, because that is the format whose length can be worked out from the
/// bytes alone (frame headers). The other accepted containers would need their own container
/// parser, so they keep no duration. The values are read into the track row, which is the shape
/// `api-docs.md` documents — this shape is not answered as itself.
#[derive(Debug, Default, PartialEq)]
pub struct AudioMeta {
    pub title: String,
    pub artist: String,
    pub duration_ms: i64,
}

pub fn read_audio_meta(data: &[u8]) -> AudioMeta {
    let (tags, audio_start) = read_id3v2(data);
    AudioMeta {
        title: tags.get("TIT2").cloned().unwrap_or_default(),
        artist: tags.get("TPE1").cloned().unwrap_or_default(),
        duration_ms: mp3_duration_ms(data, audio_start),
    }
}

/// Makes text that came out of a file safe to show. It is the same rule an uploaded name goes
/// through (see `sanitize`), so a tag cannot be longer, or cleaned differently, than a name.
pub fn clean_tag_text(text: &str) -> String {
    sanitize::without_control_chars(text, music::MAX_TITLE_LEN)
}

/// The text frames of an ID3v2 tag and where the audio data begins. A file with no tag gives an
/// empty map and offset 0.
pub fn read_id3v2(data: &[u8]) -> (HashMap<String, String>, usize) {
    let mut tags: HashMap<String, String> = HashMap::new();
    if data.len() < 10 || &data[..3] != b"ID3" {
        return (tags, 0);
    }

    // The header is "ID3", then version, revision, flags, then a syncsafe size.
    let version = data[3];
    let flags = data[5];
    let mut tag_size = synchsafe(&data[6..10]);
    if tag_size > data.len() - 10 {
        tag_size = data.len() - 10; // a tag that claims more than the file has
    }
    let end = 10 + tag_size;

    if version < 3 {
        // ID3v2.2 frames have a different header shape, so a v2.2 tag is left unread; the audio
        // still starts after it.
        return (tags, end);
    }

    if flags & 0x40 != 0 {
        // An extended header is rare, and its size field counts itself in ID3v2.4 but not in
        // ID3v2.3, so a file with one is left unread rather than read from the wrong offset. The
        // audio still starts after the whole tag.
        return (tags, end);
    }

    let mut position = 10;
    while position + 10 <= end {
        let id = &data[position..position + 4];
        if id[0] == 0 {
            break; // the rest of the tag is padding
        }

        // v2.3 stores the frame size as a plain number, v2.4 as a syncsafe one.
        let mut size = u32::from_be_bytes([data[position + 4], data[position + 5], data[position + 6], data[position + 7]]) as usize;
        if version >= 4 {
            size = synchsafe(&data[position + 4..position + 8]);
        }
        if size == 0 || position + 10 + size > end {
            break; // a frame that does not fit in the tag cannot be read
        }

        if id == b"TIT2" || id == b"TPE1" {
            let name = String::from_utf8_lossy(id).to_string();
            tags.insert(name, clean_tag_text(&decode_frame_text(&data[position + 10..position + 10 + size])));
        }
        position += 10 + size;
    }

    (tags, end)
}

/// Decodes the text of one ID3v2 text frame. Its first byte says which encoding the rest is in.
pub fn decode_frame_text(payload: &[u8]) -> String {
    if payload.is_empty() {
        return String::new();
    }

    let text = &payload[1..];
    let decoded = match payload[0] {
        // ISO-8859-1: every byte is the code point with the same number.
        0 => text.iter().map(|byte| char::from(*byte)).collect(),
        1 => decode_utf16(text, false),
        2 => decode_utf16(text, true),
        3 => String::from_utf8_lossy(text).to_string(),
        _ => String::new(),
    };

    decoded.trim_matches('\0').to_string()
}

/// Reads code units. `assume_big_endian` is the ID3v2.4 encoding that has no mark; for the one
/// with a mark, the first unit decides the order.
pub fn decode_utf16(text: &[u8], assume_big_endian: bool) -> String {
    let mut big_endian = assume_big_endian;
    let mut position = 0;
    if !assume_big_endian && text.len() >= 2 {
        match u16::from_be_bytes([text[0], text[1]]) {
            // The mark is read the way it is written, so the pairs after it are big-endian too.
            0xFEFF => {
                big_endian = true;
                position = 2;
            }
            // The mark only makes sense read the other way, so the pairs are little-endian.
            0xFFFE => {
                big_endian = false;
                position = 2;
            }
            _ => {}
        }
    }

    let mut units: Vec<u16> = Vec::with_capacity((text.len() - position) / 2);
    while position + 1 < text.len() {
        units.push(if big_endian {
            u16::from_be_bytes([text[position], text[position + 1]])
        } else {
            u16::from_le_bytes([text[position], text[position + 1]])
        });
        position += 2;
    }

    String::from_utf16_lossy(&units)
}

/// Reads the 4-byte ID3v2 size, where every byte carries 7 bits.
pub fn synchsafe(bytes: &[u8]) -> usize {
    let mut value = 0usize;
    for byte in bytes {
        value = (value << 7) | (byte & 0x7f) as usize;
    }
    value
}

/// How long an MP3 plays. The first frame header gives the bitrate and the sample rate; with
/// them the number of frames follows from the audio bytes — exactly when the file carries a
/// Xing/Info header with its frame count (variable bitrate), otherwise as an estimate for
/// constant bitrate, which is what a plain frame scan would confirm.
pub fn mp3_duration_ms(data: &[u8], audio_start: usize) -> i64 {
    // A trailing ID3v1 tag is 128 bytes at the end and is not audio, so the count must not read
    // it as frames.
    let mut end = data.len();
    if end.saturating_sub(audio_start) >= 128 && &data[end - 128..end - 125] == b"TAG" {
        end -= 128;
    }
    if end.saturating_sub(audio_start) < 4 {
        return 0;
    }

    // The first sync marker. Bytes between the tag and the first frame are not part of the frame
    // chain, so they are skipped.
    let mut head = 0u32;
    let mut position = audio_start;
    while position + 4 <= end {
        head = u32::from_be_bytes([data[position], data[position + 1], data[position + 2], data[position + 3]]);
        if head & 0xFFE0_0000 == 0xFFE0_0000 {
            break;
        }
        position += 1;
    }
    if position + 4 > end {
        return 0;
    }

    // The header bits, in the order the standard lays them out: sync, version, layer, protection,
    // bitrate index, sample rate index, padding.
    let version = ((head >> 19) & 3) as usize;
    let layer = ((head >> 17) & 3) as usize;
    let bitrate_index = ((head >> 12) & 0xF) as usize;
    let sample_index = ((head >> 10) & 3) as usize;
    let padding = ((head >> 9) & 1) as usize;

    if layer != 1 {
        return 0; // only Layer III is read, see the bitrate table
    }

    let bitrate = mp3_bitrate_kbps(version, bitrate_index);
    let sample_rate = mp3_sample_rate(version, sample_index);
    let samples_per_frame = mp3_samples_per_frame(version);
    if bitrate == 0 || sample_rate == 0 || samples_per_frame == 0 {
        return 0;
    }

    let frame_bytes = mp3_frame_bytes(version, bitrate, sample_rate, padding);
    if frame_bytes < 4 || position + frame_bytes > end {
        return 0;
    }

    // A variable bitrate file is only measured exactly when the file carries its frame count where
    // this reads it — at the start of the frame data. A file that puts the magic further inside the
    // side information is not recognised here, so it gets the constant-bitrate estimate. That is
    // what the Go version did, so searching wider here would answer a different length for the same
    // file than the version this replaced.
    let frames = match xing_frame_count(&data[position + 4..position + frame_bytes]) {
        Some(frames) => frames,
        None => (end - position) / frame_bytes,
    };

    frames as i64 * samples_per_frame as i64 * 1000 / sample_rate as i64
}

/// The frame count of a Xing or Info header. The header sits at the start of the frame data, so
/// only that part is looked at: bytes further in that happen to spell "Xing" are audio, not a
/// header.
pub fn xing_frame_count(frame: &[u8]) -> Option<usize> {
    if frame.len() < 12 || (frame[..4] != *b"Xing" && frame[..4] != *b"Info") {
        return None;
    }
    if u32::from_be_bytes([frame[4], frame[5], frame[6], frame[7]]) & 1 == 0 {
        return None; // this header carries no frame count
    }
    Some(u32::from_be_bytes([frame[8], frame[9], frame[10], frame[11]]) as usize)
}

/// Bitrate index to kbps, for MPEG Audio Layer III — the layer an MP3 is. Layers I and II have
/// their own ladders and are not read here, so a file that turns out to be one of them keeps no
/// duration and the client shows a dash. Version 1 is a reserved value and has no table; index 15
/// is a bad value.
const MP3_BITRATE_KBPS: [[usize; 16]; 4] = [
    [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0], // version 0: MPEG 2.5
    [0; 16],                                                             // version 1: reserved
    [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0], // version 2: MPEG 2
    [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0], // version 3: MPEG 1
];

/// Sample rate index to Hz, per version. Index 3 is a reserved value.
const MP3_SAMPLE_RATE: [[usize; 4]; 4] = [
    [11025, 12000, 8000, 0],
    [0; 4],
    [22050, 24000, 16000, 0],
    [44100, 48000, 32000, 0],
];

fn mp3_bitrate_kbps(version: usize, index: usize) -> usize {
    if version > 3 || index > 15 {
        return 0;
    }
    MP3_BITRATE_KBPS[version][index]
}

fn mp3_sample_rate(version: usize, index: usize) -> usize {
    if version > 3 || index > 3 {
        return 0;
    }
    MP3_SAMPLE_RATE[version][index]
}

/// The samples one Layer III frame carries.
fn mp3_samples_per_frame(version: usize) -> usize {
    match version {
        3 => 1152, // MPEG 1
        0 | 2 => 576, // MPEG 2 and 2.5
        _ => 0,
    }
}

/// The size of one Layer III frame in bytes, so the frames after it can be counted from what is
/// left in the file. A frame of 1152 samples is 144 * bitrate / sample_rate, and the 576-sample
/// frames of MPEG 2 are half of that; the padding bit adds one byte to the frame.
fn mp3_frame_bytes(version: usize, bitrate_kbps: usize, sample_rate: usize, padding: usize) -> usize {
    let slots = if version == 3 { 144 } else { 72 };
    slots * bitrate_kbps * 1000 / sample_rate + padding
}
