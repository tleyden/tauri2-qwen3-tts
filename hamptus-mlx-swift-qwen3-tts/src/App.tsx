import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import "./App.css";
import podcastScript from "../swift-only-poc/test_data/podcast_script.txt?raw";

function App() {
  const [speakers, setSpeakers] = useState<string[]>([]);
  const [speaker, setSpeaker] = useState("");
  const [text, setText] = useState(
    "Hello from the Rust side of the Qwen three T T S bridge.",
  );
  const [chunkSize, setChunkSize] = useState(500);
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
    setStatus(
      chunkSize === 0
        ? "Synthesizing without chunking..."
        : `Synthesizing in ${chunkSize}-character chunks...`,
    );
    try {
      const base64Wav = await invoke<string>("synthesize_speech", {
        text,
        speaker,
        chunkSize,
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
      <div className="row settings-row">
        <label htmlFor="chunk-size">Chunk size</label>
        <input
          id="chunk-size"
          type="number"
          min="0"
          max="2000"
          step="50"
          value={chunkSize}
          onChange={(e) =>
            setChunkSize(Math.max(0, Number(e.currentTarget.value) || 0))
          }
        />
      </div>

      <form
        className="editor-form"
        onSubmit={(e) => {
          e.preventDefault();
          synthesize();
        }}
      >
        <button
          type="button"
          className="sample-content-link"
          onClick={() => setText(podcastScript)}
        >
          insert sample content
        </button>
        <textarea
          className="text-input"
          value={text}
          onChange={(e) => setText(e.currentTarget.value)}
        />
        <div className="actions">
          <button type="submit">Synthesize</button>
        </div>
      </form>

      <p>{status}</p>

      {audioUrl && <audio controls autoPlay src={audioUrl} />}
    </main>
  );
}

export default App;
