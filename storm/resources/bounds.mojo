"""Periodic domain size resource."""


@fieldwise_init
struct Bounds(TrivialRegisterPassable):
    """Width and height of the periodic simulation domain in meters."""

    var width: Float32
    var height: Float32

    def __init__(out self):
        """Creates a 120 by 75 meter domain."""
        self.width = 120.0
        self.height = 75.0
