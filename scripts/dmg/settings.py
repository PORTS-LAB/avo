# dmgbuild settings for Avo's disk image (scripts/build-dmg.sh).
#
#   dmgbuild -s scripts/dmg/settings.py -D app=/path/to/Avo.app \
#     -D background=scripts/dmg/background.tiff "Avo 0.1.0" Avo-0.1.0.dmg
#
# The background (background.tiff, 640x480 with a @2x page) is rendered from
# background.html (next to this file) with headless Chrome, at 1x and 2x.
import os

app = defines["app"]
appname = os.path.basename(app)

format = "ULFO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

# dmgbuild runs this file without __file__: build-dmg.sh passes the path.
background = defines["background"]
window_rect = ((240, 140), (640, 508))
icon_size = 112
text_size = 13
icon_locations = {
    appname: (160, 200),
    "Applications": (480, 200),
}

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False
