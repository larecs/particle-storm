"""Particle velocity component."""


@fieldwise_init
struct Velocity(ImplicitlyCopyable, Movable):
    """Particle velocity in meters per second."""

    var dx: Float32
    var dy: Float32
