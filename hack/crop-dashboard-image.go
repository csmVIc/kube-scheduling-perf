package main

import (
	"fmt"
	"image"
	"image/draw"
	"image/png"
	"os"
	"strconv"
)

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}

func main() {
	if len(os.Args) != 7 {
		fail("usage: %s INPUT OUTPUT X Y WIDTH HEIGHT", os.Args[0])
	}

	values := make([]int, 4)
	for i, value := range os.Args[3:] {
		parsed, err := strconv.Atoi(value)
		if err != nil || parsed < 0 {
			fail("invalid crop value %q", value)
		}
		values[i] = parsed
	}
	x, y, width, height := values[0], values[1], values[2], values[3]
	if width == 0 || height == 0 {
		fail("crop width and height must be positive")
	}

	input, err := os.Open(os.Args[1])
	if err != nil {
		fail("open input image: %v", err)
	}
	defer input.Close()

	source, err := png.Decode(input)
	if err != nil {
		fail("decode input image: %v", err)
	}
	crop := image.Rect(x, y, x+width, y+height)
	if !crop.In(source.Bounds()) {
		fail("crop rectangle %v exceeds image bounds %v", crop, source.Bounds())
	}

	result := image.NewRGBA(image.Rect(0, 0, width, height))
	draw.Draw(result, result.Bounds(), source, crop.Min, draw.Src)

	output, err := os.Create(os.Args[2])
	if err != nil {
		fail("create output image: %v", err)
	}
	if err := png.Encode(output, result); err != nil {
		output.Close()
		fail("encode output image: %v", err)
	}
	if err := output.Close(); err != nil {
		fail("close output image: %v", err)
	}
}
