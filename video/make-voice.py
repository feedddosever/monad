"""Generate the narration clips (out/clips/*.wav, out/clips.json) from narration.json with Piper TTS.

Usage: python3 make-voice.py <piper-binary> <voice.onnx>
"""
import json
import pathlib
import subprocess
import sys

piper, voice = sys.argv[1], sys.argv[2]
here = pathlib.Path(__file__).resolve().parent
out = here / "out" / "clips"
out.mkdir(parents=True, exist_ok=True)
clips = {}
for key, line in json.loads((here / "narration.json").read_text()).items():
    wav = out / f"{key}.wav"
    subprocess.run([piper, "--model", voice, "--output_file", str(wav), "--length_scale", "0.93", "--sentence_silence", "0.2"],
                   input=line["tts"].encode(), check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    dur = float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(wav)]))
    clips[key] = {"file": str(wav), "dur": round(dur, 3), "caption": line["caption"]}
    print(f"{key:9s} {dur:5.1f}s")
(here / "out" / "clips.json").write_text(json.dumps(clips, indent=1))
print(f"speech total {sum(c['dur'] for c in clips.values()):.1f}s")
