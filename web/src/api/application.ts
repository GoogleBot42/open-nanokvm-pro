import { http } from '@/lib/http.ts';

// get application version
export function getVersion() {
  return http.get('/api/application/version');
}

// update application to latest version
export function update() {
  return http.request({
    method: 'post',
    url: '/api/application/update',
    timeout: 15 * 60 * 1000 // 15 minutes
  });
}

// enable/disable preview updates
export function setPreviewUpdates(enable: boolean) {
  const data = {
    enable
  };
  return http.post('/api/application/preview', data);
}

// get preview updates state
export function getPreviewUpdates() {
  return http.get('/api/application/preview');
}

// enable/disable automatic (unattended) updates
export function setAutoUpdates(enable: boolean) {
  const data = {
    enable
  };
  return http.post('/api/application/auto', data);
}

// get automatic updates state
export function getAutoUpdates() {
  return http.get('/api/application/auto');
}

// An update that is installed but not yet booted, plus what (if anything) is
// keeping the device from rebooting into it on its own.
// pkgs/nanokvm-server/update-status.go.in.
export function getUpdateStatus() {
  return http.get('/api/application/pending');
}
