package main

import "core:slice"
import "core:mem"
import "core:strings"
import stbi "vendor:stb/image"
import "vendor:directx/dxgi"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import nri "libs/NRI-odin"

detexTexture :: struct {
	format          : dxgi.FORMAT,
	data            : []u8,
	width           : int,
	height          : int,
	width_in_blocks : int,
	height_in_blocks: int,
} 

DDS_PIXELFORMAT_FLAGS_ENUM :: enum {
	alphapixels = 0,
	alpha       = 1,
	four_cc     = 2,
	rgb         = 6,
	yuv         = 9,
	luminance   = 17,
}

DDS_PIXELFORMAT_FLAGS :: bit_set[DDS_PIXELFORMAT_FLAGS_ENUM; u32]

DDS_PIXELFORMAT :: struct {
	size         : u32,
	flags        : DDS_PIXELFORMAT_FLAGS,
	four_cc      : [4]u8,
	RBG_bit_count: u32,
	R_bit_mask   : u32,
	G_bit_mask   : u32,
	B_bit_mask   : u32,
	A_bit_mask   : u32,
}

DDS_HEADER_FLAGS_ENUM :: enum u32 {

	caps        = 0,
	height      = 1,
	width       = 2,
	pitch       = 3,
	pixelformat = 12,
	mipmapcount = 17,
	linearsize  = 19,
	depth       = 23,
}

DDS_HEADER_FLAGS :: bit_set[DDS_HEADER_FLAGS_ENUM; u32]

DDS_CAPS_ENUM :: enum {
	complex = 3,
	texture = 12,
	mipmap  = 22,
}

DDS_CAPS :: bit_set[DDS_CAPS_ENUM; u32]

DDS_CAPS2_ENUM :: enum {
	cubemap           = 9,
	cubemap_positivex = 10,
	cubemap_negativex = 11,
	cubemap_positivey = 12,
	cubemap_negativey = 13,
	cubemap_positivez = 14,
	cubemap_negativez = 15,
	volume            = 21,
}

DDS_CAPS2 :: bit_set[DDS_CAPS2_ENUM; u32]

DDS_HEADER :: struct {
	size                : u32,
	flags               : DDS_HEADER_FLAGS,
	height              : u32,
	width               : u32,
	pitch_or_linear_size: u32,
	depth               : u32,
	mipmap_count        : u32,
	reserved_1          : [11]u32,
	pixel_format    : DDS_PIXELFORMAT,
	caps                : DDS_CAPS,
	caps2               : DDS_CAPS2,
	caps3               : u32,
	caps4               : u32,
	reserved_2          : u32,
}

DDS_HEADER_DXT10 :: struct {
	dxgi_format       : dxgi.FORMAT,
	resource_dimension: i32,
	misc_flag         : u32,
	array_size        : u32,
	misc_flags_2      : u32,
}






/* Load texture file (type autodetected from extension) with mipmaps. */
load_texture_file_with_mipmaps :: proc(
    filename: string, 
    max_mipmaps: int, 
	textures_out: ^[dynamic]detexTexture, 
// ) -> (textures_out: []detexTexture, nu_levels_out: int,  ok: bool) {
) -> (nu_levels_out: int,  ok: bool) {
    filename_length := len(filename)
    
	if filename_length > 4 && filepath.ext(filename) == ".ktx" {
		// return detexLoadKTXFileWithMipmaps(filename, max_mipmaps, textures_out, nu_levels_out)
    }
	else if filename_length > 4 && filepath.ext(filename) == ".dds" {
		// return load_DDS_file_with_mipmaps_from_file(filename, max_mipmaps)
    } else {
		texture_out, ok := load_image_file(filename)
		append(textures_out, texture_out)
		// textures_out := []detexTexture{texture_out}
		
		return 1, ok
	}
	return
}

load_DDS_file_with_mipmaps :: proc{
	load_DDS_file_with_mipmaps_from_file, 
	load_DDS_file_with_mipmaps_from_mem,
}

load_DDS_file_with_mipmaps_from_mem :: proc(
	f: []u8, 
    max_mipmaps: int, 
    // textures_out: []^detexTexture,	
) -> (textures_out: []^detexTexture, nu_levels_out: int,  ok: bool) {
	// textures_out := textures_out
	// Read signature.
    if len(f) < 128 || f[0] != 'D' || f[1] != 'D' || f[2] != 'S' || f[3] != ' ' {
		return
    }

	header := (cast(^DDS_HEADER)raw_data(f[4:128]))^

	dxgi_format : dxgi.FORMAT
	if .four_cc in header.pixel_format.flags && 
		header.pixel_format.four_cc[0] == 'D' &&
		header.pixel_format.four_cc[1] == 'X' &&
		header.pixel_format.four_cc[2] == '1' &&
		header.pixel_format.four_cc[3] == '0' 
	{
		header_dx10 := (cast(^DDS_HEADER_DXT10)raw_data(f[132:152]))^
		dxgi_format = header_dx10.dxgi_format
	} else {
		dxgi_format = .BC3_UNORM
		// dxgi_format = .BC3_UNORM_SRGB
	}

	mipmap_count : int = 1
	if int(header.mipmap_count) > max_mipmaps {
		mipmap_count = max_mipmaps
	} else {
		mipmap_count = int(header.mipmap_count)
	}

	textures : []^detexTexture
	block_width := 4
	block_height := 4

	// for i:int ; i<mipmap_count; i+=1 {
	// 	n := 
	// }


	// textures := detexTexture{
	// 	format          = dxgi_format,
	// 	// data            = f[132:],
	// 	data            = raw_data(f[156:]),
	// 	width           = int(header.width),
	// 	height          = int(header.height),
	// 	// width_in_blocks = int,
	// 	// height_in_blocks= int,
	// }

	// text_point := &textures

	// textures_out[0] = text_point

	// textures_out[0].data = raw_data(f[156:])
	// textures_out[0].format = dxgi_format

	// if dds_header.dds_pixel_format.flags
	fmt.printfln("dds header: %v", header)
	
	return textures, mipmap_count, true;
}

// Load texture from DDS file with mip-maps. Returns true if successful.
// nu_levels is a return parameter that returns the number of mipmap levels found.
// textures_out is a return parameter for an array of detexTexture pointers that is allocated,
// free with free(). textures_out[i] are allocated textures corresponding to each level, free
// with free();
load_DDS_file_with_mipmaps_from_file :: proc(
    filename: string, 
    max_mipmaps: int,
) -> (textures_out: []^detexTexture, nu_levels_out: int,  ok: bool) {
    // f, err := os.open(filename)
    f, f_ok := os.read_entire_file(filename)
	// FILE *f = fopen(filename, "rb");
	if (f == nil) {
		// detexSetErrorMessage("detexLoadDDSFileWithMipmaps: Could not open file %s", filename)
		return
	}

	return load_DDS_file_with_mipmaps_from_mem(f, max_mipmaps)
}

load_image_file :: proc(filename: string) -> (texture: detexTexture, ok: bool) {
	width, height, nr_channels : i32

	image := stbi.load(strings.clone_to_cstring(filename), &width, &height, &nr_channels, 4)
	if image == nil {
		fmt.eprintfln("Could not open image: %s. Reason %s", filename, stbi.failure_reason())
		return
	}	

	texture.format          = .R8G8B8A8_UNORM
	texture.width           = int(width)
	texture.height          = int(height)
	texture.width_in_blocks = int(width)
	texture.height_in_blocks= int(height)
	// texture.data            = data
	texture.data            = slice.reinterpret([]u8, image[:width * height * nr_channels])

	// texture_out^ = texture^	

	return texture, true
}

get_subresource :: proc(subresource: ^nri.TextureSubresourceUploadDesc, mip_index: u32, mip: detexTexture, array_index: u32 = 0) {
	
	// mip : ^detexTexture

	row_pitch, slice_pitch : int

	{ // detexComputePitch
		bpp := 4 * 8
		row_pitch = (mip.width * bpp + 7) * 8
		slice_pitch = row_pitch * mip.height

	}

	subresource.slices = raw_data(mip.data)
	subresource.sliceNum = 1
	subresource.rowPitch = u32(row_pitch)
	subresource.slicePitch = u32(slice_pitch)
}

