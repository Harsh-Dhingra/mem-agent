// mem-agent tab bridge: every 30s, send the tab inventory to the daemon via
// the native messaging host and discard whatever tab ids it hands back.
// Privacy: only the URL host and a truncated title leave the browser, and
// they go solely to the local mem-agent daemon over stdio — no network.

const HOST = "com.memagent.chrome";
const ALARM = "memagent-sync";

function hostOf(url) {
  try {
    return new URL(url).host || null;
  } catch {
    return null;
  }
}

async function sync() {
  let tabs;
  try {
    tabs = await chrome.tabs.query({});
  } catch {
    return;
  }
  const now = Date.now();
  const payload = {
    tabs: tabs
      .filter((t) => t.id !== chrome.tabs.TAB_ID_NONE)
      .map((t) => ({
        id: t.id,
        active: t.active,
        audible: t.audible ?? false,
        pinned: t.pinned,
        discarded: t.discarded ?? false,
        last_accessed: t.lastAccessed ?? now,
        url_host: hostOf(t.url ?? ""),
        title: (t.title ?? "").slice(0, 80),
      })),
  };
  chrome.runtime.sendNativeMessage(HOST, payload, async (resp) => {
    if (chrome.runtime.lastError) return; // daemon/host not installed — quiet
    for (const id of resp?.discard_tab_ids ?? []) {
      try {
        await chrome.tabs.discard(id);
      } catch {
        // tab closed in the meantime — fine
      }
    }
  });
}

function arm() {
  chrome.alarms.create(ALARM, { periodInMinutes: 0.5 });
  sync();
}

chrome.runtime.onInstalled.addListener(arm);
chrome.runtime.onStartup.addListener(arm);
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === ALARM) sync();
});
