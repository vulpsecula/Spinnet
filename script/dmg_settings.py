# dmgbuild settings for the release DMG (package_release.sh). dmgbuild writes
# the Finder window layout itself, so packaging never has to script Finder.
#
# Defines passed with -D: app (the signed Spinnet.app), background (the TIFF
# with the arrow, 660 x 400 points at 1x and 2x).
import os.path

application = defines["app"]  # noqa: F821 - dmgbuild provides defines
app_name = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]

background = defines["background"]  # noqa: F821
# The window matches the background; the icons sit either side of its arrow.
window_rect = ((200, 120), (660, 400))
icon_size = 128
text_size = 13
icon_locations = {
    app_name: (180, 190),
    "Applications": (480, 190),
}
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
