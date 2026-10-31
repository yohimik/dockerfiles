"""Adapt the existing server CLI to GitHub composite-action outputs."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import uuid


SERVER_PATH = (
    Path(__file__).resolve().parents[3]
    / "images" / "laptop-location-server" / "function" / "main.py"
)
spec = importlib.util.spec_from_file_location("server_repository_function", SERVER_PATH)
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


def write_output(output, name, value):
    """Use an unambiguous delimiter even for provider strings with newlines."""
    delimiter = "server_check_" + uuid.uuid4().hex
    while delimiter in value:
        delimiter = "server_check_" + uuid.uuid4().hex
    output.write("{}<<{}\n{}\n{}\n".format(name, delimiter, value, delimiter))


def main():
    output_path = os.environ.get("GITHUB_OUTPUT", "")
    if not output_path:
        print("GITHUB_OUTPUT is required to run the composite action", file=sys.stderr)
        return 1
    try:
        # Check the runner's output destination before a visibility-changing API
        # call. Keep all provider behavior and input validation in the server.
        with Path(output_path).open("a", encoding="utf-8") as output:
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                code = server.main()
            if code != 0:
                return code
            result = json.loads(captured.getvalue())
            encoded = json.dumps(result, sort_keys=True)
            activity_at = result.get("activity_at")
            values = {
                "result": encoded,
                "status": result["status"],
                "stop-schedule": "true" if result["stop_schedule"] else "false",
                "activity-at": activity_at if isinstance(activity_at, str) else "",
                "activity-source": result["activity_source"],
            }
            for name, value in values.items():
                write_output(output, name, value)
            output.flush()
    except OSError:
        print("Cannot write GitHub action outputs; check GITHUB_OUTPUT", file=sys.stderr)
        return 1
    except (ValueError, KeyError, TypeError):
        print("Server returned an invalid action result", file=sys.stderr)
        return 1
    except Exception:
        # Unexpected provider/library errors may contain credentials. The step
        # must fail without exposing exception details or a traceback.
        print("Server check failed; no action result was produced", file=sys.stderr)
        return 1
    print(encoded)
    return 0


if __name__ == "__main__":
    sys.exit(main())
