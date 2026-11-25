"""Physics parameters resource."""


struct Physics(TrivialRegisterPassable):
    """Gravity and per-type velocity relaxation times for the wind model."""

    var gravity: Float32
    """Downward gravitational acceleration in meters per second squared."""
    var response_times: SIMD[DType.float32, 2]
    """Velocity relaxation times in seconds, indexed by ParticleType.id."""

    def __init__(
        out self, *, snow: Float32, sand: Float32, gravity: Float32 = 9.81
    ):
        """Sets gravity and the response time for each particle type.

        Args:
            snow: Positive response time for snow particles in seconds.
            sand: Positive response time for sand particles in seconds.
            gravity: Downward acceleration in meters per second squared.
        """
        self.gravity = gravity
        self.response_times = SIMD[DType.float32, 2](snow, sand)
