JSON.stringify({
  storedMode: localStorage.getItem('nano-kvm-vide-mode'),
  fallbackFlag: sessionStorage.getItem('nano-kvm-video-paint-fallback'),
  canvas: !!document.querySelector('canvas#screen'),
  video: !!document.querySelector('video#screen'),
  notices: [...document.querySelectorAll('.ant-notification-notice')].map((n) => n.innerText)
})
