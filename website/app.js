(() => {
  const RELEASE_DATA = {
    version: '1.8.2',
    notes:
      '高刷屏适配与流畅度优化：支持 Android 90Hz/120Hz/144Hz 同分辨率最高刷新率，流式输出合帧窗口优化至 64ms，消息列表新增 RepaintBoundary 隔离重绘',
    assets: {
      'arm64-v8a': {
        name: 'zpocket-1.8.2-arm64-v8a.apk',
        size: '31.8 MB',
        url: 'https://nghqqa.cn/updates/zpocket-1.8.2-arm64-v8a.apk',
        sha256: '65afc551539b6dbfc93635941eef508bee20e6b8ca9a788ab893fa477360c480',
      },
      'armeabi-v7a': {
        name: 'zpocket-1.8.2-armeabi-v7a.apk',
        size: '28.6 MB',
        url: 'https://nghqqa.cn/updates/zpocket-1.8.2-armeabi-v7a.apk',
        sha256: '2e1fdfa7714921b5dff819fad50ba5a297d547a3c1f73b3aa20a277f9fc86ae3',
      },
      x86_64: {
        name: 'zpocket-1.8.2-x86_64.apk',
        size: '34.4 MB',
        url: 'https://nghqqa.cn/updates/zpocket-1.8.2-x86_64.apk',
        sha256: '5885d3617a36f505e8cff94675b9e85c153d14eeeee21aafe05a1e451f99b7d9',
      },
    },
  };

  let currentAbi = 'arm64-v8a';

  // Screenshot showcase tabs
  const tabBtns = document.querySelectorAll('.tab-btn');
  const showcaseImg = document.getElementById('showcase-img');
  const showcaseCaption = document.getElementById('showcase-caption');

  tabBtns.forEach((btn) => {
    btn.addEventListener('click', () => {
      tabBtns.forEach((b) => {
        b.classList.remove('active');
        b.setAttribute('aria-selected', 'false');
      });
      btn.classList.add('active');
      btn.setAttribute('aria-selected', 'true');
      showcaseImg.src = btn.dataset.img;
      showcaseCaption.textContent = btn.dataset.caption;
    });
  });

  // ABI download panel
  const abiBtns = document.querySelectorAll('.abi-btn');
  const dlVersion = document.getElementById('dl-version');
  const dlNotes = document.getElementById('dl-notes');
  const dlFilename = document.getElementById('dl-filename');
  const dlSha = document.getElementById('dl-sha');
  const dlPrimaryUrl = document.getElementById('dl-primary-url');
  const dlGithubUrl = document.getElementById('dl-github-url');
  const copyBtn = document.getElementById('copy-sha-btn');

  function renderDownload() {
    const item = RELEASE_DATA.assets[currentAbi];
    if (!item) return;
    dlVersion.textContent = `v${RELEASE_DATA.version}`;
    dlNotes.textContent = RELEASE_DATA.notes;
    dlFilename.textContent = `${item.name}${item.size ? ` (${item.size})` : ''}`;
    dlSha.textContent = item.sha256;
    dlPrimaryUrl.href = item.url;
    dlGithubUrl.href = `https://github.com/nghqqa/zpocket/releases/download/v${RELEASE_DATA.version}/${item.name}`;
  }

  abiBtns.forEach((btn) => {
    btn.addEventListener('click', () => {
      abiBtns.forEach((b) => {
        b.classList.remove('active');
        b.setAttribute('aria-selected', 'false');
      });
      btn.classList.add('active');
      btn.setAttribute('aria-selected', 'true');
      currentAbi = btn.dataset.abi;
      renderDownload();
    });
  });

  copyBtn.addEventListener('click', async () => {
    const sha = dlSha.textContent.trim();
    try {
      await navigator.clipboard.writeText(sha);
      copyBtn.textContent = '已复制';
      setTimeout(() => {
        copyBtn.textContent = '复制';
      }, 1500);
    } catch {
      copyBtn.textContent = '请手动复制';
    }
  });

  renderDownload();

  // Attempt live manifest sync (gracefully ignored if CORS/offline)
  fetch('https://nghqqa.cn/updates/manifest.json', { mode: 'cors' })
    .then((res) => (res.ok ? res.json() : null))
    .then((manifest) => {
      if (!manifest || !manifest.version || !Array.isArray(manifest.assets)) return;
      RELEASE_DATA.version = manifest.version;
      if (manifest.notes) RELEASE_DATA.notes = manifest.notes;
      for (const a of manifest.assets) {
        const key = ['arm64-v8a', 'armeabi-v7a', 'x86_64'].find((k) => a.name && a.name.includes(k));
        if (key && a.url && a.sha256) {
          RELEASE_DATA.assets[key] = {
            name: a.name,
            size: RELEASE_DATA.assets[key]?.size || '',
            url: a.url,
            sha256: a.sha256,
          };
        }
      }
      const heroVer = document.getElementById('hero-version-text');
      const heroBtn = document.getElementById('hero-download-btn');
      if (heroVer) heroVer.textContent = `v${RELEASE_DATA.version} · 已适配 ZCode 3.18`;
      if (heroBtn && RELEASE_DATA.assets['arm64-v8a']) {
        heroBtn.href = RELEASE_DATA.assets['arm64-v8a'].url;
      }
      renderDownload();
    })
    .catch(() => {});
})();
