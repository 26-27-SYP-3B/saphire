package main

import (
	"encoding/binary"
	"strings"
	"unicode/utf16"
)

// audioMeta is what an uploaded file says about itself: the title and the artist
// its tags name, and how long it plays. A file that does not say something stays
// empty or zero, so the library shows a dash instead of a guess.
//
// Only MP3 is read here, because that is the format whose length can be worked
// out from the bytes alone (frame headers). The other accepted containers would
// need their own container parser, so they keep no duration.
// It is not answered as itself; the values are read into the Track, which is the
// shape api-docs.md documents.
type audioMeta struct {
	Title      string
	Artist     string
	DurationMS int64
}

// readAudioMeta reads an MP3. Tags are what the file has; without them the
// strings are empty and the caller falls back to the name the client sent.
func readAudioMeta(data []byte) audioMeta {
	tags, audioStart := readID3v2(data)
	return audioMeta{
		Title:      tags["TIT2"],
		Artist:     tags["TPE1"],
		DurationMS: mp3DurationMS(data, audioStart),
	}
}

// cleanTagText makes text that came out of a file safe to show: no control
// characters, at most maxTitleLen characters. This is the same rule the uploaded
// name goes through, so a tag cannot be longer than a name.
func cleanTagText(text string) string {
	var b strings.Builder
	count := 0
	for _, r := range text {
		if r < 0x20 || r == 0x7f {
			continue
		}
		if count >= maxTitleLen {
			break
		}
		b.WriteRune(r)
		count++
	}
	return strings.TrimSpace(b.String())
}

// readID3v2 returns the text frames of an ID3v2 tag and where the audio data
// begins. A file with no tag gives an empty map and offset 0.
func readID3v2(data []byte) (map[string]string, int) {
	tags := map[string]string{}
	if len(data) < 10 || string(data[:3]) != "ID3" {
		return tags, 0
	}

	// The header is "ID3", then version, revision, flags, then a syncsafe size.
	version := data[3]
	flags := data[5]
	tagSize := synchsafe(data[6:10])
	if tagSize > len(data)-10 {
		tagSize = len(data) - 10 // a tag that claims more than the file has
	}
	end := 10 + tagSize

	if version < 3 {
		// ID3v2.2 frames have a different header shape, so a v2.2 tag is left
		// unread; the audio still starts after it.
		return tags, end
	}

	if flags&0x40 != 0 {
		// An extended header is rare, and its size field counts itself in ID3v2.4 but
		// not in ID3v2.3, so a file with one is left unread rather than read from the
		// wrong offset. The audio still starts after the whole tag.
		return tags, end
	}

	for i := 10; i+10 <= end; {
		id := string(data[i : i+4])
		if id[0] == 0 {
			break // the rest of the tag is padding
		}

		// v2.3 stores the frame size as a plain number, v2.4 as a syncsafe one.
		size := int(binary.BigEndian.Uint32(data[i+4 : i+8]))
		if version >= 4 {
			size = synchsafe(data[i+4 : i+8])
		}
		if size <= 0 || i+10+size > end {
			break // a frame that does not fit in the tag cannot be read
		}

		if id == "TIT2" || id == "TPE1" {
			tags[id] = cleanTagText(decodeFrameText(data[i+10 : i+10+size]))
		}
		i += 10 + size
	}

	return tags, end
}

// decodeFrameText decodes the text of one ID3v2 text frame. Its first byte says
// which encoding the rest is in.
func decodeFrameText(payload []byte) string {
	if len(payload) == 0 {
		return ""
	}

	text := payload[1:]
	switch payload[0] {
	case 0:
		// ISO-8859-1: every byte is the code point with the same number.
		var b strings.Builder
		for _, r := range text {
			b.WriteRune(rune(r))
		}
		return strings.Trim(b.String(), "\x00")
	case 1:
		return strings.Trim(decodeUTF16(text, false), "\x00")
	case 2:
		return strings.Trim(decodeUTF16(text, true), "\x00")
	case 3:
		return strings.Trim(string(text), "\x00")
	default:
		return ""
	}
}

// decodeUTF16 reads code units. assumeBigEndian is the ID3v2.4 encoding that has
// no mark; for the one with a mark the first unit decides the order.
func decodeUTF16(text []byte, assumeBigEndian bool) string {
	bigEndian := assumeBigEndian
	if !assumeBigEndian && len(text) >= 2 {
		switch binary.BigEndian.Uint16(text[:2]) {
		case 0xFEFF:
			// The mark is read the way it is written, so the pairs after it are
			// big-endian too.
			bigEndian = true
			text = text[2:]
		case 0xFFFE:
			// The mark only makes sense read the other way, so the pairs are
			// little-endian.
			bigEndian = false
			text = text[2:]
		}
	}

	units := make([]uint16, 0, len(text)/2)
	for i := 0; i+1 < len(text); i += 2 {
		if bigEndian {
			units = append(units, binary.BigEndian.Uint16(text[i:i+2]))
		} else {
			units = append(units, binary.LittleEndian.Uint16(text[i:i+2]))
		}
	}
	return string(utf16.Decode(units))
}

// synchsafe reads the 4-byte ID3v2 size, where every byte carries 7 bits.
func synchsafe(b []byte) int {
	n := 0
	for _, c := range b {
		n = n<<7 | int(c&0x7f)
	}
	return n
}

// mp3DurationMS works out how long an MP3 plays.
//
// The first frame header gives the bitrate and the sample rate. With them the
// number of frames follows from the audio bytes — exactly when the file carries a
// Xing/Info header with its frame count (variable bitrate), otherwise as an
// estimate for constant bitrate, which is what a plain frame scan would confirm.
func mp3DurationMS(data []byte, audioStart int) int64 {
	// A trailing ID3v1 tag is 128 bytes at the end and is not audio, so the count
	// must not read it as frames.
	end := len(data)
	if end-audioStart >= 128 && string(data[end-128:end-125]) == "TAG" {
		end -= 128
	}
	if end-audioStart < 4 {
		return 0
	}

	// The first sync marker. Bytes between the tag and the first frame are not
	// part of the frame chain, so they are skipped.
	var head uint32
	i := audioStart
	for i+4 <= end {
		head = binary.BigEndian.Uint32(data[i : i+4])
		if head&0xFFE00000 == 0xFFE00000 {
			break
		}
		i++
	}
	if i+4 > end {
		return 0
	}

	// The header bits, in the order the standard lays them out: sync, version,
	// layer, protection, bitrate index, sample rate index, padding.
	version := int((head >> 19) & 3)
	layer := int((head >> 17) & 3)
	bitrateIdx := int((head >> 12) & 0xF)
	sampleIdx := int((head >> 10) & 3)
	padding := int((head >> 9) & 1)

	if layer != 1 {
		return 0 // only Layer III is read, see the bitrate table
	}

	bitrateKbps := mp3BitrateKbps(version, bitrateIdx)
	sampleRate := mp3SampleRate(version, sampleIdx)
	samplesPerFrame := mp3SamplesPerFrame(version)
	if bitrateKbps == 0 || sampleRate == 0 || samplesPerFrame == 0 {
		return 0
	}

	frameBytes := mp3FrameBytes(version, bitrateKbps, sampleRate, padding)
	if frameBytes < 4 || i+frameBytes > end {
		return 0
	}

	// A variable bitrate file only has a length a frame count could not give, so its
	// Xing header is used when the file has one.
	if frames := xingFrameCount(data[i+4 : i+frameBytes]); frames > 0 {
		return int64(frames) * int64(samplesPerFrame) * 1000 / int64(sampleRate)
	}

	// Constant bitrate: the frames that fit in the bytes left, which includes the
	// header we just read.
	frames := int64(end-i) / int64(frameBytes)
	return frames * int64(samplesPerFrame) * 1000 / int64(sampleRate)
}

// xingFrameCount reads the frame count of a Xing or Info header. The header sits at
// the start of the frame data, so only that part is looked at: bytes further in that
// happen to spell "Xing" are audio, not a header.
func xingFrameCount(frame []byte) int {
	if len(frame) < 12 || (string(frame[:4]) != "Xing" && string(frame[:4]) != "Info") {
		return 0
	}
	if binary.BigEndian.Uint32(frame[4:8])&1 == 0 {
		return 0 // this header carries no frame count
	}
	return int(binary.BigEndian.Uint32(frame[8:12]))
}

// Bitrate index to kbps, for MPEG Audio Layer III — the layer an MP3 is. Layers I
// and II have their own ladders and are not read here, so a file that turns out to
// be one of them keeps no duration and the client shows a dash. Version 1 is a
// reserved value and has no table; index 15 is a bad value.
var mp3Bitrates = [4][16]int{
	{0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0}, // version 0: MPEG 2.5
	{}, // version 1: reserved
	{0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0},     // version 2: MPEG 2
	{0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0}, // version 3: MPEG 1
}

// Sample rate index to Hz, per version. Index 3 is a reserved value.
var mp3SampleRates = [4][4]int{
	{11025, 12000, 8000, 0},
	{},
	{22050, 24000, 16000, 0},
	{44100, 48000, 32000, 0},
}

func mp3BitrateKbps(version, index int) int {
	if version < 0 || version > 3 || index < 0 || index > 15 {
		return 0
	}
	return mp3Bitrates[version][index]
}

func mp3SampleRate(version, index int) int {
	if version < 0 || version > 3 || index < 0 || index > 3 {
		return 0
	}
	return mp3SampleRates[version][index]
}

// mp3SamplesPerFrame is the samples one Layer III frame carries.
func mp3SamplesPerFrame(version int) int {
	switch version {
	case 3: // MPEG 1
		return 1152
	case 0, 2: // MPEG 2 and 2.5
		return 576
	}
	return 0
}

// mp3FrameBytes is the size of one Layer III frame in bytes, so the frames after it
// can be counted from what is left in the file. A frame of 1152 samples is
// 144 * bitrate / sample_rate, and the 576-sample frames of MPEG 2 are half of that;
// the padding bit adds one byte to the frame.
func mp3FrameBytes(version, bitrateKbps, sampleRate, padding int) int {
	slots := 144
	if version != 3 {
		slots = 72
	}
	return slots*bitrateKbps*1000/sampleRate + padding
}
