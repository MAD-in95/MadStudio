"""Command line entry point the Mac app talks to.

Every command prints JSON lines: {"event": "progress"|"partial"|"done"|"error", ...}
"""

import argparse
import json
import sys
import traceback

from . import device, events, export, models, paths, transcribe


def _cmd_device(_):
    events.emit("done", result=device.device_info())


def _cmd_speed_test(_):
    events.emit("done", result=device.speed_test())


def _cmd_tempo(args):
    """Makes a re-voiced piece faster or slower without changing the voice's pitch."""
    import subprocess

    factor = min(2.0, max(0.5, args.factor))
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", args.input, "-filter:a", f"atempo={factor}", args.output], check=True)
    from . import audio as audio_module

    events.emit("done", result={"path": args.output, "duration": audio_module.probe(args.output)["duration"]})


def _cmd_audiofx(args):
    """A recording through a filter chain the app built from the microphone settings."""
    import subprocess

    chain = args.chain.strip() or "anull"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", args.input, "-af", chain, "-c:a", "pcm_s24le", args.output], check=True)
    events.emit("done", result={"path": args.output})


def _cmd_hub(args):
    from . import hub

    if args.action == "search":
        events.emit("done", result=hub.search(args.task, args.query or ""))
    elif args.action == "stats":
        events.emit("done", result=hub.stats())
    elif args.action == "install":
        result = hub.install(args.task, args.query, on_progress=lambda v: events.progress("download", v, model=args.query))
        events.emit("done", result=result)


def _cmd_models(args):
    if args.action == "where":
        events.emit("done", result=paths.models_dir_status())
    elif args.action == "move":
        events.emit("done", result=paths.move_models(args.id or "", on_progress=lambda v: events.progress("move", v)))
    elif args.action == "use":
        models.use(args.id)
        events.emit("done", result={"id": args.id})
    elif args.action == "updates":
        events.emit("done", result=models.updates())
    elif args.action == "update":
        path = models.update(args.id, on_progress=lambda v: events.progress("download", v, model=args.id))
        events.emit("done", result={"id": args.id, "path": str(path)})
    elif args.action == "list":
        events.emit("done", result=models.list_models())
    elif args.action == "install":
        path = models.install(args.id, on_progress=lambda v: events.progress("download", v, model=args.id))
        events.emit("done", result={"id": args.id, "path": str(path)})
    elif args.action == "remove":
        models.remove(args.id)
        events.emit("done", result={"id": args.id})


def _cmd_transcribe(args):
    result = transcribe.transcribe(
        args.input, args.model,
        on_progress=events.progress,
        on_partial=lambda start, text: events.emit("partial", start=start, text=text),
    )
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False)
    # waveform data for the app, next to the transcript
    from pathlib import Path

    from . import audio
    Path(args.output).with_name("loudness.bin").write_bytes(audio.loudness(audio.load(args.input)))
    events.emit("done", result={"path": args.output, "tokens": len(result["tokens"]),
                                "seconds_spent": result["seconds_spent"]})


def _cmd_reanalyze(args):
    events.emit("done", result=transcribe.reanalyze(args.transcript))


_voice = None   # stays loaded between requests in `serve` mode


def _cmd_revoice(args):
    from . import voice as voice_module

    global _voice
    with open(args.transcript, encoding="utf-8") as f:
        tokens = json.load(f)["tokens"]
    if _voice is None:
        events.progress("voice_load", 0.0)
        _voice = voice_module.Voice()
        events.progress("voice_load", 1.0)
    voice_module.STEPS = args.steps
    result = _voice.replace(args.source, tokens, args.first, args.last, args.text, args.output,
                            on_progress=lambda v: events.progress("voice", v), speed=args.speed)
    events.emit("done", result=result)


def _cmd_speak(args):
    from . import voice as voice_module
    from .speak import speak

    global _voice
    with open(args.text, encoding="utf-8") as f:
        text = f.read()
    if _voice is None:
        events.progress("voice_load", 0.0)
        _voice = voice_module.Voice()
        events.progress("voice_load", 1.0)
    result = speak(_voice, text, args.ref_audio, args.ref_text, args.output, speed=args.speed,
                   on_progress=lambda v: events.progress("speak", v))
    events.emit("done", result=result)


IDLE_EXIT = 300.0   # a server with nothing to do for 5 minutes quits and frees the memory


def _cmd_serve(args):
    """Keeps the process (and the models it loaded) alive: every stdin line is a JSON list
    of command arguments; after each command comes {"event": "end"}. Only for commands
    whose models are worth keeping (re-voicing)."""
    import select

    parser = _parser()
    while True:
        ready, _, _ = select.select([sys.stdin], [], [], IDLE_EXIT)
        if not ready:
            return
        line = sys.stdin.readline()
        if not line:
            return
        try:
            argv = json.loads(line)
            if not argv or argv[0] not in ("revoice", "speak"):
                raise RuntimeError("serve: only the voice model is kept warm")
            parsed = parser.parse_args(argv)
            parsed.fn(parsed)
        except Exception as e:  # noqa: BLE001 — report and keep serving
            traceback.print_exc()
            events.emit("error", message=str(e), **({"model": e.model_id} if hasattr(e, "model_id") else {}))
        events.emit("end")


def _cmd_speakers(args):
    result = transcribe.speakers_for(args.transcript, args.source,
                                     on_progress=lambda v: events.progress("speakers", v))
    events.emit("done", result=result)


def _cmd_extract(args):
    from . import audio

    path = audio.extract(args.input, args.output_base)
    events.emit("done", result={"path": path, **audio.probe(path)})


def _cmd_youtube(args):
    from .text_ai import TextModel

    with open(args.script, encoding="utf-8") as f:
        script = f.read()
    events.progress("text_load", 0.0)
    model = TextModel(str(models.require(models.default_for("text"))))
    events.progress("text_load", 1.0)
    events.emit("done", result=model.youtube(script, on_progress=lambda v: events.progress("youtube", v)))


def _cmd_shorts(args):
    from .shorts import find
    from .text_ai import TextModel

    with open(args.words, encoding="utf-8") as f:
        words = json.load(f)
    events.progress("text_load", 0.0)
    model = TextModel(str(models.require(models.default_for("text"))))
    events.progress("text_load", 1.0)
    events.emit("done", result={"moments": find(model, words, on_progress=lambda v: events.progress("shorts", v))})


def _cmd_verify_voice(args):
    from .consent import verify

    voice_print = None
    if args.print:
        with open(args.print, encoding="utf-8") as f:
            voice_print = json.load(f)
    events.emit("done", result=verify(args.recording, args.phrase, voice_print,
                                      on_progress=lambda v: events.progress("verify", v)))


def _cmd_voice_prints(args):
    from .consent import prints_for

    events.emit("done", result=prints_for(args.transcript, args.source))


def _cmd_translate(args):
    from .translate import dub

    with open(args.words, encoding="utf-8") as f:
        words = json.load(f)
    events.emit("done", result=dub(args.source, words, args.language, args.output,
                                   on_progress=events.progress, keep_background=args.background))


def _cmd_separate(args):
    from .separate import Separator

    result = Separator().run(args.source, args.voice, args.background,
                             on_progress=lambda v: events.progress("separate", v))
    events.emit("done", result=result)


def _cmd_mixdown(args):
    from .mixdown import mix

    with open(args.plan, encoding="utf-8") as f:
        plan = json.load(f)
    events.emit("done", result=mix(plan, args.output, on_progress=lambda v: events.progress("export", v)))


def _cmd_voicefx(args):
    from .voicefx import process

    events.emit("done", result=process(args.source, args.output, denoise=args.denoise, radio=args.radio,
                                       on_progress=lambda v: events.progress("voicefx", v)))


def _cmd_detect(args):
    from .voice import detect_watermark

    events.emit("done", result=detect_watermark(args.file))


def _cmd_export(args):
    with open(args.ranges, encoding="utf-8") as f:
        plan = json.load(f)
    segments = plan.get("segments", plan.get("ranges", []))
    target = plan.get("loudness")
    loudness = export.PRESETS.get(target, target) if target is not None else None
    result = export.render(args.input, segments, args.output, loudness=loudness,
                           on_progress=lambda v: events.progress("export", v))
    events.emit("done", result=result)


def _parser():
    parser = argparse.ArgumentParser(prog="madstudio-engine")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("device").set_defaults(fn=_cmd_device)
    sub.add_parser("speed-test", help="how fast this Mac runs the models; time estimates").set_defaults(fn=_cmd_speed_test)

    p = sub.add_parser("models")
    p.add_argument("action", choices=["list", "install", "remove", "use", "updates", "update", "where", "move"])
    p.add_argument("id", nargs="?")
    p.set_defaults(fn=_cmd_models)

    p = sub.add_parser("hub", help="find models on Hugging Face for a task, or install one")
    p.add_argument("action", choices=["search", "install", "stats"])
    p.add_argument("task", nargs="?")
    p.add_argument("query", nargs="?", help="search words, or the repository to install")
    p.set_defaults(fn=_cmd_hub)

    p = sub.add_parser("transcribe")
    p.add_argument("input")
    p.add_argument("output")
    p.add_argument("--model")
    p.set_defaults(fn=_cmd_transcribe)

    p = sub.add_parser("reanalyze", help="upgrade an existing transcript to the current analysis")
    p.add_argument("transcript")
    p.set_defaults(fn=_cmd_reanalyze)

    p = sub.add_parser("revoice", help="say new words in place of tokens first..last, in the speaker's voice")
    p.add_argument("transcript")
    p.add_argument("source")
    p.add_argument("first", type=int)
    p.add_argument("last", type=int)
    p.add_argument("text")
    p.add_argument("output")
    p.add_argument("--speed", type=float, default=1.0, help="pace of the new words: 1.2 — faster, 0.85 — slower")
    p.add_argument("--steps", type=int, default=16,
                   help="16: ~2x faster (measured: same voice similarity and intelligibility); 32: finest")
    p.set_defaults(fn=_cmd_revoice)

    p = sub.add_parser("speak", help="read a text aloud in a confirmed voice")
    p.add_argument("text", help="UTF-8 text file")
    p.add_argument("ref_audio", help="the voice's confirmation reading")
    p.add_argument("ref_text", help="what is said in it")
    p.add_argument("output")
    p.add_argument("--speed", type=float, default=1.0)
    p.set_defaults(fn=_cmd_speak)

    p = sub.add_parser("audiofx", help="process a recording with an ffmpeg filter chain (microphone presets)")
    p.add_argument("input")
    p.add_argument("output")
    p.add_argument("chain")
    p.set_defaults(fn=_cmd_audiofx)

    p = sub.add_parser("tempo", help="faster/slower without changing pitch (re-voiced pieces)")
    p.add_argument("input")
    p.add_argument("output")
    p.add_argument("factor", type=float)
    p.set_defaults(fn=_cmd_tempo)

    sub.add_parser("serve", help="keep models loaded: JSON argument lists on stdin").set_defaults(fn=_cmd_serve)

    p = sub.add_parser("speakers", help="find who speaks when in an existing transcript")
    p.add_argument("transcript")
    p.add_argument("source")
    p.set_defaults(fn=_cmd_speakers)

    p = sub.add_parser("extract-audio", help="take the sound out of a video without losing quality")
    p.add_argument("input")
    p.add_argument("output_base", help="output path without extension")
    p.set_defaults(fn=_cmd_extract)

    p = sub.add_parser("verify-voice", help="check a read-aloud confirmation: the phrase and the voice")
    p.add_argument("recording")
    p.add_argument("phrase")
    p.add_argument("--print", help="JSON file with the voice print it must match")
    p.set_defaults(fn=_cmd_verify_voice)

    p = sub.add_parser("voice-prints", help="voice print of every speaker of a transcript")
    p.add_argument("transcript")
    p.add_argument("source")
    p.set_defaults(fn=_cmd_voice_prints)

    p = sub.add_parser("shorts", help="moments for Shorts/Reels from the edited words (JSON list with times)")
    p.add_argument("words")
    p.set_defaults(fn=_cmd_shorts)

    p = sub.add_parser("youtube", help="chapters, titles, description and tags from a timed script")
    p.add_argument("script", help='text file with lines "[m:ss] text"')
    p.set_defaults(fn=_cmd_youtube)

    p = sub.add_parser("translate", help="translate speech and say it in the speaker's voice")
    p.add_argument("source", help="audio the words are timed to")
    p.add_argument("words", help='JSON list of {"text", "start", "end", "speaker"}')
    p.add_argument("language", help="en, de, es, fr, it, pt, tr, uk")
    p.add_argument("output")
    p.add_argument("--background", action="store_true", help="keep the original music and noises")
    p.set_defaults(fn=_cmd_translate)

    p = sub.add_parser("separate", help="split a recording into voice and background")
    p.add_argument("source")
    p.add_argument("voice")
    p.add_argument("background")
    p.set_defaults(fn=_cmd_separate)

    p = sub.add_parser("mixdown", help="mix tracks of clips into one file")
    p.add_argument("plan", help="JSON plan (see mixdown.mix)")
    p.add_argument("output")
    p.set_defaults(fn=_cmd_mixdown)

    p = sub.add_parser("voicefx", help="noise removal and radio voice for the voice track")
    p.add_argument("source")
    p.add_argument("output")
    p.add_argument("--denoise", choices=["off", "light", "medium", "strong"], default="off")
    p.add_argument("--radio", action="store_true")
    p.set_defaults(fn=_cmd_voicefx)

    p = sub.add_parser("detect-watermark", help="check a file for MadStudio's AI mark")
    p.add_argument("file")
    p.set_defaults(fn=_cmd_detect)

    p = sub.add_parser("export")
    p.add_argument("input")
    p.add_argument("ranges", help='JSON file: {"ranges": [[start, end], ...]} in seconds')
    p.add_argument("output")
    p.set_defaults(fn=_cmd_export)

    return parser


def main(argv=None):
    args = _parser().parse_args(argv)
    try:
        args.fn(args)
    except Exception as e:  # the app shows the message; details go to stderr
        traceback.print_exc()
        events.emit("error", message=str(e), **({"model": e.model_id} if hasattr(e, "model_id") else {}))
        sys.exit(1)


if __name__ == "__main__":
    main()
