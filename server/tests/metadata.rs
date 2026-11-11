// What a file says about itself: the title and artist its tags name and the length its frames
// give. The fixtures are built here by hand, so the expected values are numbers the test states
// on its own rather than what the code under test calculated.

use saphire_server::{metadata, music};

/// The four bytes of an ID3v2 size, where every byte carries 7 bits. Written out here so a test
/// of the reader does not use the reader to build its own fixture.
fn syncsafe_bytes(value: usize) -> [u8; 4] {
    [
        ((value >> 21) & 0x7f) as u8,
        ((value >> 14) & 0x7f) as u8,
        ((value >> 7) & 0x7f) as u8,
        (value & 0x7f) as u8,
    ]
}

/// One text frame payload: the encoding byte, then the text.
fn text_frame(encoding: u8, text: &str) -> Vec<u8> {
    let mut payload = vec![encoding];
    payload.extend_from_slice(text.as_bytes());
    payload
}

/// Builds a tag body and header. The two size formats are the difference between ID3v2.4
/// (syncsafe frame sizes) and ID3v2.3 (plain numbers), which the reader has to tell apart.
fn build_id3_tag(version: u8, frame_sizes_syncsafe: bool, frames: &[(&str, Vec<u8>)]) -> Vec<u8> {
    let mut body = Vec::new();
    for (id, payload) in frames {
        // A frame size is four bytes either way; only the encoding of the number differs.
        let size: [u8; 4] = if frame_sizes_syncsafe {
            syncsafe_bytes(payload.len())
        } else {
            (payload.len() as u32).to_be_bytes()
        };

        body.extend_from_slice(id.as_bytes());
        body.extend_from_slice(&size);
        body.extend_from_slice(&[0, 0]); // frame flags
        body.extend_from_slice(payload);
    }

    let mut tag = vec![b'I', b'D', b'3', version, 0, 0];
    tag.extend_from_slice(&syncsafe_bytes(body.len()));
    tag.extend_from_slice(&body);
    tag
}

/// The four header bytes of one MPEG audio frame, with the fields in the order the standard lays
/// them out.
fn mp3_frame_header(version: u32, layer: u32, bitrate_index: u32, sample_index: u32, padding: u32) -> [u8; 4] {
    let mut head: u32 = 0xFFE0_0000;
    head |= version << 19;
    head |= layer << 17;
    head |= 1 << 16; // no CRC
    head |= bitrate_index << 12;
    head |= sample_index << 10;
    head |= padding << 9;
    head.to_be_bytes()
}

// MPEG 1, Layer III, bitrate index 9 = 128 kbps, sample index 2 = 32000 Hz. These numbers come
// out whole, so the tests can state them without rounding: a frame is 144 * 128000 / 32000 = 576
// bytes and 1152 / 32000 s = 36 ms long.
fn frame_128k() -> [u8; 4] {
    mp3_frame_header(3, 1, 9, 2, 0)
}

/// Builds n whole frames of audio.
fn audio_of(count: usize) -> Vec<u8> {
    let mut data = Vec::new();
    for _ in 0..count {
        data.extend_from_slice(&frame_128k());
        data.extend_from_slice(&[0u8; 572]);
    }
    data
}

#[test]
fn read_audio_meta_reads_the_tags_and_the_duration() {
    let mut file = build_id3_tag(
        3,
        false,
        &[("TIT2", text_frame(0, "Neutrone (Remix)")), ("TPE1", text_frame(0, "Kraftwerk"))],
    );
    file.extend_from_slice(&audio_of(10));

    let meta = metadata::read_audio_meta(&file);
    assert_eq!(meta.title, "Neutrone (Remix)", "the TIT2 frame was not read: {meta:?}");
    assert_eq!(meta.artist, "Kraftwerk", "the TPE1 frame was not read: {meta:?}");

    // 10 frames of 1152 samples at 32000 Hz is 360 ms.
    assert_eq!(meta.duration_ms, 10 * 1152 * 1000 / 32000, "the duration is not the frames the file has");
}

#[test]
fn read_audio_meta_without_tags_still_counts_the_frames() {
    let meta = metadata::read_audio_meta(&audio_of(10));

    assert_eq!(meta.title, "", "a file with no tag must not report one: {meta:?}");
    assert_eq!(meta.artist, "", "a file with no tag must not report one: {meta:?}");

    // The title an untagged file gets comes from the name the client sent, so the answer here is
    // only what the file itself says: nothing, but still a measurable length.
    assert_eq!(meta.duration_ms, 360, "the frames were not counted");
}

// The padding bit is the bit after the sample rate index. A frame that has it set is one byte
// longer, so a reader that takes the wrong bit gets a different frame size — or, because it reads
// the bit as part of the sample rate index, no frame at all.
#[test]
fn read_audio_meta_counts_padded_frames() {
    let padded = mp3_frame_header(3, 1, 9, 2, 1);

    // The fixture has to be long enough for the difference to show: with ten frames both readings
    // give the same count, because floor(5770 / 577) and floor(5770 / 576) are both 10. At 600
    // frames a reader that drops the padding bit counts 601 and answers a different length.
    let mut file = Vec::new();
    for _ in 0..600 {
        file.extend_from_slice(&padded);
        file.extend_from_slice(&[0u8; 573]);
    }
    assert_eq!(metadata::read_audio_meta(&file).duration_ms, 600 * 1152 * 1000 / 32000, "the padding bit was not read");

    // The same numbers for a frame of MPEG 2, which carries 576 samples and half the bytes:
    // 72 * 64000 / 16000 = 288 bytes, 576 / 16000 s = 36 ms. Bitrate index 8 of the MPEG 2
    // ladder = 64 kbps, sample index 2 = 16000 Hz. A wrong version reads 576 bytes per frame and
    // counts half as many, so this half does not need a longer file.
    let mpeg2 = mp3_frame_header(2, 1, 8, 2, 0);

    let mut half = Vec::new();
    for _ in 0..10 {
        half.extend_from_slice(&mpeg2);
        half.extend_from_slice(&[0u8; 284]);
    }
    assert_eq!(metadata::read_audio_meta(&half).duration_ms, 360, "ten MPEG 2 frames are 360 ms");
}

// A variable bitrate file cannot be measured by bytes per frame, so its Xing header is the only
// source of a frame count. The file here holds 50 frames while its header claims 100, so the two
// answers differ and the test can tell which one the reader used.
#[test]
fn read_audio_meta_uses_the_xing_frame_count() {
    let mut frame = frame_128k().to_vec();
    frame.extend_from_slice(b"Xing");
    frame.extend_from_slice(&[0, 0, 0, 1]); // flags: the frame count is present
    frame.extend_from_slice(&100u32.to_be_bytes());
    frame.extend_from_slice(&[0u8; 560]); // the rest of the 576-byte frame

    // Only the start of the frame data is a header; the rest of a frame is audio.
    assert_eq!(metadata::xing_frame_count(&frame[4..]), Some(100), "the Xing header itself was not read");

    let mut file = build_id3_tag(4, true, &[]);
    file.extend_from_slice(&frame);
    file.extend_from_slice(&audio_of(49));

    // 100 frames of 1152 samples at 32000 Hz is 3600 ms, not the 1800 the bytes alone would give.
    assert_eq!(metadata::read_audio_meta(&file).duration_ms, 100 * 1152 * 1000 / 32000, "the frame count was not used");
}

// A trailing ID3v1 tag is 128 bytes that are not audio. Here the audio leaves a remainder of 449
// bytes, which is more than the tag is long, so counting it as audio would add a frame and change
// the answer.
#[test]
fn read_audio_meta_does_not_count_a_trailing_id3v1_tag() {
    let mut file = audio_of(10);
    file.extend_from_slice(&[0u8; 449]);
    file.extend_from_slice(b"TAG");
    file.extend_from_slice(&[0u8; 125]);

    assert_eq!(metadata::read_audio_meta(&file).duration_ms, 360, "the trailing tag was counted as audio");
}

#[test]
fn read_audio_meta_decodes_the_text_encodings() {
    // UTF-16 with a byte order mark, the encoding most tagged files use. Both orders spell the
    // same two letters here, so the test shows which one the reader chose.
    let mut big_endian = build_id3_tag(4, true, &[("TPE1", vec![1u8, 0xFE, 0xFF, 0x00, b'K', 0x00, b'r'])]);
    big_endian.extend_from_slice(&audio_of(1));
    let meta = metadata::read_audio_meta(&big_endian);
    assert_eq!(meta.artist, "Kr", "UTF-16 read big-endian decoded wrong: {meta:?}");

    let mut little_endian = build_id3_tag(4, true, &[("TPE1", vec![1u8, 0xFF, 0xFE, b'K', 0, b'r', 0])]);
    little_endian.extend_from_slice(&audio_of(1));
    let meta = metadata::read_audio_meta(&little_endian);
    assert_eq!(meta.artist, "Kr", "UTF-16 read little-endian decoded wrong: {meta:?}");

    // A frame that claims more than the tag has is not read, and nothing crashes.
    let mut broken = build_id3_tag(4, true, &[]);
    broken.extend_from_slice(b"TIT2");
    broken.extend_from_slice(&syncsafe_bytes(100)); // larger than the tag
    broken.extend_from_slice(&[0, 0]);
    broken.extend_from_slice(&text_frame(3, "zu lang"));
    broken.extend_from_slice(&audio_of(1));

    assert_eq!(metadata::read_audio_meta(&broken).title, "", "a frame outside the tag was read");
}

// Only MPEG Audio Layer III is read, so a file of another layer has no length here.
#[test]
fn read_audio_meta_ignores_other_layers() {
    // The file has to be long enough for the layer check to be what decides the answer: these
    // header values would mean a Layer III frame of 144 * 96000 / 32000 = 432 bytes, so a reader
    // without the layer check would count one frame and answer 36 ms. A shorter file would return
    // 0 for the wrong reason — a frame that does not fit.
    let mut layer_ii = mp3_frame_header(3, 2, 7, 2, 0).to_vec();
    layer_ii.extend_from_slice(&[0u8; 432]);

    assert_eq!(metadata::read_audio_meta(&layer_ii).duration_ms, 0, "a Layer II frame gave a duration");
}

// A tag that is not audio, or audio with no header, has nothing to read.
#[test]
fn read_audio_meta_answers_nothing_for_empty_or_tag_only() {
    assert_eq!(metadata::read_audio_meta(&build_id3_tag(4, true, &[])).duration_ms, 0, "a tag with no audio has no duration");

    // A header with nothing after it cannot be measured, even though it is a frame.
    let mut empty = vec![b'I', b'D', b'3', 4, 0, 0];
    empty.extend_from_slice(&syncsafe_bytes(0));
    assert_eq!(metadata::read_audio_meta(&empty).duration_ms, 0, "no audio has no duration");

    // Junk that is not a sync marker is skipped until nothing is left.
    assert_eq!(metadata::read_audio_meta(&[1, 2, 3, 4, 5, 6, 7, 8]).duration_ms, 0, "no audio has no duration");

    // The extended header flag must not read past the end of a short file.
    let mut short = vec![b'I', b'D', b'3', 4, 0, 0x40];
    short.extend_from_slice(&syncsafe_bytes(0));
    short.extend_from_slice(&audio_of(1));
    assert_eq!(metadata::read_audio_meta(&short).artist, "", "a file with an extended header read a tag");
}

// The same cap a name has, so a tag cannot be longer than a name the client sent.
#[test]
fn clean_tag_text_strips_control_characters_and_caps_the_length() {
    assert_eq!(metadata::clean_tag_text("a\nb\tc"), "abc", "control characters must be dropped");

    let cleaned = metadata::clean_tag_text(&"x".repeat(music::MAX_TITLE_LEN + 10));
    // The cap counts characters, not bytes, so a multi-byte letter is not cut in half.
    assert_eq!(cleaned.chars().count(), music::MAX_TITLE_LEN, "tag text is longer than the cap a name has");
}
