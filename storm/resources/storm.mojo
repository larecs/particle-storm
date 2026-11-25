"""Storm vortex resource and the wind it produces."""

from std.math import cos, pi, sin
from storm.components import Position
from storm.periodic import wrap_delta
from storm.resources.bounds import Bounds


@fieldwise_init
struct Wind(TrivialRegisterPassable):
    """Local wind velocity in meters per second."""

    var dx: Float32
    var dy: Float32


struct Storm(TrivialRegisterPassable):
    """One large vortex whose center drifts across the domain.

    Tangential speed is `2 * max_speed * r * radius / (r² + radius²)`, which
    peaks at `max_speed` on the core radius and decays as `1 / r` outside.
    An inward component, `inflow` times the tangential speed, spirals air
    toward the core and balances the outward drift of inertial particles.
    A periodic taper fades the wind to zero half a domain from the center.
    """

    var radius: Float32
    """Core radius in meters, where wind speed peaks."""
    var max_speed: Float32
    """Peak tangential wind speed in meters per second."""
    var inflow: Float32
    """Inward wind speed as a fraction of the tangential speed."""
    var drift: SIMD[DType.float32, 2]
    """Center drift amplitude along x and y as a fraction of the domain."""
    var period: SIMD[DType.float32, 2]
    """Center drift period along x and y in seconds."""

    def __init__(
        out self,
        *,
        radius: Float32 = 10.0,
        max_speed: Float32 = 24.0,
        inflow: Float32 = 0.15,
        drift: SIMD[DType.float32, 2] = SIMD[DType.float32, 2](0.3, 0.2),
        period: SIMD[DType.float32, 2] = SIMD[DType.float32, 2](70.0, 45.0),
    ):
        """Creates a storm vortex.

        Args:
            radius: Positive core radius in meters.
            max_speed: Peak tangential wind speed in meters per second.
            inflow: Nonnegative inward speed as a fraction of tangential speed.
            drift: Center drift amplitude along x and y as a domain fraction.
            period: Positive center drift period along x and y in seconds.
        """
        self.radius = radius
        self.max_speed = max_speed
        self.inflow = inflow
        self.drift = drift
        self.period = period

    @always_inline
    def center(self, time: Float32, bounds: Bounds) -> Position:
        """Returns the vortex center at a point in time.

        Args:
            time: Elapsed simulation time in seconds.
            bounds: Periodic domain size.

        Returns:
            Center position in meters.
        """
        var phase = (2 * pi) * time / self.period
        return Position(
            bounds.width * (0.5 + self.drift[0] * sin(phase[0])),
            bounds.height * (0.5 + self.drift[1] * sin(phase[1])),
        )

    @always_inline
    def wind(
        self, position: Position, center: Position, bounds: Bounds
    ) -> Wind:
        """Samples the vortex wind at a position.

        Args:
            position: Sample position in meters.
            center: Current vortex center from `center`.
            bounds: Periodic domain size.

        Returns:
            Vortex wind in meters per second.
        """
        var dx = wrap_delta(position.x - center.x, bounds.width)
        var dy = wrap_delta(position.y - center.y, bounds.height)
        var r2 = self.radius * self.radius
        # A periodic cos² taper reaches zero half a domain away, so the
        # wrapped field has no seam where the flow direction flips.
        var taper_x = cos(pi * dx / bounds.width)
        var taper_y = cos(pi * dy / bounds.height)
        var scale = (
            2
            * self.max_speed
            * self.radius
            / (dx * dx + dy * dy + r2)
            * (taper_x * taper_x * taper_y * taper_y)
        )
        return Wind(
            (-dy - self.inflow * dx) * scale, (dx - self.inflow * dy) * scale
        )
