"""Particle acceleration component."""


@fieldwise_init
struct Acceleration(ImplicitlyCopyable, Movable):
    """Particle acceleration in meters per second squared."""

    var ddx: Float32
    var ddy: Float32
