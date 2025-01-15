import logging
import pwnagotchi.ui.fonts as fonts
from pwnagotchi.ui.hw.base import DisplayImpl
from PIL import Image


class Waveshare2in7Partial(DisplayImpl):
    def __init__(self, config):
        super(Waveshare2in7Partial, self).__init__(config, 'waveshare2in7Partial')
        self._display = None
        self.counter = 0

    def layout(self):
        fonts.setup(10, 9, 10, 35, 25, 9)
        self._layout['width'] = 264
        self._layout['height'] = 176
        self._layout['face'] = (66, 27)
        self._layout['name'] = (5, 73)
        self._layout['channel'] = (0, 0)
        self._layout['aps'] = (28, 0)
        self._layout['uptime'] = (199, 0)
        self._layout['line1'] = [0, 14, 264, 14]
        self._layout['line2'] = [0, 162, 264, 162]
        self._layout['friend_face'] = (0, 146)
        self._layout['friend_name'] = (40, 146)
        self._layout['shakes'] = (0, 163)
        self._layout['mode'] = (239, 163)
        self._layout['status'] = {
            'pos': (38, 93),
            'font': fonts.status_font(fonts.Medium),
            'max': 40
        }
        return self._layout

    def initialize(self):
        logging.info("Initializing Waveshare 2.7 inch display with partial refresh support")
        from pwnagotchi.ui.hw.libs.waveshare.epaper.v2in7p.epd2in7 import EPD
        self._display = EPD(fast_refresh=True)
        self._display.init()

    def render(self, canvas):
        # Convert canvas to 1-bit mode and rotate for correct display orientation
        canvas = canvas.convert("1")
        rotated = canvas.rotate(90, expand=True)

        # Full refresh on the first render
        if self.counter == 0:
            self._display.smart_update(rotated)
        # Alternate inverted image for a flashing effect every 35th frame
        elif self.counter % 35 == 0:
            inverted_image = rotated.point(lambda x: 255 - x)
            self._display.display_partial_frame(inverted_image, 0, 0, 264, 176, fast=True)
            self._display.display_partial_frame(rotated, 0, 0, 264, 176, fast=True)
        # Perform partial refresh of the entire screen every 7th frame
        elif self.counter % 7 == 0:
            self._display.display_partial_frame(rotated, 0, 0, 264, 176, fast=True)
        # Update only a specific region (e.g., face area) on other frames
        else:
            self._display.display_partial_frame(rotated, 110, 84, 92, 40, fast=True)

        # Reset counter after 100 frames to avoid overflow
        self.counter = (self.counter + 1) % 100

    def clear(self):
        if self._display:
            self._display.Clear(0xFF)
