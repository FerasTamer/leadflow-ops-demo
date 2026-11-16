"""Assemble the final video from frames + ElevenLabs narration, with burned-in English captions.

usage: python -I video/tools/build_video.py
Inputs : video/build/frames/*.png, video/build/frames/reveal.json, video/audio/<segment>.mp3,
         video/script/<segment>.txt
Output : video/LeadFlow-Ops-Demo.mp4
"""
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
VID = ROOT / "video"
FRAMES = VID / "build" / "frames"
SEG_DIR = VID / "build" / "segments"
WINGET = pathlib.Path(os.environ.get("LOCALAPPDATA", "")) / "Microsoft" / "WinGet" / "Links"


def find_tool(name):
    """FFMPEG / FFPROBE env var, then PATH, then the winget install location on Windows."""
    found = os.environ.get(name.upper()) or shutil.which(name)
    if found:
        return found
    candidate = WINGET / f"{name}.exe"
    if candidate.exists():
        return str(candidate)
    raise SystemExit(f"{name} not found: install ffmpeg or set {name.upper()}")


FFMPEG = find_tool("ffmpeg")
FFPROBE = find_tool("ffprobe")

W, H_CONTENT, H = 1920, 940, 1080
FPS = 30
LEAD, TAIL, FADE = 0.35, 0.75, 0.25
BG_BAND = "0x0b1020"
TERM_BG = "0x0f172a"

# segment -> still frame (terminal segments use a frame with the same name)
STILLS = {
    "00_intro": "intro", "01_arch_system": "arch_system", "02_arch_cards": "arch_cards",
    "03_arch_run": "arch_run", "04_arch_schema": "arch_schema", "05_n8n_workflow": "n8n_workflow",
    "99_outro": "n8n_executions",
}


def run(args):
    proc = subprocess.run(args, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr[-3000:])
        raise SystemExit(f"command failed: {' '.join(args[:6])} ...")
    return proc.stdout


def duration(path):
    return float(run([FFPROBE, "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)]))


def still_filter(n_frames):
    # Slow 4% push-in. Upscale first so zoompan does not jitter.
    return (f"[0:v]scale=3840:-2,zoompan=z='1+0.04*on/{n_frames}':x='iw/2-(iw/zoom/2)':"
            f"y='ih/2-(ih/zoom/2)':d={n_frames}:s={W}x{H_CONTENT}:fps={FPS}[v0]")


def terminal_filter(info, dur):
    top, bottom = info["outTop"], max(info["outBottom"], info["outTop"] + 1)
    reveal = max(1.2, min(0.7 * dur, 0.08 * (bottom - top) / 21 + 1.5))
    cover_h = H_CONTENT - top - 20
    return (f"color=c={TERM_BG}:s=1872x{cover_h}:r={FPS}[cov];"
            f"[0:v]scale={W}:{H_CONTENT},fps={FPS}[base];"
            f"[base][cov]overlay=x=24:y='if(lt(t,{reveal:.3f}),{top}+({bottom}-{top})*(t-{LEAD})/{reveal - LEAD:.3f}*gte(t,{LEAD}),{H_CONTENT})':"
            f"shortest=1[v0]")


def build_segment(name, dur):
    frame = FRAMES / f"{STILLS.get(name, name)}.png"
    audio = VID / "audio" / f"{name}.mp3"
    out = SEG_DIR / f"{name}.mp4"
    n_frames = int(round(dur * FPS))
    if name in STILLS:
        vf = still_filter(n_frames)
    else:
        info = json.loads((FRAMES / "reveal.json").read_text(encoding="utf-8"))[name]
        vf = terminal_filter(info, dur)
    vf += (f";[v0]pad={W}:{H}:0:0:color={BG_BAND},format=yuv420p,"
           f"fade=t=in:st=0:d={FADE},fade=t=out:st={dur - FADE:.3f}:d={FADE}[v]")
    af = (f"[1:a]aresample=48000,aformat=channel_layouts=stereo,adelay={int(LEAD * 1000)}:all=1,"
          f"apad,atrim=0:{dur:.3f}[a]")
    # zoompan emits d frames per input frame, so stills go in as a single frame;
    # terminal frames are looped for the duration and animated by the overlay.
    image_in = ["-i", str(frame)] if name in STILLS else \
        ["-loop", "1", "-framerate", str(FPS), "-t", f"{dur:.3f}", "-i", str(frame)]
    run([FFMPEG, "-y", *image_in, "-i", str(audio), "-filter_complex", vf + ";" + af, "-map", "[v]", "-map", "[a]",
         "-t", f"{dur:.3f}", "-r", str(FPS), "-c:v", "libx264", "-preset", "medium", "-crf", "19",
         "-c:a", "aac", "-b:a", "192k", str(out)])
    return out


def caption_chunks(text):
    """Sentences, then long sentences split at commas, each chunk at most ~90 characters."""
    chunks = []
    for sentence in re.split(r"(?<=[.!?:])\s+", text.strip()):
        parts, cur = [], ""
        for piece in re.split(r"(?<=,)\s+", sentence):
            if cur and len(cur) + len(piece) + 1 > 90:
                parts.append(cur)
                cur = piece
            else:
                cur = f"{cur} {piece}".strip()
        if cur:
            parts.append(cur)
        chunks.extend(parts)
    return chunks


def srt_time(t):
    ms = int(round(t * 1000))
    return f"{ms // 3600000:02}:{ms // 60000 % 60:02}:{ms // 1000 % 60:02},{ms % 1000:03}"


def main():
    names = sorted(p.stem for p in (VID / "script").glob("[0-9][0-9]_*.txt"))
    missing = [n for n in names if not (VID / "audio" / f"{n}.mp3").exists()]
    if missing:
        raise SystemExit(f"missing audio: {missing}")
    SEG_DIR.mkdir(parents=True, exist_ok=True)

    cues, segments, clock = [], [], 0.0
    for i, name in enumerate(names, 1):
        speech = duration(VID / "audio" / f"{name}.mp3")
        dur = LEAD + speech + TAIL
        segments.append(build_segment(name, dur))
        chunks = caption_chunks((VID / "script" / f"{name}.txt").read_text(encoding="utf-8"))
        total = sum(len(c) for c in chunks)
        t = clock + LEAD
        for c in chunks:
            span = speech * len(c) / total
            cues.append((t, t + span - 0.05, c))
            t += span
        clock += dur
        print(f"[{i:02}/{len(names)}] {name}: {dur:5.1f}s")

    (SEG_DIR / "list.txt").write_text("".join(f"file '{s.name}'\n" for s in segments), encoding="utf-8")
    srt = "".join(f"{i}\n{srt_time(a)} --> {srt_time(b)}\n{c}\n\n" for i, (a, b, c) in enumerate(cues, 1))
    (SEG_DIR / "captions.srt").write_text(srt, encoding="utf-8")

    run([FFMPEG, "-y", "-f", "concat", "-safe", "0", "-i", str(SEG_DIR / "list.txt"), "-c", "copy",
         str(SEG_DIR / "joined.mp4")])

    style = ("FontName=Segoe UI,FontSize=12,Bold=0,PrimaryColour=&H00FFFFFF,OutlineColour=&H00101010,"
             "BorderStyle=1,Outline=0.6,Shadow=0,MarginV=11,Alignment=2")
    final = VID / "LeadFlow-Ops-Demo.mp4"
    # Run from SEG_DIR so the subtitles filter gets a plain relative path (no Windows drive colon).
    proc = subprocess.run(
        [FFMPEG, "-y", "-i", "joined.mp4", "-vf", f"subtitles=captions.srt:force_style='{style}'",
         "-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-c:v", "libx264", "-preset", "medium", "-crf", "19",
         "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", str(final)],
        cwd=SEG_DIR, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr[-3000:])
        raise SystemExit("final encode failed")
    print(f"done: {final} ({duration(final):.1f}s, {final.stat().st_size / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
