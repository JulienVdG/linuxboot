#!/usr/bin/perl
# Parse GUIDs, generate EFI structs, etc

package EFI;
use warnings;
use strict;
use File::Temp 'tempfile';
use Digest::SHA 'sha1';
#use IO::Compress::Lzma 'lzma';  # apt install libio-compress-lzma-perl
#use Compress::Raw::Lzma;  # apt install libcompress-raw-lzma-perl


# Address Size  Designation
# ------- ----  -----------
# 
# EFI_FFS_FILE_HEADER:
# 0x0000  16    Name (EFI_GUID)
# 0x0010  1     IntegrityCheck.Header (Header Checksum)
# 0x0011  1     IntegrityCheck.File -> set to 0xAA (FFS_FIXED_CHECKSUM) and clear bit 0x40 of Attributes
# 0x0012  1     FileType -> 0x07 = EFI_FV_FILETYPE_DRIVER
# 0x0013  1     Attributes -> 0x00
# 0x0014  3     Size, including header and all other sections
# 0x0017  1     State (unused) -> 0X00
# 
# EFI_COMMON_SECTION_HEADER:
# 0x0000  3     Size, including this header
# 0x0003  1     Type -> 0x10 (EFI_SECTION_PE32)
# 0x0004  ####  <PE data>
# 
# EFI_COMMON_SECTION_HEADER:
# 0x0000  3     Size, including this header
# 0x0003  1     Type -> 0x15 (EFI_SECTION_USER_INTERFACE)
# 0x0004  ####  NUL terminated UTF-16 string (eg "FAT\0")
# 
# EFI_COMMON_SECTION_HEADER:
# 0x0000  3     Size, including this header
# 0x0003  1     Type -> 0x14 (EFI_SECTION_VERSION)
# 0x0004  ####  NUL terminated UTF-16 string (eg "1.0\0")

my $sec_hdr_len = 0x04; # FFSv2 sections
my $ffs_hdr_len = 0x18; # FFSv2
#my $sec_hdr_len = 0x08; # FFSv3 sections include a 32-bit length
#my $ffs_hdr_len = 0x20; # FFSv3 files include a 64-bit length

my $fv_hdr_len = 0x48;
my $fv_block_size = 0x1000; # force alignment of files to this spacing



our %file_types = qw/
	RAW                   0x01
	FREEFORM              0x02
	SECURITY_CORE         0x03
	PEI_CORE              0x04
	DXE_CORE              0x05
	PEIM                  0x06
	DRIVER                0x07
	COMBINED_PEIM_DRIVER  0x08
	APPLICATION           0x09
	SMM                   0x0A
	FIRMWARE_VOLUME_IMAGE 0x0B
	COMBINED_SMM_DXE      0x0C
	SMM_CORE              0x0D
	DEBUG_MIN             0xe0
	DEBUG_MAX             0xef
	FFS_PAD               0xf0
/;


our %section_types = qw/
	TIANO_COMPRESSED      0x01
	GUID_DEFINED          0x02
	PE32                  0x10
	PIC                   0x11
	TE                    0x12
	DXE_DEPEX             0x13
	VERSION               0x14
	USER_INTERFACE        0x15
	COMPATIBILITY16       0x16
	FIRMWARE_VOLUME_IMAGE 0x17
	FREEFORM_SUBTYPE_GUID 0x18
	RAW                   0x19
	PEI_DEPEX             0x1B
	SMM_DEPEX             0x1C
/;


# Some special cases for non-PE32 sections
our %section_type_map = qw/
	FREEFORM		RAW
	FIRMWARE_VOLUME_IMAGE	FIRMWARE_VOLUME_IMAGE
/;

# Special cases for DEPEX sections
our %depex_type_map = qw/
	PEIM			PEI_DEPEX
	DRIVER			DXE_DEPEX
	SMM			SMM_DEPEX
/;

# Invert the file type and section type maps
our %file_types_lookup = map { hex $file_types{$_} => $_ } keys %file_types;
our %section_types_lookup = map { hex $section_types{$_} => $_ } keys %section_types;


sub section_type_lookup
{
	my $type = shift;
	my $name = $section_types_lookup{$type};
	$name ||= sprintf "0x%02x", $type;

	return $name;
}

sub file_type_lookup
{
	my $type = shift;
	my $name = $file_types_lookup{$type};
	$name ||= sprintf "0x%02x", $type;

	return $name;
}

# convert text GUID to hex
sub guid
{
	my $guid = shift;
	my ($g1,$g2,$g3,$g4,$g5) =
		$guid =~ /
			([0-9a-fA-F]{8})
			-([0-9a-fA-F]{4})
			-([0-9a-fA-F]{4})
			-([0-9a-fA-F]{4})
			-([0-9a-fA-F]{12})
		/x
		or die "$guid: Unable to parse guid\n";

	return pack("VvvnCCCCCC",
		hex $g1,
		hex $g2,
		hex $g3,
		hex $g4,
		hex substr($g5, 0, 2),
		hex substr($g5, 2, 2),
		hex substr($g5, 4, 2),
		hex substr($g5, 6, 2),
		hex substr($g5, 8, 2),
		hex substr($g5,10, 2),
	);
}


# Some common GUIDs (these should be in a data file)
our $lzma_guid = 'ee4e5898-3914-4259-9d6e-dc7bd79403cf';


# Convert a string to UCS-16 and add a nul terminator
sub ucs16
{
	my $val = shift;

	my $rc = '';
	for(my $i = 0 ; $i < length $val ; $i++)
	{
		$rc .= substr($val, $i, 1) . chr(0x0);
	}

	# nul terminate the string
	$rc .= chr(0x0) . chr(0x0);

	return $rc;
}

# Convert from UCS-16 back to a normal string
sub read_ucs16
{
	my $val = shift;
	my $offset = shift;
	my $len = length($val);
	my $rc = '';

	while($offset < $len-1)
	{
		my $word = unpack("n", substr($val, $offset, 2));
		last if $word == 0x0000;

		$rc .= chr(($word >> 8) & 0xFF);
		$offset += 2;
	}

	return $rc;
}


# output an EFI Common Section Header
# Since we might be dealing with ones larger than 16 MB, we should use extended
# section type that gives us a 4-byte length.
sub section
{
	my $type = shift;
	my $data = shift;	

	die "$type: Unknown section type\n"
		unless exists $section_types{$type};

	my $len = length($data) + $sec_hdr_len;
	die "Section length $len > 0xFFFFFF\n" if $len > 0xFFFFFF;

	my $sec = ''
		. write24($len)
		. chr(hex $section_types{$type})
		. $data;

	return $sec;
}


sub section_pad
{
	my $len = shift;
	return '' if $len < $sec_hdr_len;

	return section(RAW => chr(0x00) x ($len - $sec_hdr_len));
}

sub ffs_align
{
	my $pad_offset = shift || 0;
	my $pad_align = shift || 0;
	my $align = 4;
	my $data = '';

	for my $sec (@_)
	{
		# sections must be 4 byte aligned,
		my $unaligned = length($data) % $align;
		$data .= chr(0x00) x ($align - $unaligned)
			if $unaligned != 0;

		# if we need more alignment, add a pad section
		if ($pad_align)
		{
			$unaligned = (length($data) + $pad_offset) % $pad_align;
			$unaligned += $pad_align
				if $unaligned < $sec_hdr_len;

			$data .= section_pad($pad_align - $unaligned)
				if $unaligned != 0;
		}

		$data .= $sec;
	}

	return $data;
}


sub ffs
{
	my $file_type = shift;
	my $guid = shift;
	my $data = ffs_align(0, 0, @_);

	# if they did not provide a GUID, generate one
	$guid ||= substr(sha1($data), 0, 16);

	my $len = length($data) + $ffs_hdr_len;

	my $type_byte = $file_types{$file_type}
		or die "$file_type: Unknown file type\n";

	#my $attr = 0x28; # == aligned?
	my $attr = 0x40; # == aligned?
	my $state = 0xF8;
	if ($file_type eq 'FFS_PAD')
	{
		$attr = 0x40;
		$state = 0xF8;
	}

	# since we make everything a large file, set the bit
	#$attr |= 0x01;

	my $ffs = ''
		. $guid			# 0x00
		. chr(0x00)		# 0x10 header checksum
		. chr(0x00)		# 0x11 FFS_FIXED_CHECKSUM
		. chr(hex $type_byte)	# 0x12
		. chr($attr)		# 0x13 attributes
		. write24($len)		# 0x14 length (24-bit)
		. chr($state)		# 0x17 state (not included in checksum)
		# . pack("Q", $len)       # 0x18 64-bit length
		;

	# fixup the header checksum
	my $sum = 0;
	for my $i (0..length($ffs)-2) {
		$sum -= ord(substr($ffs, $i, 1));
	}

	# fixup the data checksum
	my $data_sum = 0x00;
	for my $i (0..length($data))
	{
		$data_sum -= ord(substr($data, $i, 1));
	}

	substr($ffs, 0x10, 2) = chr($sum & 0xFF) . chr($data_sum & 0xFF);

	# Add the rest of the data
	return $ffs . $data;
}


# Generate a padding firmware file
sub ffs_pad
{
	my $len = shift;
	return '' if $len <= $ffs_hdr_len;

	my $ffs = ffs(FFS_PAD =>
		chr(0xFF) x 16, # GUID
		chr(0xFF) x ($len - $ffs_hdr_len), # data
	);

	return $ffs;
}

# Generate a DEPEX section
sub depex
{
	my $type = shift;
	return unless @_;

	my $section_type = $depex_type_map{$type}
		or die "$type: DEPEX is not supported\n";

	if ($_[0] eq 'TRUE')
	{
		# Special case for short-circuit
		return section($section_type, chr(0x06) . chr(0x08));
	}

	my $data = '';
	my $count = 0;

	for my $guid (@_)
	{
		# push the guid
		$data .= chr(0x02) . guid($guid);
		$count++;
	}

	# AND them all together (1 minus the number of GUIDs)
	$data .= chr(0x03) for 1..$count-1;
	$data .= chr(0x08);
	
	return section($section_type, $data);
}


# compress a section and Wrap a GUIDed section around it
sub compress
{
	# We could force 128-byte alignment for compressed sections
	# but it doesn't seem to matter.
	my $data = ffs_align(0, 00, @_);

	my ($fh,$filename) = tempfile();
	print $fh $data;
	close $fh;

	# -7 produces the same bit-stream as the UEFI tools
	#my $lz = new Compress::Raw::Lzma::EasyEncoder(Preset => 7);
	#my $lz_data;
	#$lz->code($data, $lz_data);
	my $lz_data = `lzma --compress --stdout -7 $filename`;
	#printf STDERR "%d compressed to %d\n", length($data), length($lz_data);

	# fixup the size field in the lzma compressed data
	substr($lz_data, 5, 8) = write64(length $data);

	# wrap the lzdata in a GUIDed section
	my $lz_header = ''
		. guid($lzma_guid)
		. chr($ffs_hdr_len)  # data offset, should this be 0x14?
		. chr(0x00)
		. chr(0x01)  # Processing required
		. chr(0x00)
		;

	# and replace our data with the GUID defined LZ compressed data
	return section(GUID_DEFINED => $lz_header . $lz_data);
}


# Create a FV for a given file size with the included files
sub fv
{
	my $size = shift;
	my $guid = guid("8C8CE578-8A3D-4F1C-9935-896185C32DD3");  # FFSv2
	#my $guid = guid("5473c07a-3dcb-4dca-bd6f-1e9689e7349a"); # FFSv3 for large sections

	my $fv_hdr = ''
		. (chr(0x00) x 0x10)		# 0x00 Zero vector
		. $guid				# 0x10
		. write64($size)		# 0x20 length (64-bit)
		. '_FVH'			# 0x28 signature
		. pack("V", 0x000CFEFF)		# 0x2C attributes
		. pack("v", $fv_hdr_len)	# 0x30 header length (32-bit)
		. pack("v", 0x0000)		# 0x32 checksum
		. chr(0x00)			# 0x34 reserved?
		. chr(0x00)			# 0x35 reserved
		. chr(0x00)			# 0x36 reserved
		. chr(0x02)			# 0x37 version
		. pack("V", $size / $fv_block_size) # 0x38 number blocks (32-bit)
		. pack("V", $fv_block_size)	# 0x3C block size (32-bit)
		. pack("V", 0)			# 0x40 number blocks (unused)
		. pack("V", 0)			# 0x44 block size (unused)
		;

	die "FV Header length ", length $fv_hdr, " != $fv_hdr_len\n"
		unless $fv_hdr_len == length $fv_hdr;

	# update the header checksum
	my $sum = 0;
	for(my $i = 0 ; $i < $fv_hdr_len ; $i += 2)
	{
		$sum -= unpack("v", substr($fv_hdr, $i, 2));
	}

	substr($fv_hdr, 0x32, 2) = pack("v", $sum & 0xFFFF);

	for my $ffs (@_)
	{
		next if fv_append(\$fv_hdr, $ffs);

		warn "FV append failed\n";
		return;
	}

	return $fv_hdr if fv_pad(\$fv_hdr);

	warn "FV pad failed\n";
	return;
}


# Append a file to an FV, adding an initial pad if necessary
# This is used internally by EFI::fv() and should not need to be called
# by users of the EFI library.
sub fv_append
{
	my $fv_ref = shift;
	my $ffs = shift;

	# quick sanity check on the file
	my $length = length $ffs;

	my $ffs_length = unpack("V", substr($ffs, 0x14, 4)) & 0xFFFFFF;
	if ($ffs_length == 0xFFFFFF)
	{
		# ffs2 with extended length field
		$ffs_length = unpack("Q", substr($ffs, 0x18, 8));
	}

	# if the size of the file doesn't match the header size
	# we do not want to add it to our output.  signal an error
	return if $ffs_length != $length;

	# force at least 8 byte alignment for the section
	my $unaligned = $length % 8;
	$ffs .= chr(0xFF) x (8 - $unaligned)
		if $unaligned != 0;

	# if the current offset does not align with the block size,
	# we should add a pad section until the next block
	# The firmware files can specify their desired alignment
	# we just force 4KB is they want anything
	my $attr = ord(substr($ffs, 0x13, 1));
	my $alignment = ($attr & 0x38) >> 3;
	if ($alignment == 0)
	{
		$alignment = 0x10;
	} else {
		warn sprintf "alignment attribute %02x\n", $alignment;
		$alignment = 0x1000;
	}

	my $block_unaligned = $alignment - (length($$fv_ref) % $alignment);
	$block_unaligned += $alignment if $block_unaligned < $ffs_hdr_len;

	$$fv_ref .= EFI::ffs_pad($block_unaligned - $ffs_hdr_len);
	my $ffs_offset = length($$fv_ref);

	# Due to a stupid design in edk2's GenFfs, the state field in
	# the FFS will not be set correctly.  We have to flip it if
	# the top bit is not set.  This should depend on the erase
	# polarity bit in the FV header, but no one ever changes it.
	my $state = ord(substr($ffs, 0x17, 1));
	if (($state & 0x80) == 0)
	{
		substr($ffs, 0x17, 1) = chr((~$state) & 0xFF);
	}

	# finally add the section
	$$fv_ref .= $ffs;

	return $ffs_offset;
}

# Finish the FV by padding it to its proper size
sub fv_pad
{
	my $fv_ref = shift;
	my $fv_size = unpack("Q", substr($$fv_ref, 0x20, 8));

	my $size = length($$fv_ref);

	# check for the overflow: if the header size is smaller than the actual size
	return if $fv_size < $size;

	# pad out so that actual size is the same as header size
	$$fv_ref .= chr(0xFF) x ($fv_size - $size);

	return 1;
}


# Helpers for reading values from the ROM images
sub read8
{
	my $data = shift;
	my $offset = shift;
	return unpack("C", substr($data, $offset, 1));
}

sub read16
{
	my $data = shift;
	my $offset = shift;
	return unpack("v", substr($data, $offset, 2));
}

sub write16
{
	my $len = shift;
	return ''
		. chr(($len >>  0) & 0xFF)
		. chr(($len >>  8) & 0xFF)
		;
}

sub read24
{
	my $data = shift;
	my $offset = shift;
	return 0
		| ord(substr($data, $offset+2, 1)) << 16
		| ord(substr($data, $offset+1, 1)) <<  8
		| ord(substr($data, $offset+0, 1)) <<  0
		;
}

sub write24
{
	my $len = shift;
	return ''
		. chr(($len >>  0) & 0xFF)
		. chr(($len >>  8) & 0xFF)
		. chr(($len >> 16) & 0xFF)
		;
}


sub read32
{
	my $data = shift;
	my $offset = shift;
	return unpack("V", substr($data, $offset, 4));
}

sub write32
{
	my $len = shift;
	return ''
		. chr(($len >>  0) & 0xFF)
		. chr(($len >>  8) & 0xFF)
		. chr(($len >> 16) & 0xFF)
		. chr(($len >> 24) & 0xFF)
		;
}

sub read64
{
	my $data = shift;
	my $offset = shift;
	return read32($data, $offset+4) << 32 | read32($data, $offset+0);
}

sub write64
{
	my $data = shift;
	return pack("VV", $data >> 0, $data >> 32);
}


sub read_guid
{
	my $data = shift;
	my $offset = shift;

	my ($g1,$g2,$g3,$g4,@g5) = unpack("VvvnCCCCCC", substr($data, $offset, 16));

	return sprintf "%08x-%04x-%04x-%04x-%02x%02x%02x%02x%02x%02x",
		$g1,
		$g2,
		$g3,
		$g4,
		$g5[0],
		$g5[1],
		$g5[2],
		$g5[3],
		$g5[4],
		$g5[5],
		;
}


#
# Parse the older NVAR (non-volatile variable) structures
#
package EFI::NVRAM::NVAR;

my $nvar_sig			= 0x5241564e; # 'NVAR'
my $nvar_entry_ascii_name	= 0x02;
my $nvar_entry_data_only	= 0x08;
my $nvar_entry_valid		= 0x80;


#
# Create a NVAR object from an in-memory representation
# of the structure.
#
sub parse
{
	my $class = shift;
	my $ffs = shift;
	my $offset = shift || 0;

	my $ffs_len = length($ffs);

	my $sig = EFI::read32($ffs, $offset + 0x00);

	# we've reached the end of the data;
	return if $sig == 0xFFFFFFFF;

	die sprintf "0x%x: sig %08x != nvram %08x\n",
		$offset, $sig, $nvar_sig
		unless $sig eq $nvar_sig;

	my $len = EFI::read16($ffs, $offset + 0x04);

	die sprintf "0x%x: len %x > length %x\n",
		$offset, $len, $ffs_len
		unless $offset + $len <= $ffs_len;

	my $nvar = substr($ffs, $offset, $len);
	my $next = EFI::read24($nvar, 0x06);
	my $attr = EFI::read8($nvar, 0x09);
	my $data = substr($nvar, 0x0a);
	my $name;
	my $guid_id;

	# depending on the attribute we might have a
	# nul terminated string and a guid index in the guidstore
	if ($attr & $nvar_entry_ascii_name)
	{
		$guid_id = EFI::read8($data, 0);
		my $name_end = index($data, chr(0), 1);
		die sprintf "offset 0x%x: ascii name, but no nul\n", $offset
			if $name_end == -1;

		$name = substr($data, 1, $name_end-1);

		# remove the guid and name from the data
		$data = substr($data, $name_end+1);
	}

	my $self = bless {
		nvar	=> $nvar,
		offset	=> $offset,
		attr	=> $attr,
		name	=> $name,
		guid	=> $guid_id,
		next	=> $next,
		data	=> $data,
	}, $class;

	return $self;
}


#
# Serialize an NVRAM NVAR structure
#
sub output
{
	my $self = shift;

	my $data = $self->{data};
	my $attr = $self->{attr};
	my $name = $self->{name};
	if ($name)
	{
		# update the attribute that we have name
		$attr |=  $nvar_entry_ascii_name;
		$attr &= ~$nvar_entry_data_only;
		$data = chr($self->{guid}) . $self->{name} . chr(0x00) . $data;
	}

	return ''
		. EFI::write32($nvar_sig)		# 0x00
		. EFI::write16(length($data) + 0x0A)	# 0x04
		. EFI::write24(0xFFFFFF) # no next	# 0x06
		. chr($attr)				# 0x09
		. $data;				# 0x0A
}


sub length
{
	my $self = shift;
	return length $self->{nvar};
}


sub valid
{
	my $self = shift;
	return $self->{attr} & $nvar_entry_valid;
}


sub next
{
	my $self = shift;
	# all F is no next, since that can be inverted in the flash
	return if $self->{next} eq 0xFFFFFF;

	# the next pointer is relative to the offset of this one,
	# so shift it by the amount that we've advanced
	return $self->{next} + $self->{offset};
}

sub name { my $self = shift; return $self->{name}; }
sub guid { my $self = shift; return $self->{guid}; }
sub data { my $self = shift; return $self->{data}; }


"0, but true";
__END__
