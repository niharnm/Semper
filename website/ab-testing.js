(function attachSemperExperiments(root, factory) {
  const api = factory();

  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }

  if (root && root.document) {
    root.SemperExperiments = api;
    root.semperWebsiteExperiment = api.startWebsiteExperiment(root);
  }
})(typeof globalThis === "undefined" ? this : globalThis, function createAPI() {
  "use strict";

  const EXPERIMENT_ID = "website.hero-repository-cta-copy.v1";
  const SUBJECT_KEY = "semper.ab.subject.v1";
  const ASSIGNMENT_PREFIX = "semper.ab.assignment.";
  const ROOT_ATTRIBUTE = "data-semper-ab-hero-cta";
  const VALID_VARIANTS = new Set(["control", "treatment"]);

  function fnv1a32(value) {
    let hash = 0x811c9dc5;

    for (let index = 0; index < value.length; index += 1) {
      hash ^= value.charCodeAt(index);
      hash = Math.imul(hash, 0x01000193);
    }

    return hash >>> 0;
  }

  function assignedVariant(experimentID, subjectID) {
    const bucket = fnv1a32(`${experimentID}:${subjectID}`) % 10000;
    return bucket < 5000 ? "control" : "treatment";
  }

  function debugOverride(search, experimentID) {
    const rawValue = new URLSearchParams(search).get("semper_ab");
    if (!rawValue) return null;

    const separatorIndex = rawValue.lastIndexOf(":");
    if (separatorIndex < 0) return null;

    const requestedExperiment = rawValue.slice(0, separatorIndex);
    const requestedVariant = rawValue.slice(separatorIndex + 1);

    if (
      requestedExperiment !== experimentID ||
      !VALID_VARIANTS.has(requestedVariant)
    ) {
      return null;
    }

    return requestedVariant;
  }

  function canUseStorage(storage) {
    if (!storage) return false;

    const probeKey = "semper.ab.storage-probe";
    try {
      storage.setItem(probeKey, "1");
      storage.removeItem(probeKey);
      return true;
    } catch {
      return false;
    }
  }

  function browserStorage(browserWindow) {
    try {
      if (canUseStorage(browserWindow.localStorage)) {
        return browserWindow.localStorage;
      }
    } catch {
      // Continue to session storage.
    }

    try {
      if (canUseStorage(browserWindow.sessionStorage)) {
        return browserWindow.sessionStorage;
      }
    } catch {
      // The control remains visible when browser storage is unavailable.
    }

    return null;
  }

  function randomUUID(browserWindow) {
    if (browserWindow.crypto?.randomUUID) {
      return browserWindow.crypto.randomUUID();
    }

    if (!browserWindow.crypto?.getRandomValues) {
      return null;
    }

    const bytes = new Uint8Array(16);
    browserWindow.crypto.getRandomValues(bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = [...bytes].map((byte) => byte.toString(16).padStart(2, "0"));

    return [
      hex.slice(0, 4).join(""),
      hex.slice(4, 6).join(""),
      hex.slice(6, 8).join(""),
      hex.slice(8, 10).join(""),
      hex.slice(10, 16).join(""),
    ].join("-");
  }

  function resolveAssignment({
    experimentID,
    storage,
    search,
    makeUUID,
  }) {
    const override = debugOverride(search, experimentID);

    if (!storage) {
      return {
        subjectID: makeUUID() ?? "storage-unavailable",
        variant: override ?? "control",
        source: override ? "debug_override" : "fallback",
      };
    }

    try {
      let subjectID = storage.getItem(SUBJECT_KEY);
      if (!subjectID) {
        subjectID = makeUUID();
        if (!subjectID) {
          return {
            subjectID: "uuid-unavailable",
            variant: override ?? "control",
            source: override ? "debug_override" : "fallback",
          };
        }
        storage.setItem(SUBJECT_KEY, subjectID);
      }

      if (override) {
        return {
          subjectID,
          variant: override,
          source: "debug_override",
        };
      }

      const assignmentKey = `${ASSIGNMENT_PREFIX}${experimentID}`;
      const storedVariant = storage.getItem(assignmentKey);
      if (VALID_VARIANTS.has(storedVariant)) {
        return {
          subjectID,
          variant: storedVariant,
          source: "bucket",
        };
      }

      const variant = assignedVariant(experimentID, subjectID);
      storage.setItem(assignmentKey, variant);
      return { subjectID, variant, source: "bucket" };
    } catch {
      return {
        subjectID: makeUUID() ?? "storage-unavailable",
        variant: override ?? "control",
        source: override ? "debug_override" : "fallback",
      };
    }
  }

  function createClient({
    experimentID,
    storage,
    search = "",
    makeUUID,
    emit,
    now = () => new Date(),
  }) {
    const assignment = resolveAssignment({
      experimentID,
      storage,
      search,
      makeUUID,
    });
    const sessionID = makeUUID() ?? "session-unavailable";
    const emittedKeys = new Set();
    let fallbackEventIndex = 0;

    function emitOnce(eventName, metricKey = null) {
      const dedupeKey = `${eventName}:${metricKey ?? ""}`;
      if (emittedKeys.has(dedupeKey)) return false;
      if (eventName === "experiment_outcome") {
        const exposureKey = "experiment_exposure:";
        if (!emittedKeys.has(exposureKey)) return false;
      }

      emittedKeys.add(dedupeKey);
      fallbackEventIndex += 1;
      emit({
        schema_version: 1,
        event_id:
          makeUUID() ?? `${sessionID}:event-${String(fallbackEventIndex)}`,
        event_name: eventName,
        occurred_at: now().toISOString(),
        surface: "website",
        experiment_id: experimentID,
        variant: assignment.variant,
        assignment_source: assignment.source,
        subject_id: assignment.subjectID,
        session_id: sessionID,
        collection_mode: "local",
        metric_key: metricKey,
      });
      return true;
    }

    return {
      assignment,
      recordExposure: () => emitOnce("experiment_exposure"),
      recordOutcome: (metricKey) =>
        emitOnce("experiment_outcome", metricKey),
    };
  }

  function startWebsiteExperiment(browserWindow) {
    const storage = browserStorage(browserWindow);
    const client = createClient({
      experimentID: EXPERIMENT_ID,
      storage,
      search: browserWindow.location.search,
      makeUUID: () => randomUUID(browserWindow),
      emit: (event) => {
        browserWindow.dispatchEvent(
          new browserWindow.CustomEvent("semper:experiment", {
            detail: event,
          }),
        );
      },
    });

    browserWindow.document.documentElement.setAttribute(
      ROOT_ATTRIBUTE,
      client.assignment.variant,
    );

    const bindExperiment = () => {
      const cta = browserWindow.document.querySelector(
        `[data-ab-experiment="${EXPERIMENT_ID}"]`,
      );
      if (!cta) return;

      if ("IntersectionObserver" in browserWindow) {
        const observer = new browserWindow.IntersectionObserver(
          (entries) => {
            if (
              !entries.some(
                (entry) =>
                  entry.isIntersecting && entry.intersectionRatio >= 0.5,
              )
            ) {
              return;
            }
            client.recordExposure();
            observer.disconnect();
          },
          { threshold: 0.5 },
        );
        observer.observe(cta);
      } else {
        client.recordExposure();
      }

      cta.addEventListener("click", () => {
        client.recordExposure();
        client.recordOutcome(cta.dataset.abConversion);
      });
    };

    if (browserWindow.document.readyState === "loading") {
      browserWindow.document.addEventListener(
        "DOMContentLoaded",
        bindExperiment,
        { once: true },
      );
    } else {
      bindExperiment();
    }

    return client;
  }

  return {
    EXPERIMENT_ID,
    assignedVariant,
    createClient,
    debugOverride,
    fnv1a32,
    resolveAssignment,
    startWebsiteExperiment,
  };
});
