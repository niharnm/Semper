const prefersReducedMotion = window.matchMedia(
  "(prefers-reduced-motion: reduce)",
).matches;

const volumeIcon = `
  <svg viewBox="0 0 20 20" aria-hidden="true">
    <path d="M3 8h3l4-3v10l-4-3H3V8Z" />
    <path d="M13 7.5a4 4 0 0 1 0 5" />
  </svg>
`;

const mutedIcon = `
  <svg viewBox="0 0 20 20" aria-hidden="true">
    <path d="M3 8h3l4-3v10l-4-3H3V8Z" />
    <path d="m13 8 4 4M17 8l-4 4" />
  </svg>
`;

document.querySelectorAll("[data-volume]").forEach((slider) => {
  const row = slider.closest(".app-row");
  const valueLabel = slider.parentElement.querySelector(".range-value");

  const renderSlider = () => {
    const value = `${slider.value}%`;
    slider.style.setProperty("--range-value", value);
    valueLabel.textContent = value;
  };

  const updateSlider = () => {
    renderSlider();
    if (Number(slider.value) > 0 && row.classList.contains("is-muted")) {
      const muteButton = row.querySelector(".mute-button");
      row.classList.remove("is-muted");
      muteButton.setAttribute("aria-pressed", "false");
      muteButton.setAttribute(
        "aria-label",
        `Mute ${row.querySelector(".app-heading strong").textContent}`,
      );
      muteButton.innerHTML = volumeIcon;
    }
  };

  renderSlider();
  slider.addEventListener("input", updateSlider);
});

document.querySelectorAll(".mute-button").forEach((button) => {
  button.addEventListener("click", () => {
    const row = button.closest(".app-row");
    const appName = row.querySelector(".app-heading strong").textContent;
    const willMute = button.getAttribute("aria-pressed") !== "true";

    row.classList.toggle("is-muted", willMute);
    button.setAttribute("aria-pressed", String(willMute));
    button.setAttribute(
      "aria-label",
      `${willMute ? "Unmute" : "Mute"} ${appName}`,
    );
    button.innerHTML = willMute ? mutedIcon : volumeIcon;
  });
});

const eqPresets = {
  flat: [48, 48, 48, 48, 48, 48, 48, 48, 48, 48],
  focus: [62, 58, 52, 45, 39, 35, 34, 38, 45, 51],
  warm: [28, 31, 36, 42, 47, 51, 55, 58, 62, 65],
};

const eqBands = [...document.querySelectorAll(".eq-band i")];

document.querySelectorAll("[data-preset]").forEach((button) => {
  button.addEventListener("click", () => {
    const gains = eqPresets[button.dataset.preset];

    document.querySelectorAll("[data-preset]").forEach((presetButton) => {
      const isActive = presetButton === button;
      presetButton.classList.toggle("is-active", isActive);
      presetButton.setAttribute("aria-pressed", String(isActive));
    });

    eqBands.forEach((band, index) => {
      band.style.setProperty("--gain", `${gains[index]}%`);
    });
  });
});

const progressBar = document.querySelector(".page-progress span");

const updateProgress = () => {
  const scrollRange =
    document.documentElement.scrollHeight - window.innerHeight;
  const progress = scrollRange > 0 ? window.scrollY / scrollRange : 0;
  progressBar.style.transform = `scaleX(${Math.min(Math.max(progress, 0), 1)})`;
};

updateProgress();
window.addEventListener("scroll", updateProgress, { passive: true });
window.addEventListener("resize", updateProgress);

const revealItems = document.querySelectorAll(".reveal");

if (prefersReducedMotion || !("IntersectionObserver" in window)) {
  revealItems.forEach((item) => item.classList.add("is-visible"));
} else {
  const revealObserver = new IntersectionObserver(
    (entries, observer) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      });
    },
    { threshold: 0.14, rootMargin: "0px 0px -8% 0px" },
  );

  revealItems.forEach((item) => revealObserver.observe(item));
}

document.getElementById("year").textContent = new Date().getFullYear();
