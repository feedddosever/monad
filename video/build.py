"""Assemble capture.json (screencast frames + narration timeline) into an H.264/AAC MP4."""
import json
import pathlib
import subprocess
import sys

video_dir = str(pathlib.Path(__file__).resolve().parent / "out")
out = sys.argv[1] if len(sys.argv) > 1 else f"{video_dir}/monad-credit-demo.mp4"
cap = json.load(open(f"{video_dir}/capture.json"))
frames = sorted(cap["frames"], key=lambda f: f["t"])
t0, t_end = frames[0]["t"], cap["tEnd"]

# Video: each screencast frame holds until the next one arrives.
with open(f"{video_dir}/frames.txt", "w") as fh:
    for i, f in enumerate(frames):
        nxt = frames[i + 1]["t"] if i + 1 < len(frames) else t_end
        fh.write(f"file '{f['file']}'\nduration {max(nxt - f['t'], 0.001):.4f}\n")
    fh.write(f"file '{frames[-1]['file']}'\n")
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", f"{video_dir}/frames.txt",
                "-vf", "fps=30,scale=1920:1080:flags=lanczos,format=yuv420p", "-c:v", "libx264", "-preset", "slow",
                "-crf", "18", "-movflags", "+faststart", f"{video_dir}/video.mp4"], check=True)

# Audio: every clip delayed to the moment it started during capture, mixed onto silence.
total = t_end - t0
inputs, chains = [], []
for i, c in enumerate(cap["timeline"]):
    inputs += ["-i", c["file"]]
    delay = max(0, int((c["t"] - t0) * 1000))
    chains.append(f"[{i}:a]aresample=48000,adelay={delay}:all=1[a{i}]")
mix = "".join(f"[a{i}]" for i in range(len(cap["timeline"])))
graph = ";".join(chains) + f";{mix}amix=inputs={len(cap['timeline'])}:normalize=0:dropout_transition=0,apad,atrim=0:{total:.3f}[out]"
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", graph, "-map", "[out]",
                "-ac", "2", "-c:a", "aac", "-b:a", "160k", f"{video_dir}/audio.m4a"], check=True)

subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", f"{video_dir}/video.mp4", "-i", f"{video_dir}/audio.m4a",
                "-map", "0:v", "-map", "1:a", "-c", "copy", "-shortest", "-movflags", "+faststart", out], check=True)
dur = subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", out]).decode().strip()
print(f"{out}: {float(dur):.1f} s, {len(frames)} frames, {len(cap['timeline'])} narration clips")
