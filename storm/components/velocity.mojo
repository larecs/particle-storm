"""Particle velocity component."""


@fieldwise_init
struct Velocity(TrivialRegisterPassable):
    """Particle velocity in meters per second."""

    var dx: Float32
    var dy: Float32
