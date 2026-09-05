// H.264: SPS parsing (just what an MP4 sample entry needs), avcC, codec string.
import { BitReader, toRbsp } from './bitreader.ts';

export type H264Sps = {
  profileIdc: number;
  constraintFlags: number;
  levelIdc: number;
  chromaFormatIdc: number;
  bitDepthLumaMinus8: number;
  bitDepthChromaMinus8: number;
  width: number;
  height: number;
};

export function h264NalType(nal: Uint8Array): number {
  return nal[0] & 0x1f;
}

export const H264_NAL_SPS = 7;
export const H264_NAL_PPS = 8;
export const H264_NAL_AUD = 9;
export const H264_NAL_IDR = 5;

const HIGH_PROFILES = new Set([100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]);

function skipScalingList(r: BitReader, size: number): void {
  let last = 8;
  let next = 8;
  for (let j = 0; j < size; j++) {
    if (next !== 0) {
      const delta = r.se();
      next = (last + delta + 256) % 256;
    }
    last = next === 0 ? last : next;
  }
}

// ITU-T H.264 7.3.2.1.1, up to frame_cropping.
export function parseH264Sps(nal: Uint8Array): H264Sps {
  const r = new BitReader(toRbsp(nal, 1));

  const profileIdc = r.u(8);
  const constraintFlags = r.u(8);
  const levelIdc = r.u(8);
  r.ue(); // seq_parameter_set_id

  let chromaFormatIdc = 1;
  let bitDepthLumaMinus8 = 0;
  let bitDepthChromaMinus8 = 0;

  if (HIGH_PROFILES.has(profileIdc)) {
    chromaFormatIdc = r.ue();
    if (chromaFormatIdc === 3) r.skip(1); // separate_colour_plane_flag
    bitDepthLumaMinus8 = r.ue();
    bitDepthChromaMinus8 = r.ue();
    r.skip(1); // qpprime_y_zero_transform_bypass_flag
    if (r.flag()) {
      // seq_scaling_matrix_present_flag
      const lists = chromaFormatIdc !== 3 ? 8 : 12;
      for (let i = 0; i < lists; i++) {
        if (r.flag()) skipScalingList(r, i < 6 ? 16 : 64);
      }
    }
  }

  r.ue(); // log2_max_frame_num_minus4
  const pocType = r.ue();
  if (pocType === 0) {
    r.ue(); // log2_max_pic_order_cnt_lsb_minus4
  } else if (pocType === 1) {
    r.skip(1); // delta_pic_order_always_zero_flag
    r.se(); // offset_for_non_ref_pic
    r.se(); // offset_for_top_to_bottom_field
    const cycles = r.ue();
    for (let i = 0; i < cycles; i++) r.se();
  }
  r.ue(); // max_num_ref_frames
  r.skip(1); // gaps_in_frame_num_value_allowed_flag

  const widthInMbs = r.ue() + 1;
  const heightInMapUnits = r.ue() + 1;
  const frameMbsOnly = r.flag();
  if (!frameMbsOnly) r.skip(1); // mb_adaptive_frame_field_flag
  r.skip(1); // direct_8x8_inference_flag

  let cropLeft = 0;
  let cropRight = 0;
  let cropTop = 0;
  let cropBottom = 0;
  if (r.flag()) {
    cropLeft = r.ue();
    cropRight = r.ue();
    cropTop = r.ue();
    cropBottom = r.ue();
  }

  // crop units (Table 6-1): 4:2:0 -> 2x2, 4:2:2 -> 2x1, else 1x1; times 2
  // vertically for field coding
  const subWidthC = chromaFormatIdc === 1 || chromaFormatIdc === 2 ? 2 : 1;
  const subHeightC = chromaFormatIdc === 1 ? 2 : 1;
  const cropUnitX = chromaFormatIdc === 0 ? 1 : subWidthC;
  const cropUnitY = (chromaFormatIdc === 0 ? 1 : subHeightC) * (frameMbsOnly ? 1 : 2);

  const width = widthInMbs * 16 - (cropLeft + cropRight) * cropUnitX;
  const height = (frameMbsOnly ? 1 : 2) * heightInMapUnits * 16 - (cropTop + cropBottom) * cropUnitY;

  return {
    profileIdc,
    constraintFlags,
    levelIdc,
    chromaFormatIdc,
    bitDepthLumaMinus8,
    bitDepthChromaMinus8,
    width,
    height
  };
}

const hex2 = (v: number) => v.toString(16).toUpperCase().padStart(2, '0');

// RFC 6381: avc1.PPCCLL from the SPS profile/constraint/level bytes.
export function h264CodecString(sps: H264Sps): string {
  return `avc1.${hex2(sps.profileIdc)}${hex2(sps.constraintFlags)}${hex2(sps.levelIdc)}`;
}

// ISO/IEC 14496-15 5.3.3.1.2 AVCDecoderConfigurationRecord.
export function buildAvcC(sps: H264Sps, spsNal: Uint8Array, ppsNal: Uint8Array): Uint8Array {
  const parts: number[] = [
    1,
    sps.profileIdc,
    sps.constraintFlags,
    sps.levelIdc,
    0xff, // reserved 111111 + lengthSizeMinusOne = 3
    0xe1, // reserved 111 + numOfSequenceParameterSets = 1
    spsNal.length >> 8,
    spsNal.length & 0xff,
    ...spsNal,
    1, // numOfPictureParameterSets
    ppsNal.length >> 8,
    ppsNal.length & 0xff,
    ...ppsNal
  ];

  if (HIGH_PROFILES.has(sps.profileIdc)) {
    parts.push(
      0xfc | sps.chromaFormatIdc,
      0xf8 | sps.bitDepthLumaMinus8,
      0xf8 | sps.bitDepthChromaMinus8,
      0 // numOfSequenceParameterSetExt
    );
  }

  return Uint8Array.from(parts);
}
