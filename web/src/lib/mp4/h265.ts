// H.265: SPS parsing (profile_tier_level + geometry), hvcC, codec string.
import { BitReader, toRbsp } from './bitreader.ts';

export type H265Sps = {
  profileSpace: number;
  tierFlag: number;
  profileIdc: number;
  compatibilityFlags: number; // general_profile_compatibility_flag[0..31], bit j = flag j
  constraintBytes: Uint8Array; // the 6 general_constraint_indicator bytes
  levelIdc: number;
  maxSubLayersMinus1: number;
  temporalIdNesting: boolean;
  chromaFormatIdc: number;
  bitDepthLumaMinus8: number;
  bitDepthChromaMinus8: number;
  width: number;
  height: number;
};

export function h265NalType(nal: Uint8Array): number {
  return (nal[0] >> 1) & 0x3f;
}

export const H265_NAL_VPS = 32;
export const H265_NAL_SPS = 33;
export const H265_NAL_PPS = 34;
export const H265_NAL_AUD = 35;

export function isH265Irap(type: number): boolean {
  return type >= 16 && type <= 23;
}

// ITU-T H.265 7.3.2.2.1 up to bit depths. The 2-byte NAL header is skipped.
export function parseH265Sps(nal: Uint8Array): H265Sps {
  const r = new BitReader(toRbsp(nal, 2));

  r.u(4); // sps_video_parameter_set_id
  const maxSubLayersMinus1 = r.u(3);
  const temporalIdNesting = r.flag();

  // profile_tier_level(1, maxSubLayersMinus1)
  const profileSpace = r.u(2);
  const tierFlag = r.u(1);
  const profileIdc = r.u(5);
  let compatibilityFlags = 0;
  for (let j = 0; j < 32; j++) {
    if (r.u(1)) compatibilityFlags |= 1 << j;
  }
  compatibilityFlags >>>= 0;
  const constraintBytes = new Uint8Array(6);
  for (let k = 0; k < 6; k++) constraintBytes[k] = r.u(8);
  const levelIdc = r.u(8);

  const subLayerProfilePresent: boolean[] = [];
  const subLayerLevelPresent: boolean[] = [];
  for (let i = 0; i < maxSubLayersMinus1; i++) {
    subLayerProfilePresent.push(r.flag());
    subLayerLevelPresent.push(r.flag());
  }
  if (maxSubLayersMinus1 > 0) {
    for (let i = maxSubLayersMinus1; i < 8; i++) r.skip(2); // reserved_zero_2bits
  }
  for (let i = 0; i < maxSubLayersMinus1; i++) {
    if (subLayerProfilePresent[i]) r.skip(88);
    if (subLayerLevelPresent[i]) r.skip(8);
  }

  r.ue(); // sps_seq_parameter_set_id
  const chromaFormatIdc = r.ue();
  if (chromaFormatIdc === 3) r.skip(1); // separate_colour_plane_flag
  let width = r.ue();
  let height = r.ue();

  if (r.flag()) {
    // conformance_window_flag: offsets in chroma sample units
    const subWidthC = chromaFormatIdc === 1 || chromaFormatIdc === 2 ? 2 : 1;
    const subHeightC = chromaFormatIdc === 1 ? 2 : 1;
    const left = r.ue();
    const right = r.ue();
    const top = r.ue();
    const bottom = r.ue();
    width -= (left + right) * subWidthC;
    height -= (top + bottom) * subHeightC;
  }

  const bitDepthLumaMinus8 = r.ue();
  const bitDepthChromaMinus8 = r.ue();

  return {
    profileSpace,
    tierFlag,
    profileIdc,
    compatibilityFlags,
    constraintBytes,
    levelIdc,
    maxSubLayersMinus1,
    temporalIdNesting,
    chromaFormatIdc,
    bitDepthLumaMinus8,
    bitDepthChromaMinus8,
    width,
    height
  };
}

// ISO/IEC 14496-15 Annex E: <hvc1|hev1>.<space><profile>.<compat hex>.<L|H><level>.<constraint bytes>,
// trailing zero constraint bytes dropped. Main profile 1080p from the device:
// hvc1.1.6.L123.90 (compat flags 1+2 -> "6", constraint 0x90 = progressive +
// frame_only).
export function h265CodecString(sps: H265Sps, box: 'hvc1' | 'hev1' = 'hvc1'): string {
  const constraints = Array.from(sps.constraintBytes, (b) => b.toString(16).toUpperCase().padStart(2, '0'));
  while (constraints.length > 0 && constraints[constraints.length - 1] === '00') constraints.pop();

  const space = ['', 'A', 'B', 'C'][sps.profileSpace];
  return [
    box,
    `${space}${sps.profileIdc}`,
    sps.compatibilityFlags.toString(16).toUpperCase(),
    `${sps.tierFlag ? 'H' : 'L'}${sps.levelIdc}`,
    ...constraints
  ].join('.');
}

// ISO/IEC 14496-15 8.3.3.1.2 HEVCDecoderConfigurationRecord with one array
// each for VPS, SPS, PPS (array_completeness = 1: the parameter sets are also
// kept out of the samples).
export function buildHvcC(sps: H265Sps, vpsNal: Uint8Array, spsNal: Uint8Array, ppsNal: Uint8Array): Uint8Array {
  const parts: number[] = [
    1, // configurationVersion
    (sps.profileSpace << 6) | (sps.tierFlag << 5) | sps.profileIdc,
    (sps.compatibilityFlags >>> 24) & 0xff,
    (sps.compatibilityFlags >>> 16) & 0xff,
    (sps.compatibilityFlags >>> 8) & 0xff,
    sps.compatibilityFlags & 0xff,
    ...sps.constraintBytes,
    sps.levelIdc,
    0xf0, // reserved 1111 + min_spatial_segmentation_idc (12 bits) = 0
    0x00,
    0xfc, // reserved 111111 + parallelismType = 0
    0xfc | sps.chromaFormatIdc,
    0xf8 | sps.bitDepthLumaMinus8,
    0xf8 | sps.bitDepthChromaMinus8,
    0, // avgFrameRate
    0,
    // constantFrameRate=0, numTemporalLayers, temporalIdNested, lengthSizeMinusOne=3
    ((sps.maxSubLayersMinus1 + 1) << 3) | ((sps.temporalIdNesting ? 1 : 0) << 2) | 3,
    3 // numOfArrays
  ];

  for (const [type, nal] of [
    [H265_NAL_VPS, vpsNal],
    [H265_NAL_SPS, spsNal],
    [H265_NAL_PPS, ppsNal]
  ] as [number, Uint8Array][]) {
    parts.push(0x80 | type, 0, 1, nal.length >> 8, nal.length & 0xff, ...nal);
  }

  return Uint8Array.from(parts);
}
