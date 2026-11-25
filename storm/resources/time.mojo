"""Simulation clock resource."""


@fieldwise_init
struct Time(TrivialRegisterPassable):
    """Last frame's timestep and elapsed simulation time in seconds."""

    var dt: Float32
    var absolute: Float32

    def __init__(out self):
        """Starts elapsed time at zero with a 1/60-second initial timestep."""
        self.dt = 1.0 / 60.0
        self.absolute = 0.0
