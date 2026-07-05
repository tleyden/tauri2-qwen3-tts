use clap::Parser;
use st_tts::Tts;
use std::path::PathBuf;

/// Simple CLI for on-device TTS via the Supertonic model (supertonic-rs / st-tts crate).
#[derive(Parser)]
#[command(name = "supertonic-cli", about = "Synthesize speech with Supertonic TTS")]
struct Args {
    /// Text to synthesize
    text: String,

    /// Language code
    #[arg(short, long, default_value = "en")]
    lang: String,

    /// Output WAV file path
    #[arg(short, long, default_value = "output.wav")]
    out: PathBuf,

    /// HuggingFace model id (downloaded and cached on first run)
    #[arg(long, default_value = "Supertone/supertonic-3")]
    model: String,

    /// Voice name
    #[arg(long, default_value = "M1")]
    voice: String,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();

    eprintln!("Loading model '{}' (voice: {})...", args.model, args.voice);
    let tts = Tts::new(&args.model, &args.voice).await?;

    eprintln!("Synthesizing...");
    let wav = tts.synthesize_wav(&args.text, &args.lang, None).await?;

    std::fs::write(&args.out, &wav)?;
    eprintln!("Wrote {} bytes to {}", wav.len(), args.out.display());

    Ok(())
}
