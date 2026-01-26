import { useEffect, useState } from "react";
import "./App.css";

async function loadConfig() {
  const res = await fetch("/config.json", { cache: "no-store" });
  if (!res.ok) throw new Error(`Failed to load config.json: ${res.status}`);
  return res.json();
}

export default function App() {
  const [apiBaseUrl, setApiBaseUrl] = useState("");
  const [payload, setPayload] = useState(JSON.stringify({ msg: "Welcome to the AI Lending app test" }, null, 2));
  const [out, setOut] = useState("");
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    loadConfig()
      .then((cfg) => setApiBaseUrl(cfg.apiBaseUrl || ""))
      .catch((e) => setOut(`Config error: ${e.message}`));
  }, []);

  const callApi = async () => {
    setLoading(true);
    setOut("Calling...");
    try {
      const url = apiBaseUrl.replace(/\/$/, "") + "/api/v1/chat";
      const res = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: payload
      });
      const text = await res.text();
      setOut(`HTTP ${res.status}\n\n${text}`);
    } catch (e) {
      setOut(`Error: ${e.message || e}`);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div style={{ maxWidth: 900, margin: "40px auto", fontFamily: "system-ui" }}>
      <h1>LLM Lending Agent (Dev)</h1>

      <div style={{ marginBottom: 12 }}>
        <div style={{ fontSize: 12, opacity: 0.7 }}>API Base URL (from /config.json)</div>
        <div style={{ fontFamily: "monospace", wordBreak: "break-all" }}>
          {apiBaseUrl || "(not loaded)"}
        </div>
      </div>

      <div style={{ marginBottom: 8 }}>Request JSON</div>
      <textarea
        value={payload}
        onChange={(e) => setPayload(e.target.value)}
        style={{ width: "100%", height: 120, fontFamily: "monospace" }}
      />

      <div style={{ marginTop: 12 }}>
        <button onClick={callApi} disabled={!apiBaseUrl || loading}>
          {loading ? "Calling..." : "POST /api/v1/chat"}
        </button>
      </div>

      <h3 style={{ marginTop: 24 }}>Response</h3>
      <pre style={{ background: "#cfcfcf", padding: 12, overflow: "auto" }}>{out}</pre>
    </div>
  );
}