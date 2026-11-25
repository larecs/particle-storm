"""Obstacle editor state resource."""


struct Editor(Copyable):
    """Obstacle editor state that the display shows."""

    var tool: Int
    """Shape the next click creates: Obstacle.CIRCLE or Obstacle.RECTANGLE."""
    var hovered: Int
    """Group under the cursor or being dragged, or -1."""
    var message: String
    """Short status line, such as a rejected edit."""

    def __init__(out self):
        """Starts with the circle tool and nothing hovered."""
        self.tool = 0
        self.hovered = -1
        self.message = String()
