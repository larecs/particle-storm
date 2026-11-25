"""Host loop state resource."""


@fieldwise_init
struct RunState(Copyable):
    """Whether the main loop should continue running, and frames completed."""

    var running: Bool
    var frames: Int

    def __init__(out self):
        """Starts the main loop in the running state with no frames."""
        self.running = True
        self.frames = 0
