"""Mouse and keyboard input resource."""

from storm.components import Position


struct Input(Copyable):
    """Mouse and keyboard input the display collected during the last frame.

    Positions are in domain meters. Edge flags hold for exactly one frame.
    """

    var mouse: Position
    """Cursor position in meters."""
    var over_domain: Bool
    """Whether the cursor is over the drawn domain."""
    var left_down: Bool
    """Whether the left button is held."""
    var left_pressed: Bool
    """Whether the left button went down during the frame."""
    var right_pressed: Bool
    """Whether the right button went down during the frame."""
    var wheel: Float32
    """Vertical scroll during the frame; positive scrolls away from the user."""
    var rotation: Float32
    """-1 while Q is held, 1 while E is held, else 0."""
    var tool: Int
    """Tool chosen during the frame: 1 for circle, 2 for rectangle, else 0."""
    var delete_pressed: Bool
    """Whether Delete or Backspace went down during the frame."""

    def __init__(out self):
        """Creates idle input with the cursor outside the domain."""
        self.mouse = Position(0, 0)
        self.over_domain = False
        self.left_down = False
        self.left_pressed = False
        self.right_pressed = False
        self.wheel = 0
        self.rotation = 0
        self.tool = 0
        self.delete_pressed = False
