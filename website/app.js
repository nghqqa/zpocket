(() => {
  const RELEASE_DATA = {
    version: '1.7.0',
    notes:
      '合入上游 v1.0.9（兼容 ZCode 3.19.1）：PDF 产物应用内预览、会话内搜索增强、扫码实时预览按机型分流、收集产物直达条与自动激活工作流、平板/折叠屏横屏解锁、任务完成横幅开关、子代理模型按提供方分组',
    assets: {
      'arm64-v8a': {
        name: 'zpocket-1.7.0-arm64-v8a.apk',
        size: '31.8 MB',
        url: 'https://nghqqa.cn/updates/zpocket-1.7.0-arm64-v8a.apk',
        sha256: '533f6c83a753dc41bc8f68c185395296099f5d7639fdfdaf0f3445d0f07e94b4',
      },
      'armeabi-v7a': {
        name: 'zpocket-1.7.0-armeabi-v7a.apk',
        size: '28.5 MB',
        url: 'https://nghqqa.cn/updates/zpocket-1.7.0-armeabi-v7a.apk',
        sha256: 'a99bed849fe792bca1cdb3339e035aeee6bdad1d1960cbd2371fc7b5697c46c4',
      },
      x86_64: {
        name: 'zpocket-1.7.0-x86_64.apk',
        size: '34.4 MB',
        url: 'https://nghqqa.cn/updates/zpocket-1.7.0-x86_64.apk',
        sha256: 'c12d19a47a248a9b7b2de372956e8c0173a3ebc7ce1f47cfd024e37bc3aab568',
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
