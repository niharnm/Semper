const reducedMotionQuery = window.matchMedia(
  "(prefers-reduced-motion: reduce)",
);
const prefersReducedMotion = reducedMotionQuery.matches;

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

document.querySelectorAll(".app-row .mute-button").forEach((button) => {
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

const masterOutput = document.querySelector(".master-output");
const masterSlider = document.querySelector("[data-master-volume]");
const masterValue = document.querySelector(".master-value");
const masterMute = document.querySelector("[data-master-mute]");

const renderMasterSlider = () => {
  if (!masterSlider || !masterValue) return;
  const value = `${masterSlider.value}%`;
  masterSlider.style.setProperty("--range-value", value);
  masterValue.textContent = value;
};

if (masterSlider && masterOutput && masterMute) {
  renderMasterSlider();
  masterSlider.addEventListener("input", () => {
    renderMasterSlider();
    if (Number(masterSlider.value) > 0) {
      masterOutput.classList.remove("is-muted");
      masterMute.setAttribute("aria-pressed", "false");
      masterMute.setAttribute("aria-label", "Mute AirPods Pro");
      masterMute.innerHTML = volumeIcon;
    }
  });

  masterMute.addEventListener("click", () => {
    const willMute = masterMute.getAttribute("aria-pressed") !== "true";
    masterOutput.classList.toggle("is-muted", willMute);
    masterMute.setAttribute("aria-pressed", String(willMute));
    masterMute.setAttribute(
      "aria-label",
      `${willMute ? "Unmute" : "Mute"} AirPods Pro`,
    );
    masterMute.innerHTML = willMute ? mutedIcon : volumeIcon;
  });
}

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
const signalStory = document.querySelector("[data-signal-story]");
const desktopMotionQuery = window.matchMedia("(min-width: 821px)");
const signalInputPaths = signalStory
  ? [...signalStory.querySelectorAll("[data-signal-input]")]
  : [];
const signalSplitPaths = signalStory
  ? [...signalStory.querySelectorAll("[data-signal-split]")]
  : [];
const signalPackets = signalStory
  ? [...signalStory.querySelectorAll("[data-signal-packet]")]
  : [];

const clamp = (value, minimum = 0, maximum = 1) =>
  Math.min(Math.max(value, minimum), maximum);

const updateProgress = () => {
  const scrollRange =
    document.documentElement.scrollHeight - window.innerHeight;
  const progress = scrollRange > 0 ? window.scrollY / scrollRange : 0;
  progressBar.style.transform = `scaleX(${clamp(progress)})`;
};

const placeSignalPacket = (packet, path, progress) => {
  const point = path.getPointAtLength(path.getTotalLength() * clamp(progress));
  packet.setAttribute("cx", point.x);
  packet.setAttribute("cy", point.y);
};

const updateSignalStory = () => {
  if (!signalStory) return;

  const isScrollDriven =
    desktopMotionQuery.matches && !reducedMotionQuery.matches;

  signalStory.classList.toggle("is-scroll-driven", isScrollDriven);

  if (!isScrollDriven) {
    signalStory.dataset.phase = "split";
    signalStory.style.setProperty("--signal-impact", "0");
    signalStory.style.setProperty("--signal-input-draw", "1");
    signalStory.style.setProperty("--signal-split-draw", "1");
    return;
  }

  const storyBounds = signalStory.getBoundingClientRect();
  const scrollDistance = Math.max(
    signalStory.offsetHeight - window.innerHeight,
    1,
  );
  const progress = clamp(-storyBounds.top / scrollDistance);
  const inputTravel = clamp((progress - 0.04) / 0.42);
  const splitTravel = clamp((progress - 0.56) / 0.3);
  const impact = clamp(1 - Math.abs(progress - 0.5) / 0.065);
  const phase =
    progress < 0.41 ? "start" : progress < 0.56 ? "collision" : "split";

  signalStory.dataset.phase = phase;
  signalStory.style.setProperty("--signal-impact", impact.toFixed(3));
  signalStory.style.setProperty(
    "--signal-input-draw",
    clamp(0.35 + progress * 2.4).toFixed(3),
  );
  signalStory.style.setProperty("--signal-split-draw", splitTravel.toFixed(3));

  signalPackets.forEach((packet, index) => {
    const path =
      phase === "split" ? signalSplitPaths[index] : signalInputPaths[index];
    const packetProgress = phase === "split" ? splitTravel : inputTravel;
    placeSignalPacket(packet, path, packetProgress);
  });
};

let pageUpdateFrame = 0;

const updatePageState = () => {
  pageUpdateFrame = 0;
  updateProgress();
  updateSignalStory();
};

const queuePageUpdate = () => {
  if (pageUpdateFrame) return;
  pageUpdateFrame = window.requestAnimationFrame(updatePageState);
};

queuePageUpdate();
window.addEventListener("scroll", queuePageUpdate, { passive: true });
window.addEventListener("resize", queuePageUpdate);
reducedMotionQuery.addEventListener("change", queuePageUpdate);
desktopMotionQuery.addEventListener("change", queuePageUpdate);

window.addEventListener(
  "pagehide",
  () => {
    window.removeEventListener("scroll", queuePageUpdate);
    window.removeEventListener("resize", queuePageUpdate);
    reducedMotionQuery.removeEventListener("change", queuePageUpdate);
    desktopMotionQuery.removeEventListener("change", queuePageUpdate);
    if (pageUpdateFrame) window.cancelAnimationFrame(pageUpdateFrame);
  },
  { once: true },
);

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

const downloadCommand = document.querySelector("[data-download-command]");
const copyCommandButton = document.querySelector("[data-copy-command]");
const copyCommandLabel = document.querySelector("[data-copy-label]");
const copyCommandStatus = document.querySelector("[data-copy-status]");
let copyCommandResetTimer = 0;

const writeToClipboard = async (text) => {
  let nativeClipboardError = null;

  if (navigator.clipboard && window.isSecureContext) {
    try {
      await navigator.clipboard.writeText(text);
      return;
    } catch (error) {
      nativeClipboardError = error;
    }
  }

  const copyTarget = document.createElement("textarea");
  copyTarget.value = text;
  copyTarget.setAttribute("readonly", "");
  copyTarget.style.position = "fixed";
  copyTarget.style.opacity = "0";
  document.body.appendChild(copyTarget);
  copyTarget.select();

  let didCopy = false;
  try {
    didCopy = document.execCommand("copy");
  } finally {
    copyTarget.remove();
  }

  if (!didCopy) {
    throw nativeClipboardError ?? new Error("Clipboard copy was unavailable.");
  }
};

const resetCopyCommand = () => {
  copyCommandButton.classList.remove("is-copied", "is-copy-error");
  copyCommandButton.setAttribute("aria-label", "Copy download command");
  copyCommandLabel.textContent = "Copy";
};

if (
  downloadCommand &&
  copyCommandButton &&
  copyCommandLabel &&
  copyCommandStatus
) {
  copyCommandButton.addEventListener("click", async () => {
    window.clearTimeout(copyCommandResetTimer);

    try {
      await writeToClipboard(downloadCommand.textContent.trim());
      copyCommandButton.classList.remove("is-copy-error");
      copyCommandButton.classList.add("is-copied");
      copyCommandButton.setAttribute("aria-label", "Download command copied");
      copyCommandLabel.textContent = "Copied";
      copyCommandStatus.textContent = "Download command copied.";
    } catch (error) {
      copyCommandButton.classList.remove("is-copied");
      copyCommandButton.classList.add("is-copy-error");
      copyCommandButton.setAttribute(
        "aria-label",
        "Copy failed. Select the command manually.",
      );
      copyCommandLabel.textContent = "Copy failed";
      copyCommandStatus.textContent =
        "Copy failed. Select the download command manually.";
      console.error("Unable to copy the download command.", error);
    }

    copyCommandResetTimer = window.setTimeout(resetCopyCommand, 2400);
  });

  window.addEventListener(
    "pagehide",
    () => window.clearTimeout(copyCommandResetTimer),
    { once: true },
  );
}

document.getElementById("year").textContent = new Date().getFullYear();
