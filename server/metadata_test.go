package main

import (
	"bytes"
	"encoding/binary"
	"strings"
	"testing"
)

// Test fixtures are built here by hand, so the expected values are numbers the test
// states on its own rather than what the code under test calculated.

func synchsafeBytes(n int) []byte {
	return []byte{byte(n >> 21 & 0x7f), byte(n >> 14 & 0x7f), byte(n >> 7 & 0x7f), byte(n & 0x7f)}
}

type testFrame struct {
	id      string
	payload []byte
}

// buildID3Tag builds a tag body and header. frameSizesSyncsafe is the difference
// between ID3v2.4 (syncsafe frame sizes) and ID3v2.3 (plain numbers), which the
// reader has to tell apart.
func buildID3Tag(version int, frameSizesSyncsafe bool, frames []testFrame) []byte {
	var body []byte
	for _, f := range frames {
		if frameSizesSyncsafe {
			body = append(body, []byte(f.id)...)
			body = append(body, synchsafeBytes(len(f.payload))...)
		} else {
			var size [4]byte
			binary.BigEndian.PutUint32(size[:], uint32(len(f.payload)))
			body = append(body, []byte(f.id)...)
			body = append(body, size[:]...)
		}
		body = append(body, 0, 0) // frame flags
		body = append(body, f.payload...)
	}

	tag := []byte{'I', 'D', '3', byte(version), 0, 0}
	tag = append(tag, synchsafeBytes(len(body))...)
	return append(tag, body...)
}

// textFrame is one text frame payload: the encoding byte, then the text.
func textFrame(encoding byte, text string) []byte {
	return append([]byte{encoding}, []byte(text)...)
}

// mp3FrameHeader is the four header bytes of one MPEG audio frame, with the fields in
// the order the standard lays them out.
func mp3FrameHeader(version, layer, bitrateIdx, sampleIdx, padding int) []byte {
	head := uint32(0xFFE00000)
	head |= uint32(version) << 19
	head |= uint32(layer) << 17
	head |= uint32(1) << 16 // no CRC
	head |= uint32(bitrateIdx) << 12
	head |= uint32(sampleIdx) << 10
	head |= uint32(padding) << 9
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], head)
	return b[:]
}

// MPEG 1, Layer III, bitrate index 9 = 128 kbps, sample index 2 = 32000 Hz. These
// numbers come out whole, so the tests can state them without rounding: a frame is
// 144 * 128000 / 32000 = 576 bytes and 1152 / 32000 s = 36 ms long.
var frame128k = mp3FrameHeader(3, 1, 9, 2, 0)

// audioOf builds n whole frames of audio.
func audioOf(n int) []byte {
	var data []byte
	for i := 0; i < n; i++ {
		data = append(data, frame128k...)
		data = append(data, bytes.Repeat([]byte{0}, 572)...)
	}
	return data
}

// taggedMP3 is a whole MP3 an upload can send: an ID3v2.3 tag with title and
// artist, and ten frames of audio.
func taggedMP3() []byte {
	tag := buildID3Tag(3, false, []testFrame{
		{"TIT2", textFrame(0, "Neutrone (Remix)")},
		{"TPE1", textFrame(0, "Kraftwerk")},
	})
	return append(tag, audioOf(10)...)
}

func TestReadAudioMetaReadsTagsAndDuration(t *testing.T) {
	tag := buildID3Tag(3, false, []testFrame{
		{"TIT2", textFrame(0, "Neutrone (Remix)")},
		{"TPE1", textFrame(0, "Kraftwerk")},
	})

	meta := readAudioMeta(append(tag, audioOf(10)...))
	if meta.Title != "Neutrone (Remix)" || meta.Artist != "Kraftwerk" {
		t.Errorf("tags were not read: %+v", meta)
	}

	// 10 frames of 1152 samples at 32000 Hz is 360 ms.
	if meta.DurationMS != 10*1152000/32000 {
		t.Errorf("duration is %d ms, wanted %d", meta.DurationMS, 10*1152000/32000)
	}
}

func TestReadAudioMetaWithoutTagsStillCountsFrames(t *testing.T) {
	meta := readAudioMeta(audioOf(10))
	if meta.Title != "" || meta.Artist != "" {
		t.Errorf("a file with no tag must not report one: %+v", meta)
	}
	if meta.DurationMS != 360 {
		t.Errorf("duration is %d ms, wanted 360", meta.DurationMS)
	}
}

// The padding bit is the bit after the sample rate index. A frame that has it set is
// one byte longer, so a reader that takes the wrong bit gets a different frame size —
// or, because it reads the bit as part of the sample rate index, no frame at all.
func TestReadAudioMetaCountsPaddedFrames(t *testing.T) {
	padded := mp3FrameHeader(3, 1, 9, 2, 1)

	var file []byte
	for i := 0; i < 10; i++ {
		file = append(file, padded...)
		file = append(file, bytes.Repeat([]byte{0}, 573)...)
	}

	if got := readAudioMeta(file).DurationMS; got != 360 {
		t.Errorf("duration is %d ms, wanted 360 for ten 577-byte frames", got)
	}

	// The same numbers for a frame of MPEG 2, which carries 576 samples and half the
	// bytes: 72 * 64000 / 16000 = 288 bytes, 576 / 16000 s = 36 ms.
	// Bitrate index 8 of the MPEG 2 ladder = 64 kbps, sample index 2 = 16000 Hz.
	mpeg2 := mp3FrameHeader(2, 1, 8, 2, 0)
	var half []byte
	for i := 0; i < 10; i++ {
		half = append(half, mpeg2...)
		half = append(half, bytes.Repeat([]byte{0}, 284)...)
	}
	if got := readAudioMeta(half).DurationMS; got != 360 {
		t.Errorf("MPEG 2 duration is %d ms, wanted 360", got)
	}
}

// A variable bitrate file cannot be measured by bytes per frame, so its Xing header is
// the only source of a frame count. The file here holds 50 frames while its header
// claims 100, so the two answers differ.
func TestReadAudioMetaUsesXingFrameCount(t *testing.T) {
	frame := append(frame128k, []byte("Xing")...)
	frame = append(frame, 0, 0, 0, 1) // flags: the frame count is present
	var frames [4]byte
	binary.BigEndian.PutUint32(frames[:], 100)
	frame = append(frame, frames[:]...)
	frame = append(frame, bytes.Repeat([]byte{0}, 576-16)...)

	audio := append(frame, audioOf(49)...)
	meta := readAudioMeta(append(buildID3Tag(4, true, nil), audio...))

	want := int64(100) * 1152000 / 32000 // 3600 ms, not the 1800 the bytes would give
	if meta.DurationMS != want {
		t.Errorf("duration is %d ms, wanted %d", meta.DurationMS, want)
	}
}

// A trailing ID3v1 tag is 128 bytes that are not audio. Here the audio leaves a
// remainder of 449 bytes, which is more than the tag is long, so counting it as audio
// would add a frame and change the answer.
func TestReadAudioMetaDoesNotCountTrailingID3v1(t *testing.T) {
	audio := append(audioOf(10), bytes.Repeat([]byte{0}, 449)...)
	file := append(audio, append([]byte("TAG"), bytes.Repeat([]byte{0}, 125)...)...)

	if got := readAudioMeta(file).DurationMS; got != 360 {
		t.Errorf("duration is %d ms, wanted 360 (the trailing tag must not be counted)", got)
	}
}

func TestReadAudioMetaDecodesEncodings(t *testing.T) {
	// UTF-16 with a byte order mark, the encoding most tagged files use. Both orders
	// spell the same two letters here, so the test shows which one the reader chose.
	bigEndian := append([]byte{1}, []byte{0xFE, 0xFF, 0x00, 'K', 0x00, 'r'}...)
	meta := readAudioMeta(append(buildID3Tag(4, true, []testFrame{{"TPE1", bigEndian}}), audioOf(1)...))
	if meta.Artist != "Kr" {
		t.Errorf("UTF-16 read big-endian decoded as %q", meta.Artist)
	}

	littleEndian := append([]byte{1}, []byte{0xFF, 0xFE, 'K', 0x00, 'r', 0x00}...)
	meta = readAudioMeta(append(buildID3Tag(4, true, []testFrame{{"TPE1", littleEndian}}), audioOf(1)...))
	if meta.Artist != "Kr" {
		t.Errorf("UTF-16 read little-endian decoded as %q", meta.Artist)
	}

	// A frame that claims more than the tag has is not read, and nothing crashes.
	broken := append([]byte{'I', 'D', '3', 4, 0, 0}, synchsafeBytes(100)...)
	broken = append(broken, []byte("TIT2")...)
	broken = append(broken, synchsafeBytes(100)...) // larger than the tag
	broken = append(broken, 0, 0)
	broken = append(broken, textFrame(3, "zu lang")...)
	if meta := readAudioMeta(append(broken, audioOf(1)...)); meta.Title != "" {
		t.Errorf("a frame outside the tag was read: %q", meta.Title)
	}
}

// Only MPEG Audio Layer III is read, so a file of another layer has no length here.
func TestReadAudioMetaIgnoresOtherLayers(t *testing.T) {
	layerII := mp3FrameHeader(3, 2, 7, 2, 0)
	if got := readAudioMeta(append(layerII, bytes.Repeat([]byte{0}, 284)...)).DurationMS; got != 0 {
		t.Errorf("a Layer II frame gave %d ms, wanted none", got)
	}
}

// A tag that is not audio, or audio with no header, has nothing to read.
func TestReadAudioMetaOnEmptyAndTagOnly(t *testing.T) {
	if meta := readAudioMeta(buildID3Tag(4, true, nil)); meta.DurationMS != 0 {
		t.Errorf("a tag with no audio should have no duration, got %d", meta.DurationMS)
	}

	// A header with nothing after it cannot be measured, even though it is a frame.
	if meta := readAudioMeta(append([]byte{'I', 'D', '3', 4, 0, 0}, synchsafeBytes(0)...)); meta.DurationMS != 0 {
		t.Errorf("no audio should have no duration, got %d", meta.DurationMS)
	}

	// Junk that is not a sync marker is skipped until nothing is left.
	if meta := readAudioMeta([]byte{1, 2, 3, 4, 5, 6, 7, 8}); meta.DurationMS != 0 {
		t.Errorf("no audio should have no duration, got %d", meta.DurationMS)
	}

	// The extended header flag must not read past the end of a short file.
	short := append([]byte{'I', 'D', '3', 4, 0, 0x40}, synchsafeBytes(0)...)
	if meta := readAudioMeta(append(short, audioOf(1)...)); meta.Artist != "" {
		t.Errorf("a file with an extended header read a tag: %q", meta.Artist)
	}
}

// The same cap a name has, so a tag cannot be longer than a name the client sent.
func TestCleanTagTextCapsAndStrips(t *testing.T) {
	if got := cleanTagText("a\nb\tc"); got != "abc" {
		t.Errorf("control characters must be dropped, got %q", got)
	}
	if got := cleanTagText(strings.Repeat("x", maxTitleLen+10)); len(got) != maxTitleLen {
		t.Errorf("tag text is %d characters long, the cap is %d", len(got), maxTitleLen)
	}
}
