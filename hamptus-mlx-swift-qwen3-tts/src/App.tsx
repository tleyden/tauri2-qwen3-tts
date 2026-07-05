import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import "./App.css";

function App() {
  const [speakers, setSpeakers] = useState<string[]>([]);
  const [speaker, setSpeaker] = useState("");
  const [text, setText] = useState(
    "Hello from the Rust side of the Qwen three T T S bridge."
  );
  const [audioUrl, setAudioUrl] = useState("");
  const [status, setStatus] = useState("");

  useEffect(() => {
    invoke<string[]>("available_speakers")
      .then((names) => {
        setSpeakers(names);
        setSpeaker(names[0] ?? "");
        setStatus("");
      })
      .catch((err) => setStatus(`Failed to load speakers: ${err}`));
  }, []);

  async function synthesize() {
    setStatus("Synthesizing...");
    try {
      const base64Wav = await invoke<string>("synthesize_speech", {
        text,
        speaker,
      });
      setAudioUrl(`data:audio/wav;base64,${base64Wav}`);
      setStatus("Done.");
    } catch (err) {
      setStatus(`Synthesis failed: ${err}`);
    }
  }

  return (
    <main className="container">
      <h1>Qwen3-TTS Rust/Swift bridge test harness</h1>

      <div className="row">
        <select value={speaker} onChange={(e) => setSpeaker(e.target.value)}>
          {speakers.map((name) => (
            <option key={name} value={name}>
              {name}
            </option>
          ))}
        </select>
      </div>

      <form
        className="row"
        onSubmit={(e) => {
          e.preventDefault();
          synthesize();
        }}
      >
        <input
          value={text}
          onChange={(e) => setText(e.currentTarget.value)}
          style={{ width: "24em" }}
        />
        <button type="submit">Synthesize</button>
      </form>

      <p>{status}</p>

      {audioUrl && <audio controls autoPlay src={audioUrl} />}
    </main>
  );
}

export default App;
