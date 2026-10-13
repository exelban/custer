const downloads = document.querySelectorAll('[data-download]');

downloads.forEach((download) => {
  download.addEventListener('click', () => {
    if (!window.umami) {
      return;
    }

    window.umami.track('download', { edition: download.dataset.download, location: 'hero' });
  });
});
