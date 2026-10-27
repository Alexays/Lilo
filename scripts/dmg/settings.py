# dmgbuild settings for build/Lilo.dmg; `make dmg` passes the app as -D app=<path>.
import os.path

app = defines["app"]  # noqa: F821 (injected by dmgbuild)

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/Pixel.icns")
# Relative to the repository root, where make runs; dmgbuild folds background@2x.png
# in as the Retina image of a multi-resolution TIFF.
background = "scripts/dmg/background.png"

# The height counts the 32 pt title bar macOS 26+ draws above the 640x400 content.
window_rect = ((200, 200), (640, 432))
default_view = "icon-view"
icon_size = 128
text_size = 13
icon_locations = {os.path.basename(app): (180, 176), "Applications": (460, 176)}
