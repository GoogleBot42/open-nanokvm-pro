import { useEffect, useState } from 'react';
import { Divider, Popover } from 'antd';
import { useAtom } from 'jotai';
import { CheckIcon, SquareActivityIcon } from 'lucide-react';
import { useTranslation } from 'react-i18next';

import * as api from '@/api/stream.ts';
import * as storage from '@/lib/localstorage.ts';
import { videoParametersAtom } from '@/jotai/screen.ts';

export const Quality = () => {
  const { t } = useTranslation();

  const [videoParameters, setVideoParameters] = useAtom(videoParametersAtom);

  const [customQuality, setCustomQuality] = useState(0);
  const [isLoading, setIsLoading] = useState(false);

  const qualityList = [
    { value: 100, label: t('screen.qualityLossless') },
    { value: 80, label: t('screen.qualityHigh') },
    { value: 60, label: t('screen.qualityMedium') },
    { value: 50, label: t('screen.qualityLow') }
  ];

  useEffect(() => {
    const isExist = qualityList.some((quality) => quality.value === videoParameters.quality);
    const value = isExist ? 0 : Math.floor(videoParameters.quality || 80);
    setCustomQuality(value);
  }, [videoParameters]);

  async function update(value: number) {
    if (isLoading || value === videoParameters.quality) {
      return;
    }

    setIsLoading(true);

    try {
      const rsp = await api.setQuality(value);
      if (rsp.code !== 0) {
        return;
      }

      const parameters = { ...videoParameters, quality: value };
      setVideoParameters(parameters);
      storage.setVideoParameters(JSON.stringify(parameters));
    } catch (err) {
      console.log(err);
    } finally {
      setIsLoading(false);
    }
  }

  const content = (
    <>
      {qualityList.map((quality) => (
        <div
          key={quality.value}
          className="flex h-[30px] cursor-pointer select-none items-center rounded pl-1 pr-5 hover:bg-neutral-700/70"
          onClick={() => update(quality.value)}
        >
          <div className="flex h-[14px] w-[20px] items-end text-blue-500">
            {quality.value === videoParameters.quality && <CheckIcon size={14} />}
          </div>
          <span>{quality.label}</span>
        </div>
      ))}

      {customQuality > 0 && (
        <>
          <Divider style={{ margin: '5px 0' }} />
          <div className="flex h-[30px] cursor-pointer select-none items-center rounded pl-1 pr-5 hover:bg-neutral-700/70">
            <div className="flex h-[14px] w-[20px] items-end text-blue-500">
              <CheckIcon size={14} />
            </div>
            <span>{customQuality}%</span>
          </div>
        </>
      )}
    </>
  );

  return (
    <Popover content={content} placement="rightTop" arrow={false} align={{ offset: [14, 0] }}>
      <div className="flex h-[30px] cursor-pointer items-center space-x-2 rounded pl-3 pr-6 text-neutral-300 hover:bg-neutral-700/70">
        <SquareActivityIcon size={18} />
        <span className="select-none text-sm">{t('screen.quality')}</span>
      </div>
    </Popover>
  );
};
