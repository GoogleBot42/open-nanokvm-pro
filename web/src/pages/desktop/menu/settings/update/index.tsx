import { useEffect, useState } from 'react';
import { LoadingOutlined, RocketOutlined, SmileOutlined } from '@ant-design/icons';
import { Button, Divider, Result, Spin } from 'antd';
import { useTranslation } from 'react-i18next';
import semver from 'semver';

import * as api from '@/api/application.ts';
import * as vmApi from '@/api/vm.ts';

import { Auto } from './auto.tsx';
import { Preview } from './preview.tsx';
import { Updating } from './updating.tsx';

type UpdateProps = {
  setIsLocked: (isClosable: boolean) => void;
};

type Status = '' | 'loading' | 'updating' | 'outdated' | 'latest' | 'failed' | 'pending';

// What the server reports about an installed-but-not-yet-booted update
// (pkgs/nanokvm-server/update-status.go.in).
type Pending = {
  version: string;
  from: string;
  reboot_pending: boolean;
  current: string;
};

export const Update = ({ setIsLocked }: UpdateProps) => {
  const { t } = useTranslation();

  const [status, setStatus] = useState<Status>('');
  const [currentVersion, setCurrentVersion] = useState('');
  const [latestVersion, setLatestVersion] = useState('');
  const [errMsg, setErrMsg] = useState('');
  const [tipMsg, setTipMsg] = useState('');
  const [pending, setPending] = useState<Pending | null>(null);
  const [busy, setBusy] = useState<string[]>([]);

  useEffect(() => {
    checkForUpdates();
  }, []);

  // A PENDING REBOOT OUTRANKS THE VERSION CHECK. An automatic update installs
  // as soon as the timer finds one and reboots only when nobody is using the
  // device, so the page must say "installed, restart pending" rather than
  // offering the same version again -- which the device would refuse anyway.
  function checkForUpdates() {
    if (status === 'loading') return;
    setStatus('loading');

    api
      .getUpdateStatus()
      .then((rsp: any) => {
        if (rsp.code === 0 && rsp.data?.pending?.reboot_pending) {
          setPending(rsp.data.pending);
          setBusy(rsp.data.busy || []);
          setStatus('pending');
          return;
        }

        setPending(null);
        checkVersion();
      })
      .catch(() => {
        setPending(null);
        checkVersion();
      });
  }

  // THE VERDICT IS THE SERVER'S (#101). `up_to_date` is what
  // `nanokvm-update check` decided about the device's own channel -- the same
  // channel, the same manifest, the same comparison the install will make. The
  // semver fallback below is for a server that predates the field: upstream
  // compares versions here, and the appliance does not, because it installs
  // what the channel offers and a deliberate downgrade is a downgrade rather
  // than "you are up to date".
  function checkVersion() {
    api
      .getVersion()
      .then((rsp: any) => {
        if (rsp.code !== 0 || !rsp.data) {
          setStatus('failed');
          setErrMsg(t('settings.update.queryFailed'));
          return;
        }

        setCurrentVersion(rsp.data.current);
        setLatestVersion(rsp.data.latest);

        const hasUpdate =
          typeof rsp.data.up_to_date === 'boolean'
            ? !rsp.data.up_to_date
            : semver.gt(rsp.data.latest, rsp.data.current);
        if (hasUpdate) {
          setTipMsg(t('settings.update.available'));
        }
        setStatus(hasUpdate ? 'outdated' : 'latest');
      })
      .catch(() => {
        setStatus('failed');
        setErrMsg(t('settings.update.queryFailed'));
      });
  }

  function update() {
    if (status !== 'outdated') return;

    setIsLocked(true);
    setStatus('updating');

    api.update().then((rsp: any) => {
      if (rsp.code !== 0) {
        setStatus('failed');
        setErrMsg(t('settings.update.updateFailed'));
      }
    });
  }

  // The person reading this page is usually the person the device is waiting
  // for, so let them say "go". Same route the system reboot button uses.
  function restartNow() {
    setIsLocked(true);
    setStatus('updating');
    vmApi.reboot();
  }

  return (
    <>
      <div className="text-base font-bold">{t('settings.update.title')}</div>
      <Divider className="opacity-50" />

      <Auto />
      <Preview checkForUpdates={checkForUpdates} />
      <Divider className="opacity-50" />

      <div className="flex min-h-[400px] flex-col justify-between">
        {status === 'loading' && (
          <div className="flex justify-center pt-24">
            <Spin indicator={<LoadingOutlined spin />} size="large" />
          </div>
        )}

        {status === 'updating' && <Updating />}

        {status === 'pending' && pending && (
          <Result
            status="success"
            icon={<RocketOutlined />}
            title={`${pending.from} -> ${pending.version}`}
            subTitle={
              <div className="flex flex-col items-center space-y-1">
                <span>{t('settings.update.restartPending')}</span>
                {busy.length > 0 && (
                  <span className="text-xs text-neutral-500">
                    {t('settings.update.waitingFor')}{' '}
                    {busy.map((b) => t(`settings.update.busy.${b}`)).join(', ')}
                  </span>
                )}
              </div>
            }
            extra={[
              <Button key="restart" type="primary" onClick={restartNow}>
                {t('settings.update.restartNow')}
              </Button>
            ]}
          />
        )}

        {status === 'latest' && (
          <Result
            status="success"
            icon={<SmileOutlined />}
            title={currentVersion}
            subTitle={t('settings.update.isLatest')}
            extra={[
              <Button key="confirm" onClick={checkForUpdates}>
                {t('settings.update.title')}
              </Button>
            ]}
          />
        )}

        {status === 'outdated' && (
          <Result
            status="warning"
            icon={<RocketOutlined />}
            title={`${currentVersion} -> ${latestVersion}`}
            subTitle={tipMsg}
            extra={[
              <Button key="confirm" type="primary" onClick={update}>
                {t('settings.update.confirm')}
              </Button>
            ]}
          />
        )}

        {status === 'failed' && <Result subTitle={errMsg} />}

        <div className="flex justify-center">
          <Button
            type="link"
            size="small"
            href="https://github.com/GoogleBot42/open-nanokvm-pro/blob/main/CHANGELOG.md"
            target="_blank"
          >
            {t('settings.update.changelog')}
          </Button>
        </div>
      </div>
    </>
  );
};
