"""FrameStation's analyzer: what the NAS sees in photos and videos. See NAS-ANALYSIS.md."""
import os

# ONNX Runtime ships Microsoft's telemetry (process, device and model details,
# sent to mobile.events.data.microsoft.com), on by default. It reads this once,
# as it loads, so it's set here, before anything in the package can import it.
# On the NAS the container has no network to send on anyway.
os.environ["ORT_DISABLE_TELEMETRY"] = "1"
