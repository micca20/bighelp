"""Profile-scoped speech synthesis and bounded audio responses.

Operations use the calling LoopdyAdapter as their sole state/lifecycle owner.
Facade-owned callables and context variables are explicit call-time dependencies.
"""

from __future__ import annotations

import asyncio
import json
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from .inbound_dispatch import current_reply_route
from .link_contracts import VoiceSpeakRequest, voice_audio_chunks, voice_speak_error


def synthesize_voice_audio(request: VoiceSpeakRequest) -> SynthesizedVoiceAudio:
    """Run Hermes' configured TTS provider inside the requested profile scope."""
    from gateway.run import _profile_runtime_scope
    from hermes_cli.profiles import get_profile_dir, profile_exists
    from tools.tts_tool import text_to_speech_tool

    if not profile_exists(request.agent_id):
        raise VoiceSynthesisError("The selected agent is unavailable")
    profile_home = get_profile_dir(request.agent_id)
    with tempfile.TemporaryDirectory(prefix="loopdy-voice-") as directory:
        root = Path(directory).resolve()
        output_path = root / "speech.mp3"
        with _profile_runtime_scope(profile_home):
            raw_result = text_to_speech_tool(
                request.text,
                output_path=str(output_path),
                speed=request.speed,
            )
        try:
            result = json.loads(raw_result) if isinstance(raw_result, str) else raw_result
        except (TypeError, json.JSONDecodeError) as exc:
            raise VoiceSynthesisError("Hermes TTS returned an invalid result") from exc
        if not isinstance(result, dict) or result.get("success") is not True:
            raise VoiceSynthesisError("Hermes TTS could not synthesize this response")
        file_value = result.get("file_path")
        if not isinstance(file_value, str) or not file_value:
            raise VoiceSynthesisError("Hermes TTS did not return audio")
        audio_path = Path(file_value).expanduser().resolve()
        if not audio_path.is_relative_to(root) or not audio_path.is_file():
            raise VoiceSynthesisError("Hermes TTS returned an invalid audio file")
        size = audio_path.stat().st_size
        if not 0 < size <= 8 * 1024 * 1024:
            raise VoiceSynthesisError("Hermes TTS audio exceeds the Loopdy limit")
        audio = audio_path.read_bytes()
        extension = audio_path.suffix.lower()
        mime_type = {
            ".mp3": "audio/mpeg",
            ".ogg": "audio/ogg",
            ".opus": "audio/ogg",
            ".wav": "audio/wav",
            ".flac": "audio/flac",
        }.get(extension, "audio/mpeg")
        provider = " ".join(str(result.get("provider") or "Hermes TTS").split())
        if not provider or len(provider) > 80 or any(ord(character) < 32 for character in provider):
            provider = "Hermes TTS"
        return SynthesizedVoiceAudio(
            audio=audio,
            mime_type=mime_type,
            provider=provider,
        )


class VoiceSynthesisError(RuntimeError):
    pass


@dataclass(frozen=True)
class SynthesizedVoiceAudio:
    audio: bytes
    mime_type: str
    provider: str


async def _serve_voice_request(self, request: VoiceSpeakRequest) -> None:
    if self.link_client is None:
        return
    try:
        route = current_reply_route.get()
        if route is not None:
            route.check_current()
        result = await asyncio.to_thread(self.voice_synthesizer, request)
        payloads = voice_audio_chunks(
            request=request,
            audio=result.audio,
            mime_type=result.mime_type,
            provider=result.provider,
            sent_at=int(time.time()),
        )
    except asyncio.CancelledError:
        raise
    except Exception:
        code = "synthesis_failed"
        message = "The selected agent could not create speech right now."
        try:
            await self._send_link_payload(
                voice_speak_error(
                    request=request,
                    code=code,
                    message=message,
                    sent_at=int(time.time()),
                )
            )
        except Exception:
            pass
        return
    for payload in payloads:
        try:
            await self._send_link_payload(payload)
        except asyncio.CancelledError:
            raise
        except Exception:
            return
