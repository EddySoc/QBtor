#!/usr/bin/env python3
"""
translate_srt_argos.py - Translate SRT subtitle files using Argos Translate (offline)

Usage:
    translate_srt_argos.exe --input INPUT.srt --output OUTPUT.srt --from en --to nl
    translate_srt_argos.exe --input INPUT.srt --output OUTPUT.srt --from eng --to dut

Supported language codes: 2-letter (en, nl, fr, de, ...) or 3-letter (eng, dut, fra, deu, ...)
Exit codes: 0 = success, 1 = error

Portable mode: argos-packages/ directory is read from next to the exe (or next to the .py script).
Translation engine: ctranslate2 batch mode (fast), falls back to argostranslate if needed.
"""

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
import warnings
from pathlib import Path

warnings.filterwarnings("ignore", message="Unable to find acceptable character detection dependency")

# Zorg voor UTF-8 output op Windows consoles (voorkomt crash bij emoji/speciale tekens in bestandsnamen)
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
if hasattr(sys.stderr, 'reconfigure'):
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

# ── Portable packages dir detection ───────────────────────────────────────────────────

def _find_packages_dir(override=None):
    if override and override.is_dir():
        return override
    if getattr(sys, 'frozen', False):
        candidate = Path(sys.executable).parent / "argos-packages"
    else:
        candidate = Path(__file__).parent / "argos-packages"
    return candidate if candidate.is_dir() else None


def _setup_portable_argos(override=None):
    pkg_dir = _find_packages_dir(override)
    if pkg_dir:
        try:
            import argostranslate.settings as _s
            _s.package_data_dir = pkg_dir
            _s.package_dirs = [pkg_dir]
        except ImportError:
            pass


_setup_portable_argos()

# ── Language code normalisation ────────────────────────────────────────────────────────

LANG_MAP = {
    "dut": "nl", "nld": "nl", "eng": "en", "fra": "fr", "fre": "fr",
    "deu": "de", "ger": "de", "spa": "es", "por": "pt", "ita": "it",
    "pol": "pl", "swe": "sv", "nor": "no", "dan": "da", "fin": "fi",
    "rus": "ru", "jpn": "ja", "kor": "ko", "chi": "zh", "ara": "ar",
    "tur": "tr", "cze": "cs", "slv": "sl", "slk": "sk", "ukr": "uk",
    "bul": "bg", "gre": "el", "heb": "he", "hin": "hi", "vie": "vi",
    "may": "ms", "ind": "id", "tam": "ta",
}

def normalize_lang(code):
    return LANG_MAP.get(code.lower().strip(), code.lower().strip())

# ── Package discovery ──────────────────────────────────────────────────────────────────

def _find_package(packages_dir, from_code, to_code):
    for pkg_dir in packages_dir.iterdir():
        if not pkg_dir.is_dir():
            continue
        meta = pkg_dir / "metadata.json"
        if not meta.exists():
            continue
        try:
            info = json.loads(meta.read_text(encoding='utf-8'))
        except Exception:
            continue
        if info.get("from_code") == from_code and info.get("to_code") == to_code:
            model_dir = pkg_dir / "model"
            sp_model  = next((pkg_dir / n for n in ("sentencepiece.model", "bpe.model") if (pkg_dir / n).exists()), None)
            if model_dir.is_dir() and sp_model:
                return model_dir, sp_model
    return None

# ── Translation engines ────────────────────────────────────────────────────────────────

class _Ct2Translator:
    """Fast batch translator using ctranslate2 + sentencepiece directly."""
    def __init__(self, model_dir, sp_model_path):
        import ctranslate2
        import sentencepiece as spm
        self._ct2 = ctranslate2.Translator(
            str(model_dir), device="cpu", inter_threads=4, compute_type="int8",
        )
        self._sp = spm.SentencePieceProcessor()
        self._sp.Load(str(sp_model_path))

    def translate_batch(self, texts):
        if not texts:
            return []
        tokenized = [self._sp.Encode(t, out_type=str) for t in texts]
        results   = self._ct2.translate_batch(tokenized, beam_size=2)
        # sp.Decode() on string pieces does not strip the ▁ word-boundary marker;
        # convert manually: ▁ (U+2581) marks a leading space for each piece.
        decoded = []
        for r in results:
            text = ''.join(p.replace('\u2581', ' ') for p in r.hypotheses[0]).strip()
            decoded.append(text)
        return decoded


def _build_ollama_prompt(text, from_code, to_code):
    return (
        f"Translate the following subtitle dialogue from {from_code} to {to_code}. "
        "Preserve the meaning, keep it natural, concise, and suitable for subtitles. "
        "Do not translate literally word-for-word. Keep the tone and flow natural. "
        "Do not include timestamps, line numbers, speaker labels, notes, explanations, or references to the source text. "
        "Return only the translated subtitle text with no extra commentary. "
        "Keep the same number of lines as the input.\n\n"
        f"{text}"
    )


def _ollama_request(base_url, model, prompt, timeout=90):
    payload = {
        "model": model,
        "prompt": prompt,
        "stream": False,
        "options": {"temperature": 0.2, "num_predict": 300},
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        f"{base_url.rstrip('/')}/api/generate",
        data=data,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        body = json.load(response)
    if isinstance(body, dict) and "response" in body:
        return (body.get("response") or "").strip()
    raise RuntimeError(f"Unexpected Ollama response: {body}")


class _OllamaTranslator:
    """Local subtitle-friendly translator via Ollama."""
    def __init__(self, model, from_code, to_code, base_url="http://127.0.0.1:11434", timeout=90):
        self._model = model
        self._from_code = from_code
        self._to_code = to_code
        self._base_url = base_url.rstrip("/")
        self._timeout = timeout

    def translate_batch(self, texts):
        if not texts:
            return []
        results = []
        for text in texts:
            if not text or not text.strip():
                results.append("")
                continue
            prompt = _build_ollama_prompt(text, self._from_code, self._to_code)
            try:
                results.append(_ollama_request(self._base_url, self._model, prompt, self._timeout))
            except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, RuntimeError):
                results.append(text)
        return results


def _build_ollama_polish_prompt(text, from_code, to_code):
    return (
        f"Polish the following translated subtitle text from {from_code} to {to_code}. "
        "Make it sound more natural for subtitles, more fluent, and more like natural spoken Dutch. "
        "Keep the meaning the same, keep the text concise, and preserve the same number of lines. "
        "Do not add explanations, notes, or timestamps. Return only the polished subtitle text.\n\n"
        f"{text}"
    )


class _OllamaPolisher:
    """Optional second pass that polishes subtitle wording using Ollama."""
    def __init__(self, model, from_code, to_code, base_url="http://127.0.0.1:11434", timeout=90):
        self._model = model
        self._from_code = from_code
        self._to_code = to_code
        self._base_url = base_url.rstrip("/")
        self._timeout = timeout

    def polish_text(self, text):
        if not text or not text.strip():
            return text
        prompt = _build_ollama_polish_prompt(text, self._from_code, self._to_code)
        try:
            return _ollama_request(self._base_url, self._model, prompt, self._timeout)
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, RuntimeError):
            return text


class _ArgosTranslator:
    """One-by-one fallback using argostranslate (same batch interface)."""
    def __init__(self, at_translator):
        self._t = at_translator

    def translate_batch(self, texts):
        return [self._t.translate(t) for t in texts]

# ── SRT parsing/writing ────────────────────────────────────────────────────────────────

def parse_srt(content):
    content = content.replace('\r\n', '\n').replace('\r', '\n')
    blocks  = re.split(r'\n{2,}', content.strip())
    entries = []
    for block in blocks:
        lines = block.split('\n')
        if len(lines) < 3:
            continue
        if not re.match(r'^\d+$', lines[0].strip()):
            continue
        if '-->' not in lines[1]:
            continue
        entries.append((lines[0].strip(), lines[1].strip(), lines[2:]))
    return entries


def write_srt(entries, output_path):
    with open(output_path, 'w', encoding='utf-8') as f:
        for index, timing, text_lines in entries:
            f.write(f"{index}\n{timing}\n")
            f.write('\n'.join(text_lines))
            f.write('\n\n')

# ── Batch translation with progress ───────────────────────────────────────────────────

_OPEN_TAG_RE  = re.compile(r'^(<[^>]+>)+', re.IGNORECASE)
_CLOSE_TAG_RE = re.compile(r'(<\/[^>]+>)+$', re.IGNORECASE)

def _strip_tags(line):
    s   = line.strip()
    pre = _OPEN_TAG_RE.match(s)
    suf = _CLOSE_TAG_RE.search(s)
    p   = pre.group(0) if pre else ''
    q   = suf.group(0) if suf else ''
    return p, s[len(p):len(s) - len(q)].strip(), q


def _build_subtitle_block(text_lines):
    return "\n".join(text_lines).strip()


def _sanitize_translated_block(text, expected_line_count):
    if not text:
        return []

    cleaned = []
    for line in text.replace('\r', '').splitlines():
        stripped = line.strip()
        if not stripped:
            continue

        lower = stripped.lower()
        if re.match(r'^\d+$', stripped):
            continue
        if re.match(r'^\d{2}:\d{2}:\d{2},\d{3}\s*-->\s*\d{2}:\d{2}:\d{2},\d{3}$', stripped):
            continue
        if '-->' in stripped and ':' in stripped:
            continue
        if re.search(r'\b(translation|translated|source|original|reference|note|context|subtitle|dialogue)\b', lower):
            continue
        if lower.startswith(("translation:", "translated:", "source:", "source text:", "original:", "original text:", "subtitle:", "subtitle text:", "note:", "context:")):
            continue
        if lower.startswith("this is") and "translation" in lower:
            continue
        if lower.startswith("the following") and "text" in lower:
            continue

        cleaned.append(stripped)

    if not cleaned:
        return []

    if expected_line_count and expected_line_count > 0 and len(cleaned) > expected_line_count:
        cleaned = cleaned[:expected_line_count]

    return cleaned


def translate_entries(entries, translators, verbose=True, polisher=None):
    """Translate each subtitle block as a whole and optionally polish the wording."""
    result = []
    total = len(entries)
    last_printed_pct = -1
    
    for idx, (index, timing, text_lines) in enumerate(entries, start=1):
        block_text = _build_subtitle_block(text_lines)
        if not block_text:
            result.append((index, timing, text_lines))
            continue

        translated_block = block_text
        for tr in translators:
            translated_block = tr.translate_batch([translated_block])[0]

        if polisher is not None:
            translated_block = polisher.polish_text(translated_block)

        if verbose:
            current_pct = int(idx * 100 / total)
            # Print elke 5% of elke 10 entries, zodat voortgang zichtbaar is
            if current_pct != last_printed_pct or (idx % 10 == 0):
                print(f"{current_pct}%", flush=True)
                last_printed_pct = current_pct

        translated_lines = _sanitize_translated_block(translated_block, len(text_lines))
        if not translated_lines:
            translated_lines = [block_text]
        result.append((index, timing, translated_lines))
    
    # Zorg altijd dat 100% wordt geprint
    if verbose and last_printed_pct != 100:
        print("100%", flush=True)
    
    return result

# ── Argostranslate chain fallback ─────────────────────────────────────────────────────

def _find_argos_chain(languages, from_code, to_code):
    from_obj = next((l for l in languages if l.code == from_code), None)
    to_obj   = next((l for l in languages if l.code == to_code),   None)
    if not from_obj:
        return None, None
    direct = from_obj.get_translation(to_obj) if to_obj else None
    if direct:
        return [_ArgosTranslator(direct)], f"{from_code} -> {to_code}"
    candidates = ['en'] + [l.code for l in languages if l.code not in (from_code, to_code, 'en')]
    for mid in candidates:
        mid_obj = next((l for l in languages if l.code == mid), None)
        if not mid_obj:
            continue
        t1 = from_obj.get_translation(mid_obj)
        t2 = mid_obj.get_translation(to_obj) if to_obj else None
        if t1 and t2:
            return [_ArgosTranslator(t1), _ArgosTranslator(t2)], f"{from_code} -> {mid} -> {to_code}"
    return None, None

# ── Main ───────────────────────────────────────────────────────────────────────────────

def _try_ollama_backend(from_code, to_code, model, base_url, timeout):
    try:
        translator = _OllamaTranslator(model, from_code, to_code, base_url, timeout)
        sample = translator.translate_batch(["Hello world"])
        if sample and sample[0]:
            return [translator]
    except Exception:
        return None
    return None


def _try_ollama_polisher(from_code, to_code, model, base_url, timeout):
    try:
        polisher = _OllamaPolisher(model, from_code, to_code, base_url, timeout)
        sample = polisher.polish_text("Hello world")
        if sample and sample.strip():
            return polisher
    except Exception:
        return None
    return None


def main():
    parser = argparse.ArgumentParser(description='Translate SRT using Argos Translate or Ollama (offline)')
    parser.add_argument('--input',        required=True)
    parser.add_argument('--output',       required=True)
    parser.add_argument('--from',         dest='from_lang', required=True)
    parser.add_argument('--to',           dest='to_lang',   required=True)
    parser.add_argument('--quiet',        action='store_true')
    parser.add_argument('--packages-dir', dest='packages_dir', default=None)
    parser.add_argument('--backend',      choices=['auto', 'argos', 'ollama'], default='argos')
    parser.add_argument('--ollama-model', default='mistral')
    parser.add_argument('--ollama-base-url', default='http://127.0.0.1:11434')
    parser.add_argument('--ollama-timeout', type=int, default=90)
    args = parser.parse_args()

    if args.packages_dir:
        _setup_portable_argos(Path(args.packages_dir))

    from_code = normalize_lang(args.from_lang)
    to_code   = normalize_lang(args.to_lang)

    translators = None
    polisher = None
    chain_desc  = f"{from_code} -> {to_code}"
    pkg_dir     = _find_packages_dir(Path(args.packages_dir) if args.packages_dir else None)

    if args.backend in ('auto', 'argos'):
        if pkg_dir:
            # 1. Direct pair
            pkg = _find_package(pkg_dir, from_code, to_code)
            if pkg:
                try:
                    translators = [_Ct2Translator(*pkg)]
                except Exception as e:
                    print(f"WARNING: ctranslate2 direct failed ({e})", file=sys.stderr)

            # 2. Chain via English
            if translators is None and from_code != 'en' and to_code != 'en':
                pkg1 = _find_package(pkg_dir, from_code, 'en')
                pkg2 = _find_package(pkg_dir, 'en', to_code)
                if pkg1 and pkg2:
                    try:
                        translators = [_Ct2Translator(*pkg1), _Ct2Translator(*pkg2)]
                        chain_desc  = f"{from_code} -> en -> {to_code}"
                    except Exception as e:
                        print(f"WARNING: ctranslate2 chain failed ({e})", file=sys.stderr)

        # 3. Fallback: argostranslate
        if translators is None:
            try:
                import argostranslate.translate as at
                translators, chain_desc = _find_argos_chain(at.get_installed_languages(), from_code, to_code)
            except ImportError as e:
                print(f"ERROR: argostranslate not available: {e}", file=sys.stderr)

    if translators is None and args.backend in ('auto', 'ollama'):
        translators = _try_ollama_backend(from_code, to_code, args.ollama_model, args.ollama_base_url, args.ollama_timeout)
        if translators and not args.quiet:
            print(f"Using Ollama backend ({args.ollama_model}) for {from_code} -> {to_code}...")

    if not translators:
        print(f"ERROR: No translation model for {from_code} -> {to_code}.", file=sys.stderr)
        if pkg_dir:
            pkgs = [p.name for p in pkg_dir.iterdir() if p.is_dir()]
            print(f"       Packages: {', '.join(pkgs)}", file=sys.stderr)
        sys.exit(1)

    if args.backend == 'ollama':
        polisher = None
    elif args.backend == 'auto':
        # Keep the optional Ollama polish step disabled by default so Argos stays fully local.
        polisher = None
    else:
        polisher = None

    try:
        with open(args.input, 'r', encoding='utf-8-sig') as f:
            content = f.read()
    except Exception as e:
        print(f"ERROR: Cannot read '{args.input}': {e}", file=sys.stderr)
        sys.exit(1)

    entries = parse_srt(content)
    if not entries:
        print(f"ERROR: No valid SRT entries in '{args.input}'.", file=sys.stderr)
        sys.exit(1)

    if not args.quiet:
        if isinstance(translators[0], _OllamaTranslator):
            engine = "ollama"
        elif isinstance(translators[0], _Ct2Translator):
            engine = "ctranslate2/batch"
        else:
            engine = "argostranslate"
        print(f"Translating {len(entries)} subtitle entries ({chain_desc}) [{engine}]...")

    translated = translate_entries(entries, translators, verbose=not args.quiet, polisher=polisher)

    try:
        write_srt(translated, args.output)
    except Exception as e:
        print(f"ERROR: Cannot write '{args.output}': {e}", file=sys.stderr)
        sys.exit(1)

    if not args.quiet:
        print(f"Done -> {args.output}")


if __name__ == '__main__':
    main()
