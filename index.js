/* ==========================================================================
   CrateDigger Landing Page JavaScript
   ========================================================================== */

document.addEventListener('DOMContentLoaded', () => {
  // --- Theme Switching ---
  const body = document.body;
  const appScreenshot = document.getElementById('app-screenshot');
  const btnCarbon = document.getElementById('theme-carbon');
  const btnLinen = document.getElementById('theme-linen');

  function setTheme(theme) {
    body.setAttribute('data-theme', theme);
    if (theme === 'dark') {
      btnCarbon.classList.add('active');
      btnLinen.classList.remove('active');
      appScreenshot.src = 'assets/screenshot_dark.png';
      appScreenshot.alt = 'CrateDigger Carbon (Dark) Mode';
    } else {
      btnCarbon.classList.remove('active');
      btnLinen.classList.add('active');
      appScreenshot.src = 'assets/screenshot_light.png';
      appScreenshot.alt = 'CrateDigger Linen (Light) Mode';
    }
  }

  btnCarbon.addEventListener('click', () => setTheme('dark'));
  btnLinen.addEventListener('click', () => setTheme('light'));


  // --- Hotspot Tooltips Interactivity ---
  const hotspots = document.querySelectorAll('.hotspot');
  const tooltipDefault = document.getElementById('tooltip-default');
  const tooltipContents = document.querySelectorAll('.tooltip-content');

  function showTooltip(tooltipId) {
    // Hide all tooltip texts
    tooltipContents.forEach(content => {
      content.classList.remove('active');
    });

    // Show selected tooltip text
    const targetTooltip = document.getElementById(`tooltip-${tooltipId}`);
    if (targetTooltip) {
      targetTooltip.classList.add('active');
    } else {
      tooltipDefault.classList.add('active');
    }
  }

  function resetTooltip() {
    tooltipContents.forEach(content => {
      content.classList.remove('active');
    });
    tooltipDefault.classList.add('active');
  }

  // Hover events for hotspots
  hotspots.forEach(hotspot => {
    const tooltipId = hotspot.getAttribute('data-tooltip');

    hotspot.addEventListener('mouseenter', () => {
      showTooltip(tooltipId);
    });

    hotspot.addEventListener('mouseleave', () => {
      // We don't reset immediately to allow reading, 
      // or we can reset on mouseleave of the container.
      // Let's keep the hovered one active until they hover something else,
      // which is a better reading experience.
    });

    // Support tap/click for mobile devices
    hotspot.addEventListener('click', (e) => {
      e.stopPropagation();
      showTooltip(tooltipId);
    });
  });

  // Clicking on the canvas itself resets tooltip (except when clicking hotspots)
  const appCanvas = document.querySelector('.app-canvas');
  if (appCanvas) {
    appCanvas.addEventListener('click', () => {
      resetTooltip();
    });
  }
});
