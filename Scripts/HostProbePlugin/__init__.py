"""Test-only Hermes plugin for `Scripts/HostSignInMatrixProbe.py --modes media`.

- Image provider ``bighelp-probe``: writes a small PNG into ``$HERMES_HOME/cache/images`` and reports
  it like any generator, so the stock ``image_generate`` tool runs without a paid service.
- ``probe_vault_code`` and ``probe_vault_save_login``: ask through Hermes' own vault prompt bridge,
  the callbacks ``browser_vault_enter_code`` and ``browser_vault_save_login`` use, without a browser.
  They report only whether an answer arrived and its shape, never the value.
"""

from __future__ import annotations

import base64
import json
import struct
import zlib

from agent.image_gen_provider import ImageGenProvider, resolve_aspect_ratio, save_b64_image, success_response


def _png(width: int = 1024, height: int = 1024) -> bytes:
    # Noise in the low bits keeps it about 2 MB, the size of a real generated picture.
    import os
    rows = b"".join(b"\x00" + bytes(value & 0x0F | band for value, band in
                                      zip(os.urandom(width * 3), (0xE0, 0x70 + (y % 64), 0x40) * width))
                    for y in range(height))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


class ProbeImageProvider(ImageGenProvider):
    @property
    def name(self) -> str:
        return "bighelp-probe"

    def list_models(self):
        return [{"id": "probe-image", "display": "Probe image"}]

    def generate(self, prompt, aspect_ratio="landscape", *, image_url=None, reference_image_urls=None, **kwargs):
        path = save_b64_image(base64.b64encode(_png()).decode("ascii"), prefix="probe")
        return success_response(image=str(path), model="probe-image", prompt=prompt,
                                aspect_ratio=resolve_aspect_ratio(aspect_ratio), provider=self.name)


def _code(args, **_):
    from agent.vault_backends.unlock import get_code_prompt_callback
    prompt = get_code_prompt_callback()
    if prompt is None:
        return json.dumps({"success": False, "error": "no code prompt on this surface"})
    code = (prompt(str(args.get("site") or "example.com"), "") or "").strip()
    return json.dumps({"success": bool(code), "digits": len(code), "numeric": code.isdigit()})


def _save_login(args, **_):
    from agent.vault_backends.unlock import get_save_login_prompt_callback
    prompt = get_save_login_prompt_callback()
    if prompt is None:
        return json.dumps({"success": False, "error": "no save-login prompt on this surface"})
    origin = str(args.get("origin") or "https://example.com")
    answer = prompt(origin, origin.split("://", 1)[-1]) or {}
    return json.dumps({"success": bool(answer.get("identifier") and answer.get("password")),
                       "identifier": answer.get("identifier", ""), "password_length": len(answer.get("password", ""))})


def _schema(name: str, description: str, field: str) -> dict:
    return {"name": name, "description": description,
            "parameters": {"type": "object", "properties": {field: {"type": "string"}}, "required": []}}


def register(ctx) -> None:
    ctx.register_image_gen_provider(ProbeImageProvider())
    ctx.register_tool(name="probe_vault_code", toolset="bighelp_probe", handler=_code,
                      schema=_schema("probe_vault_code", "Test only: ask for a one-time code.", "site"))
    ctx.register_tool(name="probe_vault_save_login", toolset="bighelp_probe", handler=_save_login,
                      schema=_schema("probe_vault_save_login", "Test only: ask to save a login.", "origin"))
