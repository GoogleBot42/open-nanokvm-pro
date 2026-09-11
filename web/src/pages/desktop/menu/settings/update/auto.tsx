import { useEffect, useState } from 'react';
import { Switch, Tooltip } from 'antd';
import { CircleAlertIcon } from 'lucide-react';
import { useTranslation } from 'react-i18next';

import * as api from '@/api/application.ts';

// "Automatic updates", beside "Preview updates" and deliberately identical to
// it in shape: one flag file each, presence = on. Ticking this is the ONLY way
// the device updates itself -- the timer runs either way and does nothing while
// the file is absent. See docs/updates.md.
export const Auto = () => {
  const { t } = useTranslation();

  const [isLoading, setIsLoading] = useState(false);
  const [isEnabled, setIsEnabled] = useState(false);

  useEffect(() => {
    getAutoUpdates();
  }, []);

  function getAutoUpdates() {
    setIsLoading(true);

    api
      .getAutoUpdates()
      .then((rsp) => {
        if (rsp.code !== 0) {
          console.log(rsp.msg);
          return;
        }

        setIsEnabled(rsp.data.enabled);
      })
      .finally(() => {
        setIsLoading(false);
      });
  }

  function setAutoUpdates() {
    if (isLoading) return;
    setIsLoading(true);

    const enable = !isEnabled;

    api
      .setAutoUpdates(enable)
      .then((rsp) => {
        if (rsp.code !== 0) {
          console.log(rsp.msg);
          return;
        }

        setIsEnabled(enable);
      })
      .finally(() => {
        setIsLoading(false);
      });
  }

  return (
    <div className="flex items-center justify-between py-3">
      <div className="flex flex-col">
        <div className="flex items-center space-x-2">
          <span>{t('settings.update.auto')}</span>

          <Tooltip
            title={t('settings.update.autoTip')}
            className="cursor-pointer text-neutral-500/60"
            placement="bottom"
            styles={{ root: { maxWidth: '350px' } }}
          >
            <CircleAlertIcon size={15} />
          </Tooltip>
        </div>

        <span className="text-xs text-neutral-500">{t('settings.update.autoDesc')}</span>
      </div>

      <Switch checked={isEnabled} loading={isLoading} onChange={setAutoUpdates} />
    </div>
  );
};
